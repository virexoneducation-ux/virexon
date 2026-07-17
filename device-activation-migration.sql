-- ============================================================================
-- Virexon — نظام ربط الحساب بجهاز واحد (Device Activation)
-- ينفَّذ هذا الملف كاملاً مرة واحدة في: Supabase Dashboard → SQL Editor → New query
-- آمن لإعادة التشغيل (idempotent) قدر الإمكان، ولا يمس أي بيانات حالية في
-- جداول students / subscriptions / lessons.
-- ============================================================================

-- 1) الجدول: بيانات ربط كل حساب بجهاز واحد -----------------------------------
create table if not exists public.device_activations (
  id                       uuid primary key default gen_random_uuid(),
  student_email            text not null unique,
  device_id                text not null,               -- بصمة الجهاز (SHA-256 hex)
  device_name              text,                         -- اسم تقريبي (OS/متصفح) لعرضه للأدمن فقط
  first_activation_date    timestamptz not null default now(),
  last_activation_transfer timestamptz,                  -- تاريخ آخر نقل تفعيل (NULL = لم يُنقل من قبل)
  activation_status        text not null default 'active'
                              check (activation_status in ('active','disabled')),
  updated_at               timestamptz not null default now()
);

create index if not exists idx_device_activations_email
  on public.device_activations (student_email);

-- تحديث updated_at تلقائياً
create or replace function public.trg_device_activations_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end; $$;

drop trigger if exists trg_touch_device_activations on public.device_activations;
create trigger trg_touch_device_activations
  before update on public.device_activations
  for each row execute function public.trg_device_activations_touch();

-- 2) الحماية: تفعيل RLS بدون أي Policies ------------------------------------
-- هذا يمنع أي قراءة/كتابة مباشرة على الجدول من العميل (anon/authenticated) عبر
-- REST/JS مباشرة، حتى من شخص يفتح Console ويستدعي supabase.from(...) بنفسه.
-- الوصول الوحيد المسموح به هو عبر الدوال (functions) أدناه، لأنها معرّفة
-- بصلاحية SECURITY DEFINER وتتجاوز RLS بأمان داخل منطقها المتحكَّم فيه فقط.
alter table public.device_activations enable row level security;
-- لا نضيف أي "create policy" هنا عمداً => لا وصول مباشر إطلاقاً.

-- تأكيد إضافي: سحب أي صلاحيات مباشرة قد تكون ممنوحة تلقائياً
revoke all on public.device_activations from anon, authenticated;

-- 3) دالة: التحقق من حالة الجهاز عند تسجيل الدخول ---------------------------
-- ترجع واحدة من:
--  'none'     : لا يوجد جهاز مسجَّل بعد لهذا الحساب (أول تفعيل)
--  'match'    : الجهاز الحالي هو نفسه المسجَّل => يسمح بالدخول
--  'mismatch' : يوجد جهاز مختلف مسجَّل => يُمنع الدخول (ويُعرض خيار نقل التفعيل)
--  'disabled' : تم تعطيل تفعيل هذا الحساب من الإدارة
create or replace function public.fn_check_device(p_email text, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.device_activations;
begin
  select * into r from public.device_activations where student_email = lower(p_email);

  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if r.activation_status = 'disabled' then
    return jsonb_build_object('status', 'disabled');
  end if;

  if r.device_id = p_device_id then
    return jsonb_build_object('status', 'match');
  end if;

  return jsonb_build_object(
    'status', 'mismatch',
    'device_name', r.device_name,
    'first_activation_date', r.first_activation_date
  );
end;
$$;

-- 4) دالة: تفعيل الجهاز لأول مرة (بعد موافقة المستخدم في الواجهة) -----------
create or replace function public.fn_activate_device(p_email text, p_device_id text, p_device_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.device_activations (student_email, device_id, device_name, first_activation_date, activation_status)
  values (lower(p_email), p_device_id, p_device_name, now(), 'active')
  on conflict (student_email) do nothing;

  return jsonb_build_object('status', 'activated');
end;
$$;

-- 5) دالة: نقل التفعيل إلى جهاز جديد (مرة كل 30 يوماً) ----------------------
create or replace function public.fn_transfer_device(p_email text, p_new_device_id text, p_new_device_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.device_activations;
  last_change timestamptz;
  days_since numeric;
begin
  select * into r from public.device_activations where student_email = lower(p_email);

  if not found then
    -- لا يوجد تفعيل سابق أصلاً => فعّله مباشرة كأول تفعيل
    insert into public.device_activations (student_email, device_id, device_name, first_activation_date, activation_status)
    values (lower(p_email), p_new_device_id, p_new_device_name, now(), 'active');
    return jsonb_build_object('status', 'transferred');
  end if;

  if r.activation_status = 'disabled' then
    return jsonb_build_object('status', 'disabled');
  end if;

  last_change := coalesce(r.last_activation_transfer, r.first_activation_date);
  days_since := extract(epoch from (now() - last_change)) / 86400.0;

  if days_since < 30 then
    return jsonb_build_object('status', 'cooldown', 'days_left', ceil(30 - days_since));
  end if;

  update public.device_activations
     set device_id = p_new_device_id,
         device_name = p_new_device_name,
         last_activation_transfer = now(),
         activation_status = 'active'
   where student_email = lower(p_email);

  return jsonb_build_object('status', 'transferred');
end;
$$;

-- 6) دوال الإدارة (لوحة التحكم) ---------------------------------------------
-- ملاحظة مهمة: لوحة إدارة Virexon لا تستخدم Supabase Auth للأدمن، بل كلمة مرور
-- ثابتة (1792006) مطابقة تماماً للتصميم الحالي للموقع. لذلك نطلب نفس كلمة
-- المرور كمُعامل داخل كل دالة إدارية كطبقة حماية إضافية على مستوى القاعدة،
-- بدلاً من الاعتماد فقط على متغيّر جافاسكريبت في المتصفح (adminUnlocked).
-- إن رغبت لاحقاً في أمان أقوى، يُنصح بربط الإدمن بحساب Supabase Auth حقيقي
-- واستبدال هذا الشرط بفحص auth.uid() ودور مخصص.
create or replace function public.fn_admin_check_password(p_admin_password text)
returns boolean language sql immutable as $$
  select p_admin_password = '1792006';
$$;

create or replace function public.fn_admin_list_devices(p_admin_password text)
returns setof public.device_activations
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.fn_admin_check_password(p_admin_password) then
    raise exception 'كلمة مرور الإدارة غير صحيحة';
  end if;
  return query select * from public.device_activations order by updated_at desc;
end;
$$;

create or replace function public.fn_admin_reset_device(p_admin_password text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.fn_admin_check_password(p_admin_password) then
    raise exception 'كلمة مرور الإدارة غير صحيحة';
  end if;
  delete from public.device_activations where student_email = lower(p_email);
  return jsonb_build_object('status', 'reset');
end;
$$;

create or replace function public.fn_admin_set_status(p_admin_password text, p_email text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.fn_admin_check_password(p_admin_password) then
    raise exception 'كلمة مرور الإدارة غير صحيحة';
  end if;
  if p_status not in ('active','disabled') then
    raise exception 'قيمة activation_status غير صحيحة';
  end if;
  update public.device_activations set activation_status = p_status where student_email = lower(p_email);
  return jsonb_build_object('status', 'updated');
end;
$$;

-- يسمح للطالب بنقل التفعيل فوراً (يتجاوز مهلة الـ 30 يوماً مرة واحدة)
create or replace function public.fn_admin_allow_transfer(p_admin_password text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.fn_admin_check_password(p_admin_password) then
    raise exception 'كلمة مرور الإدارة غير صحيحة';
  end if;
  update public.device_activations
     set last_activation_transfer = now() - interval '31 days'
   where student_email = lower(p_email);
  return jsonb_build_object('status', 'transfer_allowed');
end;
$$;

-- 7) صلاحيات التنفيذ: نمنح anon/authenticated حق تنفيذ الدوال فقط (وليس
--    الجدول مباشرة). هذا هو المسار الوحيد المسموح للوصول للبيانات. --------
grant execute on function public.fn_check_device(text, text)                              to anon, authenticated;
grant execute on function public.fn_activate_device(text, text, text)                      to anon, authenticated;
grant execute on function public.fn_transfer_device(text, text, text)                      to anon, authenticated;
grant execute on function public.fn_admin_list_devices(text)                                to anon, authenticated;
grant execute on function public.fn_admin_reset_device(text, text)                          to anon, authenticated;
grant execute on function public.fn_admin_set_status(text, text, text)                      to anon, authenticated;
grant execute on function public.fn_admin_allow_transfer(text, text)                        to anon, authenticated;

-- ============================================================================
-- ملاحظات Migration آمنة للبيانات الحالية:
-- * الجدول جديد بالكامل (device_activations) ولا يمس students / subscriptions / lessons.
-- * أي مستخدم حالي ليس له صف في هذا الجدول => أول دخول له بعد تفعيل هذه الميزة
--   سيُعامَل كـ "أول تفعيل" (status='none') ويُطلب منه تأكيد تفعيل جهازه الحالي
--   فقط — لن يُحظر أو يُسجَّل خروجه قسرياً قبل ذلك.
-- * لو لم يتم تنفيذ هذا الملف إطلاقاً، تطبيق الواجهة (index.html) يتعامل مع فشل
--   استدعاء fn_check_device بأمان (status='unavailable') ولا يمنع أي مستخدم من
--   تسجيل الدخول، حفاظاً على استمرارية عمل الموقع.
-- ============================================================================

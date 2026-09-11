-- courses.pay_to_teacher decides who receives a course's payments — the
-- platform's own Zain/Qi numbers, or the teacher's own payment_method/detail.
-- The "Teachers can update own courses" / "...insert own courses" RLS
-- policies (add-teacher-role-schema.sql) only constrain `status`; they never
-- restricted this column, so a teacher could set it on themselves via the
-- app's own edit form. Yosif decides who gets paid, not the teacher — lock
-- it at the DB level so removing the checkbox from teacher.html isn't the
-- only thing stopping a direct API/RLS-level write too.
create or replace function public.enforce_pay_to_teacher_admin_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    if tg_op = 'INSERT' then
      new.pay_to_teacher := false;
    else
      new.pay_to_teacher := old.pay_to_teacher;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_pay_to_teacher_admin_only on courses;
create trigger trg_enforce_pay_to_teacher_admin_only
  before insert or update on courses
  for each row
  execute function public.enforce_pay_to_teacher_admin_only();

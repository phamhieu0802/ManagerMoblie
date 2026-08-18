-- Fix RLS: ngăn admin tự nâng quyền (chỉ sửa được role/store_id giữ nguyên).
-- Fix trùng lương: chống trả lương 2 lần trong cùng 1 kỳ cho cùng 1 nhân viên.

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid())
  with check (
    id = auth.uid()
    and role = (select role from profiles where id = auth.uid())
    and (store_id is not distinct from (select store_id from profiles where id = auth.uid()))
  );

-- Chống trả lương 2 lần trong cùng 1 kỳ cho cùng 1 nhân viên.
-- Chạy lại an toàn (idempotent): chỉ thêm constraint nếu chưa tồn tại.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'salary_payments_store_employee_period_unique'
  ) then
    alter table public.salary_payments
      add constraint salary_payments_store_employee_period_unique
      unique (store_id, employee_id, period_start);
  end if;
end $$;

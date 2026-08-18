-- Patch an toàn: KHÔNG xóa dữ liệu, chỉ thêm bảng + policy mới cho tính năng
-- "Mời nhân viên qua Google". Chạy trong Supabase Dashboard -> SQL Editor.

create table if not exists public.employee_invites (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  email text not null,
  full_name text not null,
  role public.user_role not null,
  status text not null default 'pending',  -- 'pending' | 'accepted'
  invited_by uuid references public.profiles(id),
  invited_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (store_id, email)
);

alter table public.employee_invites enable row level security;

drop policy if exists "employee_invites_admin_manage" on public.employee_invites;
create policy "employee_invites_admin_manage" on public.employee_invites
  for all using (
    store_id = public.current_store_id() and public.current_role() = 'admin'
  )
  with check (
    store_id = public.current_store_id() and public.current_role() = 'admin'
  );

drop policy if exists "employee_invites_self_view" on public.employee_invites;
create policy "employee_invites_self_view" on public.employee_invites
  for select using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')));

drop policy if exists "employee_invites_self_accept" on public.employee_invites;
create policy "employee_invites_self_accept" on public.employee_invites
  for update using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')))
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')));

-- Bật realtime cho bảng mới (để danh sách lời mời tự cập nhật trong app)
alter publication supabase_realtime add table public.employee_invites;

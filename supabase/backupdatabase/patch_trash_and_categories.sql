-- Patch an toàn: KHÔNG xóa dữ liệu hiện có, chỉ thêm cột/bảng mới + cập nhật
-- RLS để hỗ trợ: ghi chú đơn, thanh toán, danh mục linh kiện, và THÙNG RÁC
-- (soft delete — chỉ admin xem/khôi phục được, dữ liệu vẫn còn nguyên trong DB).
-- Chạy trong Supabase Dashboard -> SQL Editor.

-- ========== 1. Cột mới ==========
alter table public.repair_orders add column if not exists note text;
alter table public.repair_orders add column if not exists payment_method text;
alter table public.repair_orders add column if not exists paid_at timestamptz;
alter table public.repair_orders add column if not exists deleted_at timestamptz;
alter table public.repair_orders add column if not exists deleted_by uuid references public.profiles(id);

alter table public.customers add column if not exists deleted_at timestamptz;
alter table public.customers add column if not exists deleted_by uuid references public.profiles(id);

alter table public.transactions add column if not exists deleted_at timestamptz;
alter table public.transactions add column if not exists deleted_by uuid references public.profiles(id);

create table if not exists public.part_categories (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (store_id, name)
);

alter table public.inventory_parts add column if not exists category_id uuid references public.part_categories(id);
alter table public.inventory_parts add column if not exists deleted_at timestamptz;
alter table public.inventory_parts add column if not exists deleted_by uuid references public.profiles(id);

-- ========== 2. RLS: thay policy "all" cũ bằng policy tách biệt để chặn
-- non-admin xem/khôi phục dòng đã ở trong thùng rác ==========
drop policy if exists "customers_all" on public.customers;
drop policy if exists "customers_select" on public.customers;
drop policy if exists "customers_insert" on public.customers;
drop policy if exists "customers_update" on public.customers;
drop policy if exists "customers_delete" on public.customers;
create policy "customers_select" on public.customers
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "customers_insert" on public.customers
  for insert with check (store_id = public.current_store_id());
create policy "customers_update" on public.customers
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "customers_delete" on public.customers
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

drop policy if exists "repair_orders_all" on public.repair_orders;
drop policy if exists "repair_orders_select" on public.repair_orders;
drop policy if exists "repair_orders_insert" on public.repair_orders;
drop policy if exists "repair_orders_update" on public.repair_orders;
drop policy if exists "repair_orders_delete" on public.repair_orders;
create policy "repair_orders_select" on public.repair_orders
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "repair_orders_insert" on public.repair_orders
  for insert with check (store_id = public.current_store_id());
create policy "repair_orders_update" on public.repair_orders
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "repair_orders_delete" on public.repair_orders
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

drop policy if exists "inventory_parts_all" on public.inventory_parts;
drop policy if exists "inventory_parts_select" on public.inventory_parts;
drop policy if exists "inventory_parts_insert" on public.inventory_parts;
drop policy if exists "inventory_parts_update" on public.inventory_parts;
drop policy if exists "inventory_parts_delete" on public.inventory_parts;
create policy "inventory_parts_select" on public.inventory_parts
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "inventory_parts_insert" on public.inventory_parts
  for insert with check (store_id = public.current_store_id());
create policy "inventory_parts_update" on public.inventory_parts
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "inventory_parts_delete" on public.inventory_parts
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

drop policy if exists "transactions_select" on public.transactions;
drop policy if exists "transactions_write" on public.transactions;
drop policy if exists "transactions_update" on public.transactions;
drop policy if exists "transactions_delete" on public.transactions;
create policy "transactions_select" on public.transactions
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "transactions_write" on public.transactions
  for insert with check (
    store_id = public.current_store_id() and public.current_role() in ('admin','receptionist')
  );
create policy "transactions_update" on public.transactions
  for update using (
    store_id = public.current_store_id()
    and (deleted_at is null or public.current_role() = 'admin')
    and public.current_role() in ('admin','receptionist')
  ) with check (store_id = public.current_store_id());
create policy "transactions_delete" on public.transactions
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

alter table public.part_categories enable row level security;
drop policy if exists "part_categories_all" on public.part_categories;
create policy "part_categories_all" on public.part_categories
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

-- ========== 3. Realtime cho bảng mới ==========
do $$
begin
  begin
    alter publication supabase_realtime add table public.part_categories;
  exception when duplicate_object then null;
  end;
end $$;

-- ========== 4. Dọn "thùng rác" quá 90 ngày (chạy định kỳ, tuỳ chọn) ==========
-- Có thể lên lịch bằng Supabase Cron (pg_cron) để tự xoá vĩnh viễn sau 90 ngày.
-- Ví dụ (chạy thử tay 1 lần để kiểm tra trước khi lên lịch tự động):
-- delete from public.repair_orders where deleted_at is not null and deleted_at < now() - interval '90 days';
-- delete from public.customers where deleted_at is not null and deleted_at < now() - interval '90 days';
-- delete from public.inventory_parts where deleted_at is not null and deleted_at < now() - interval '90 days';
-- delete from public.transactions where deleted_at is not null and deleted_at < now() - interval '90 days';

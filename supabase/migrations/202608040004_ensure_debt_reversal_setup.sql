-- Migration tổng hợp (idempotent, chạy lại an toàn).
-- Mục đích: đảm bảo đủ cột + policy để khi bỏ/hủy linh kiện ngoài khỏi phiếu sửa
-- thì phiếu phát sinh nợ trong Thu chi -> Công nợ được xoá hẳn và total_debt được trừ.
-- Gộp nội dung của 202608040001, 202608040002, 202608040003.

-- 1. Liên kết phiếu nợ với đơn + linh kiện
alter table public.debt_transactions
  add column if not exists repair_order_id uuid references public.repair_orders(id),
  add column if not exists inventory_part_id uuid references public.inventory_parts(id) on delete cascade;

-- 2. Cột soft-delete (dự phòng khi chưa có policy delete)
alter table public.debt_transactions
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid;

create index if not exists idx_debt_transactions_order_part
  on public.debt_transactions(repair_order_id, inventory_part_id);

-- 3. Cho phép xoá phiếu phát sinh nợ của cùng cửa hàng
drop policy if exists "debt_tx_delete" on public.debt_transactions;
create policy "debt_tx_delete" on public.debt_transactions
  for delete using (
    exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id)
  );

-- 4. Cho phép xoá linh kiện của cùng cửa hàng (trước đây chỉ admin)
drop policy if exists "inventory_parts_delete" on public.inventory_parts;
create policy "inventory_parts_delete" on public.inventory_parts
  for delete using (store_id = public.current_store_id());

-- 5. Đảm bảo FK inventory_part_id cascade theo inventory_parts
do $$
begin
  if exists (
    select 1 from pg_constraint where conname = 'debt_transactions_inventory_part_id_fkey'
  ) then
    alter table public.debt_transactions drop constraint debt_transactions_inventory_part_id_fkey;
  end if;
  alter table public.debt_transactions add constraint debt_transactions_inventory_part_id_fkey
    foreign key (inventory_part_id) references public.inventory_parts(id) on delete cascade;
end $$;

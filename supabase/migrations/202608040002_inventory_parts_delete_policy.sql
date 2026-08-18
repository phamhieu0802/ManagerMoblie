-- Khi bỏ linh kiện ngoài khỏi đơn: xoá hẳn khỏi bảng inventory_parts thay vì
-- để lại bản ghi soft-delete. Cần (1) cho phép người cùng cửa hàng xoá linh
-- kiện (trước đây chỉ admin) và (2) tự xoá phiếu nợ liên kết khi xoá linh kiện.
drop policy if exists "inventory_parts_delete" on public.inventory_parts;
create policy "inventory_parts_delete" on public.inventory_parts
  for delete using (store_id = public.current_store_id());

-- Đảm bảo FK debt_transactions.inventory_part_id cascade theo inventory_parts
-- (áp dụng cho trường hợp migration 202608040001 đã chạy).
do $$
begin
  if exists (
    select 1 from pg_constraint where conname = 'debt_transactions_inventory_part_id_fkey'
  ) then
    alter table public.debt_transactions drop constraint debt_transactions_inventory_part_id_fkey;
    alter table public.debt_transactions add constraint debt_transactions_inventory_part_id_fkey
      foreign key (inventory_part_id) references public.inventory_parts(id) on delete cascade;
  end if;
end $$;

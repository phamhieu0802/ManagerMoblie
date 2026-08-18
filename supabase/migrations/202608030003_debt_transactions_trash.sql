-- Thùng rác: cho phép phiếu phát sinh công nợ bị "xoá" được giữ lại & khôi phục.
alter table public.debt_transactions
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid;

create index if not exists idx_debt_transactions_deleted_at
  on public.debt_transactions(deleted_at);

-- Admin được thấy cả bản ghi đã xoá (để khôi phục từ thùng rác).
drop policy if exists "debt_tx_select" on public.debt_transactions;
create policy "debt_tx_select" on public.debt_transactions
  for select using (
    exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id)
    and (debt_transactions.deleted_at is null or public.current_role() = 'admin')
  );

-- Cho phép admin cập nhật cột deleted_at (khôi phục) và người cùng store đánh dấu xoá.
drop policy if exists "debt_tx_update" on public.debt_transactions;
create policy "debt_tx_update" on public.debt_transactions
  for update using (
    exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id)
  );

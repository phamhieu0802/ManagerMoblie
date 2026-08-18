-- Ngày giao dịch thu/chi & công nợ (cho phép chọn ngày khi tạo/sửa phiếu).
-- Tách riêng khỏi created_at (thời điểm tạo bản ghi).

alter table public.transactions
  add column if not exists transaction_date timestamptz;
alter table public.debt_transactions
  add column if not exists transaction_date timestamptz;

-- Dữ liệu cũ mặc định lấy theo ngày tạo bản ghi.
update public.transactions
  set transaction_date = created_at
  where transaction_date is null;
update public.debt_transactions
  set transaction_date = created_at
  where transaction_date is null;

create index if not exists idx_transactions_transaction_date
  on public.transactions(transaction_date desc);
create index if not exists idx_debt_transactions_transaction_date
  on public.debt_transactions(transaction_date desc);

-- Cho phép sửa phiếu phát sinh công nợ (người cùng cửa hàng).
drop policy if exists "debt_tx_update" on public.debt_transactions;
create policy "debt_tx_update" on public.debt_transactions
  for update using (
    exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id)
  );

-- Cho phép sửa phiếu thu/chi (người cùng cửa hàng).
drop policy if exists "tx_update" on public.transactions;
create policy "tx_update" on public.transactions
  for update using (
    exists (select 1 from profiles where id = auth.uid() and store_id = transactions.store_id)
  );

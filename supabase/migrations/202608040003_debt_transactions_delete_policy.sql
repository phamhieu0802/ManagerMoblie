-- Khi hủy linh kiện ngoài khỏi đơn: xoá hẳn phiếu phát sinh nợ (không giữ lại
-- trong thùng rác vì TrashScreen không khôi phục debt_transactions).
create policy "debt_tx_delete" on public.debt_transactions
  for delete using (
    exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id)
  );

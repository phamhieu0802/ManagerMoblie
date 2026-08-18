-- Gắn phiếu phát sinh nợ (linh kiện ngoài của đơn sửa) với đơn + linh kiện để
-- khi bỏ linh kiện ra khỏi đơn đảo lại công nợ chính xác (không còn dò theo
-- chuỗi mô tả, dễ miss khi tên linh kiện bị đổi).
alter table public.debt_transactions
  add column if not exists repair_order_id uuid references public.repair_orders(id),
  add column if not exists inventory_part_id uuid references public.inventory_parts(id) on delete cascade;

create index if not exists idx_debt_transactions_order_part
  on public.debt_transactions(repair_order_id, inventory_part_id);

-- Nâng cấp phiếu lương: lưu thêm số đơn, doanh thu, lợi nhuận và phương thức thanh toán
-- để màn Lịch sử trả lương và trang chi tiết phiếu hiển thị đúng.

alter table public.salary_payments
  add column if not exists order_count int not null default 0,
  add column if not exists labor_total numeric(14,0) not null default 0,
  add column if not exists profit_total numeric(14,0) not null default 0,
  add column if not exists pay_method text check (pay_method in ('cash', 'transfer'));

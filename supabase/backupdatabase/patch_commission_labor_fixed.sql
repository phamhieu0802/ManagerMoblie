-- Chuyển cơ chế "tiền công" từ % doanh thu -> số tiền cố định trên 1 hóa đơn.
-- Cơ chế lưu trong profiles.commission_type:
--   'labor_fixed' = số tiền nhận trên 1 đơn (lưu ở commission_amount, VNĐ)
--   'profit_pct'  = % lợi nhuận của 1 đơn (doanh thu - chi phí linh kiện, lưu ở commission_rate)
alter table public.profiles
  add column if not exists commission_amount numeric(14,0) default 0;

-- Bỏ ràng buộc cũ (nếu có) để được đổi giá trị.
alter table public.profiles
  drop constraint if exists profiles_commission_type_check;

-- Di chuyển dữ liệu cũ: 'labor_pct' (đang là %) -> 'labor_fixed' (admin cài lại số tiền/đơn).
update public.profiles
  set commission_type = 'labor_fixed'
  where commission_type = 'labor_pct';

-- Thêm lại ràng buộc cho phép giá trị mới.
alter table public.profiles
  add constraint profiles_commission_type_check
  check (commission_type in ('labor_fixed', 'profit_pct'));

-- Lịch sử trả lương: thêm cột chứa số tiền/đơn, cho phép commission_rate NULL (chỉ dùng cho % lợi nhuận).
alter table public.salary_payments
  add column if not exists commission_amount numeric(14,0) default 0;

alter table public.salary_payments
  alter column commission_rate drop not null;

alter table public.salary_payments
  drop constraint if exists salary_payments_commission_type_check;

update public.salary_payments
  set commission_type = 'labor_fixed'
  where commission_type = 'labor_pct';

alter table public.salary_payments
  add constraint salary_payments_commission_type_check
  check (commission_type in ('labor_fixed', 'profit_pct'));

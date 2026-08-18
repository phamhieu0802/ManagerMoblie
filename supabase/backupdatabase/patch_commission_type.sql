-- Thêm cột chọn cơ chế tính lương cho nhân viên (chọn trước khi nhập % hoa hồng).
-- 'labor_pct'  = % tiền công (doanh thu)
-- 'profit_pct' = % lợi nhuận (doanh thu - chi phí linh kiện)
alter table public.profiles
  add column if not exists commission_type text
    check (commission_type in ('labor_pct', 'profit_pct'));

-- Mặc định KTV cũ (đang có % hoa hồng) theo cơ chế % tiền công như trước đây.
update public.profiles
  set commission_type = 'labor_pct'
  where commission_type is null and commission_rate > 0;

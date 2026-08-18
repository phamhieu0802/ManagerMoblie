-- Tùy chọn hiển thị trên phiếu in nhiệt (mẫu in):
--   print_show_timestamp: in ngày giờ in ở hàng trên cùng
--   print_show_tax_code : in mã số thuế (MST) của cửa hàng
--   print_show_bank     : in thông tin tài khoản ngân hàng (STK)
alter table public.stores
  add column if not exists print_show_timestamp boolean not null default true,
  add column if not exists print_show_tax_code boolean not null default true,
  add column if not exists print_show_bank boolean not null default true;

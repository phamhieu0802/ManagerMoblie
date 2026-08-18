-- Mã QR chuyển khoản (VietQR / QR Code) dùng để in lên phiếu in nhiệt.
-- Người dùng dán chuỗi QR (payload) vào Cài đặt → Tài khoản chuyển khoản.
alter table public.stores
  add column if not exists bank_qr text;

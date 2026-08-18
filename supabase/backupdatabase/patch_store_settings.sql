-- Thêm cột cho stores: thông tin ngân hàng, in ấn, Discord webhook, máy in
alter table public.stores
  add column if not exists bank_name text,
  add column if not exists bank_account text,
  add column if not exists bank_branch text,
  add column if not exists print_header text,
  add column if not exists print_footer text,
  add column if not exists discord_webhook_url text,
  add column if not exists printer_address text,
  add column if not exists printer_type text default 'bluetooth';

-- Thêm discord_id cho profiles
alter table public.profiles
  add column if not exists discord_id text;

-- Đánh dấu đã gửi Discord notification
alter table public.repair_orders
  add column if not exists discord_notified bool not null default false;

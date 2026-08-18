-- =========================================================
-- SCHEMA: App quản lý cửa hàng sửa chữa điện thoại
-- Phân quyền: admin (chủ cửa hàng) / receptionist (lễ tân) / technician (kỹ thuật viên)
-- =========================================================

-- ---------- DỌN DẸP (an toàn khi chạy lại nhiều lần) ----------
drop table if exists public.employees cascade;
drop table if exists public.fcm_tokens cascade;
drop table if exists public.notifications cascade;
drop table if exists public.qr_codes cascade;
drop table if exists public.employee_invites cascade;
drop table if exists public.salary_payments cascade;
drop table if exists public.stock_counts cascade;
drop table if exists public.transactions cascade;
drop table if exists public.debt_transactions cascade;
drop table if exists public.debts cascade;
drop table if exists public.cash_accounts cascade;
drop table if exists public.inventory_transactions cascade;
drop table if exists public.inventory_parts cascade;
drop table if exists public.part_categories cascade;
drop table if exists public.repair_order_status_history cascade;
drop table if exists public.repair_orders cascade;
drop table if exists public.customers cascade;
drop table if exists public.app_logs cascade;
drop table if exists public.profiles cascade;
drop table if exists public.stores cascade;

drop function if exists public.handle_new_user() cascade;
drop function if exists public.current_profile() cascade;
drop function if exists public.current_store_id() cascade;
drop function if exists public.current_role() cascade;

drop trigger if exists on_auth_user_created on auth.users;

drop policy if exists "repair_photos_select" on storage.objects;
drop policy if exists "repair_photos_insert" on storage.objects;
drop policy if exists "repair_photos_update" on storage.objects;
drop policy if exists "repair_photos_delete" on storage.objects;

drop type if exists public.user_role cascade;
drop type if exists public.repair_status cascade;
drop type if exists public.tx_type cascade;
drop type if exists public.inventory_tx_type cascade;

-- ---------- EXTENSIONS ----------
create extension if not exists "uuid-ossp";

-- ---------- ENUM TYPES ----------
create type public.user_role as enum ('admin', 'receptionist', 'technician');
create type public.repair_status as enum (
  'received',       -- Mới tiếp nhận
  'diagnosing',      -- Đang kiểm tra/chẩn đoán
  'waiting_parts',   -- Chờ linh kiện
  'repairing',       -- Đang sửa chữa
  'repaired',        -- Đã sửa xong, chờ khách lấy
  'delivered',       -- Đã giao khách
  'cancelled'        -- Hủy
);
create type public.tx_type as enum ('income', 'expense');
create type public.inventory_tx_type as enum ('in', 'out', 'adjust');

-- ---------- STORES ----------
create table public.stores (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  store_code text not null unique,           -- mã cửa hàng, nhân viên dùng để đăng nhập
  address text,
  phone text,
  tax_code text,
  bank_name text,
  bank_account text,
  bank_branch text,
  print_header text,
  print_footer text,
  discord_webhook_url text,
  printer_address text,
  printer_type text default 'bluetooth',
  auto_backup boolean not null default false,       -- tự động sao lưu lên đám mây
  last_backup_at timestamptz,                        -- lần sao lưu tự động cuối
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- PROFILES (mọi tài khoản: chủ cửa hàng + nhân viên) ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  store_id uuid references public.stores(id) on delete cascade,
  full_name text not null,
  phone text,
  role public.user_role not null default 'technician',
  username text unique,          -- dùng để nhân viên đăng nhập (không cần email/gmail)
  is_active boolean not null default true,
  avatar_url text,
  fcm_token text,                -- token push notification (Firebase)
  discord_id text,               -- tài khoản Discord nhận webhook
  commission_rate numeric(5,2) default 0,
  commission_type text check (commission_type in ('labor_fixed', 'profit_pct')),
  commission_amount numeric(14,0) default 0,
  created_at timestamptz not null default now()
);

-- ---------- CUSTOMERS ----------
create table public.customers (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  phone text,
  address text,
  note text,
  customer_type text not null default 'retail' check (customer_type in ('retail', 'wholesale')),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id)
);
create index on public.customers (store_id);

-- ---------- REPAIR ORDERS (đơn sửa chữa) ----------
create table public.repair_orders (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  code text not null,                         -- mã đơn, ví dụ SC-120726001
  customer_id uuid references public.customers(id),
  device_model text,                        -- model máy, ví dụ iPhone 13
  imei text,
  issue_description text,
  note text,                                  -- ghi chú thêm
  photo_front_path text,                      -- ảnh mặt trước, lưu trong Storage bucket "repair-photos"
  photo_back_path text,                       -- ảnh mặt sau
  status public.repair_status not null default 'received',
  status_changed_at timestamptz not null default now(),  -- lần cuối đổi trạng thái, dùng để tính "ì" bao lâu
  aging_alert_level int not null default 0,               -- mức cảnh báo đã gửi (0/2/5/7 ngày) tránh spam thông báo lặp
  technician_id uuid references public.profiles(id),   -- người đang được giao (có thể đổi sau, VD lễ tân nhận trả máy)
  repaired_by uuid references public.profiles(id),      -- người thực sự sửa máy tại thời điểm chuyển "đã sửa xong" — dùng để tính đúng doanh thu/lợi nhuận theo KTV, không bị ghi đè sau đó
  received_by uuid references public.profiles(id),
  estimated_cost numeric(14,0) default 0,
  final_cost numeric(14,0) default 0,
  payment_method text,                        -- 'cash' | 'transfer'
  paid_at timestamptz,
  warranty_days int default 0,
  received_at timestamptz not null default now(),
  completed_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,                     -- soft delete -> thùng rác (giữ 90 ngày)
  deleted_by uuid references public.profiles(id),
  discord_notified bool not null default false, -- đã gửi Discord webhook chưa
  unique (store_id, code)
);
create index on public.repair_orders (store_id, status);
create index on public.repair_orders (technician_id);

-- lịch sử thay đổi trạng thái đơn
create table public.repair_order_status_history (
  id uuid primary key default uuid_generate_v4(),
  repair_order_id uuid not null references public.repair_orders(id) on delete cascade,
  status public.repair_status not null,
  changed_by uuid references public.profiles(id),
  note text,
  changed_at timestamptz not null default now()
);

-- ---------- INVENTORY (kho linh kiện) ----------
create table public.part_categories (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (store_id, name)
);

create table public.inventory_parts (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  sku text,
  category_id uuid references public.part_categories(id),
  quantity int not null default 0,
  unit_cost numeric(14,0) default 0,
  unit_price numeric(14,0) default 0,
  wholesale_price numeric(14,0) default 0,
  low_stock_threshold int default 3,
  barcode text,
  imei text,
  created_at timestamptz not null default now(),
  updated_at timestamptz default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  unique (store_id, sku)
);

create table public.inventory_transactions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  part_id uuid not null references public.inventory_parts(id) on delete cascade,
  type public.inventory_tx_type not null,
  quantity int not null,
  repair_order_id uuid references public.repair_orders(id),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- ---------- STOCK COUNTS (kiểm kho) ----------
create table public.stock_counts (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  counted_by uuid not null references public.profiles(id),
  part_id uuid not null references public.inventory_parts(id) on delete cascade,
  system_qty int not null default 0,
  actual_qty int not null default 0,
  diff_qty int not null default 0,
  damaged_qty int not null default 0,
  lost_qty int not null default 0,
  note text,
  created_at timestamptz not null default now()
);

-- ---------- FINANCE (tài khoản, công nợ, thu chi, lương) ----------

-- TÀI KHOẢN TIỀN MẶT / NGÂN HÀNG
create table public.cash_accounts (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  type text not null check (type in ('cash', 'bank')),
  account_number text,
  bank_name text,
  balance numeric(14,0) default 0,
  is_active bool default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- CÔNG NỢ (khách hàng / nhà cung cấp)
create table public.debts (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  type text not null check (type in ('customer', 'supplier')),
  contact_name text not null,
  contact_phone text,
  contact_address text,
  total_debt numeric(14,0) default 0,
  note text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table public.debt_transactions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  debt_id uuid not null references public.debts(id) on delete cascade,
  type text not null check (type in ('add', 'pay', 'deduct')),
  amount numeric(14,0) not null,
  description text,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

-- THU CHI / HÓA ĐƠN
create table public.transactions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  type public.tx_type not null,
  category text,                              -- ví dụ: "Sửa chữa", "Nhập kho", "Chi phí mặt bằng"
  amount numeric(14,0) not null,
  description text,
  repair_order_id uuid references public.repair_orders(id),
  account_id uuid references public.cash_accounts(id),
  debt_id uuid references public.debts(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id)
);
create index on public.transactions (store_id, created_at);

-- LƯƠNG & HOA HỒNG KTV
create table public.salary_payments (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  employee_id uuid not null references public.profiles(id),
  period_start date not null,
  period_end date not null,
  commission_type text not null check (commission_type in ('labor_fixed', 'profit_pct')),
  commission_rate numeric(5,2),
  commission_amount numeric(14,0) default 0,
  total_commission numeric(14,0) default 0,
  total_deductions numeric(14,0) default 0,
  net_amount numeric(14,0) default 0,
  order_count int not null default 0,
  assigned_count int not null default 0,   -- số máy được giao (lễ tân: received_by; KTV: technician_id)
  completed_count int not null default 0,  -- số máy hoàn thành (KTV: repaired_by + đã trả máy)
  labor_total numeric(14,0) not null default 0,
  profit_total numeric(14,0) not null default 0,
  pay_method text check (pay_method in ('cash', 'transfer')),
  transaction_id uuid references public.transactions(id),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now(),
  -- Chống trả lương 2 lần trong cùng 1 kỳ cho cùng 1 nhân viên
  unique (store_id, employee_id, period_start)
);

-- ---------- NOTIFICATIONS (lịch sử push) ----------
create table public.notifications (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid references public.profiles(id),   -- null = gửi cả cửa hàng
  title text not null,
  body text,
  data jsonb,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------- QR CODES (biên nhận bảo hành điện tử) ----------
create table public.qr_codes (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  order_id uuid not null references public.repair_orders(id) on delete cascade,
  code text not null,
  warranty_expires_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- EMPLOYEE INVITES (mời nhân viên qua Google) ----------
create table public.employee_invites (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  email text not null,
  full_name text not null,
  role public.user_role not null,
  status text not null default 'pending',  -- 'pending' | 'accepted'
  invited_by uuid references public.profiles(id),
  invited_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (store_id, email)
);

-- =========================================================
-- HELPER FUNCTIONS
-- =========================================================
create or replace function public.current_profile()
returns public.profiles
language sql stable
as $$
  select * from public.profiles where id = auth.uid();
$$;

create or replace function public.current_store_id()
returns uuid
language sql stable
security definer
set search_path = public
as $$
  select store_id from public.profiles where id = auth.uid();
$$;

create or replace function public.current_role()
returns public.user_role
language sql stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Tự tạo profile khi có tài khoản mới: tài khoản ĐẦU TIÊN của hệ thống = chủ cửa hàng (admin),
-- các tài khoản sau mặc định role 'technician' (sẽ được cấp đúng vai trò qua luồng mời nhân viên).

-- Trừ kho atomic: chỉ trừ khi còn đủ hàng (WHERE quantity >= p_qty),
-- tránh âm kho khi hai thao tác cùng trừ một linh kiện đồng thời.
create or replace function public.decrement_stock(p_part_id uuid, p_qty int)
returns int
language sql
security invoker
as $$
  update public.inventory_parts
     set quantity = quantity - p_qty
   where id = p_part_id and quantity >= p_qty
  returning quantity;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email, 'Chủ cửa hàng'),
    case when first_user then 'admin'::public.user_role else 'technician'::public.user_role end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =========================================================
-- ROW LEVEL SECURITY
-- =========================================================
alter table public.stores enable row level security;
alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.repair_orders enable row level security;
alter table public.repair_order_status_history enable row level security;
alter table public.inventory_parts enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.stock_counts enable row level security;
alter table public.transactions enable row level security;
alter table public.cash_accounts enable row level security;
alter table public.debts enable row level security;
alter table public.debt_transactions enable row level security;
alter table public.salary_payments enable row level security;
alter table public.notifications enable row level security;
alter table public.qr_codes enable row level security;
alter table public.employee_invites enable row level security;
alter table public.part_categories enable row level security;

-- STORES: chủ cửa hàng xem/sửa cửa hàng của mình; nhân viên xem được cửa hàng mình thuộc về
create policy "store_select" on public.stores
  for select using (owner_id = auth.uid() or id = public.current_store_id());
create policy "store_insert" on public.stores
  for insert with check (owner_id = auth.uid());
create policy "store_update" on public.stores
  for update using (owner_id = auth.uid());

-- PROFILES: xem các profile cùng cửa hàng; tự sửa profile của mình; admin sửa nhân viên cùng cửa hàng
create policy "profiles_select_same_store" on public.profiles
  for select using (store_id = public.current_store_id() or id = auth.uid());
create policy "profiles_insert_self" on public.profiles
  for insert with check (id = auth.uid());
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid())
  with check (
    id = auth.uid()
    and role = (select role from profiles where id = auth.uid())
    and (
      -- (a) Giữ nguyên store_id (đổi tên, SĐT, avatar, ...)
      (store_id is not distinct from (select store_id from profiles where id = auth.uid()))
      or
      -- (b) Lần đầu gán store_id khi tạo cửa hàng: hiện chưa thuộc store
      --     nào VÀ store được gán do chính mình tạo.
      (
        (select store_id from profiles where id = auth.uid()) is null
        and exists (
          select 1 from public.stores
          where stores.id = profiles.store_id
            and stores.owner_id = auth.uid()
        )
      )
    )
  );
create policy "profiles_admin_manage" on public.profiles
  for all using (
    public.current_role() = 'admin' and store_id = public.current_store_id()
  );

-- Các bảng nghiệp vụ: chỉ thao tác trong phạm vi store_id của mình.
-- Dòng đã xoá mềm (deleted_at khác null) chỉ admin mới xem/khôi phục được
-- ("thùng rác" chỉ admin truy cập); người khác chỉ update được dòng CHƯA xoá
-- (kể cả để soft-delete nó), không đụng được dòng đã ở trong thùng rác.
create policy "customers_select" on public.customers
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "customers_insert" on public.customers
  for insert with check (store_id = public.current_store_id());
create policy "customers_update" on public.customers
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "customers_delete" on public.customers
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

create policy "repair_orders_select" on public.repair_orders
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "repair_orders_insert" on public.repair_orders
  for insert with check (store_id = public.current_store_id());
create policy "repair_orders_update" on public.repair_orders
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "repair_orders_delete" on public.repair_orders
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

create policy "repair_history_all" on public.repair_order_status_history
  for all using (
    exists (select 1 from public.repair_orders ro
            where ro.id = repair_order_id and ro.store_id = public.current_store_id())
  );

create policy "part_categories_all" on public.part_categories
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

create policy "inventory_parts_select" on public.inventory_parts
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "inventory_parts_insert" on public.inventory_parts
  for insert with check (store_id = public.current_store_id());
create policy "inventory_parts_update" on public.inventory_parts
  for update using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  ) with check (store_id = public.current_store_id());
create policy "inventory_parts_delete" on public.inventory_parts
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

create policy "inventory_tx_all" on public.inventory_transactions
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

-- Thu chi: chỉ admin và lễ tân được thêm/sửa, kỹ thuật viên chỉ xem đơn liên quan (tuỳ chỉnh thêm nếu cần)
create policy "transactions_select" on public.transactions
  for select using (
    store_id = public.current_store_id() and (deleted_at is null or public.current_role() = 'admin')
  );
create policy "transactions_write" on public.transactions
  for insert with check (
    store_id = public.current_store_id()
    and public.current_role() in ('admin','receptionist')
  );
create policy "transactions_update" on public.transactions
  for update using (
    store_id = public.current_store_id()
    and (deleted_at is null or public.current_role() = 'admin')
    and public.current_role() in ('admin','receptionist')
  ) with check (store_id = public.current_store_id());
create policy "transactions_delete" on public.transactions
  for delete using (store_id = public.current_store_id() and public.current_role() = 'admin');

-- STOCK COUNTS: người cùng cửa hàng đọc/ghi
create policy "stock_counts_select" on public.stock_counts
  for select using (exists (
    select 1 from profiles where id = auth.uid() and store_id = stock_counts.store_id
  ));
create policy "stock_counts_insert" on public.stock_counts
  for insert with check (exists (
    select 1 from profiles where id = auth.uid() and store_id = stock_counts.store_id
  ));

-- TÀI KHOẢN TIỀN MẶT / NGÂN HÀNG
create policy "cash_accounts_select" on public.cash_accounts
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));
create policy "cash_accounts_insert" on public.cash_accounts
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));
create policy "cash_accounts_update" on public.cash_accounts
  for update using (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));

-- CÔNG NỢ
create policy "debts_select" on public.debts
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));
create policy "debts_insert" on public.debts
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));
create policy "debts_update" on public.debts
  for update using (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));

create policy "debt_tx_select" on public.debt_transactions
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id));
create policy "debt_tx_insert" on public.debt_transactions
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id));

-- LƯƠNG & HOA HỒNG
create policy "salary_select" on public.salary_payments
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = salary_payments.store_id));
create policy "salary_insert" on public.salary_payments
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = salary_payments.store_id));

-- QR CODES
create policy "qr_codes_select" on public.qr_codes
  for select using (exists (
    select 1 from profiles where id = auth.uid() and store_id = qr_codes.store_id
  ));
create policy "qr_codes_insert" on public.qr_codes
  for insert with check (exists (
    select 1 from profiles where id = auth.uid() and store_id = qr_codes.store_id
  ));

-- ---------- APP LOGS (log hoạt động & lỗi, xem trong Cài đặt → Log) ----------
create table public.app_logs (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid references public.stores(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  level text not null default 'info' check (level in ('info', 'action', 'warning', 'error')),
  category text,
  message text not null,
  data jsonb,
  created_at timestamptz default now()
);

alter table public.app_logs enable row level security;

create policy "app_logs_select" on public.app_logs
  for select using (
    exists (select 1 from profiles where id = auth.uid() and store_id = app_logs.store_id)
  );

create policy "app_logs_insert" on public.app_logs
  for insert with check (
    exists (select 1 from profiles where id = auth.uid() and store_id = app_logs.store_id)
  );

create policy "notifications_all" on public.notifications
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

-- EMPLOYEE INVITES: admin của cửa hàng quản lý toàn bộ lời mời
create policy "employee_invites_admin_manage" on public.employee_invites
  for all using (
    store_id = public.current_store_id() and public.current_role() = 'admin'
  )
  with check (
    store_id = public.current_store_id() and public.current_role() = 'admin'
  );

-- Người được mời (theo email khớp với JWT) có thể xem và tự đánh dấu đã chấp nhận
-- lời mời của chính mình, kể cả trước khi họ có store_id (lần đăng nhập đầu tiên).
create policy "employee_invites_self_view" on public.employee_invites
  for select using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')));
create policy "employee_invites_self_accept" on public.employee_invites
  for update using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')))
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '__none__')));

-- =========================================================
-- REALTIME
-- =========================================================
alter publication supabase_realtime add table public.repair_orders;
alter publication supabase_realtime add table public.repair_order_status_history;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.qr_codes;
alter publication supabase_realtime add table public.employee_invites;
alter publication supabase_realtime add table public.inventory_parts;
alter publication supabase_realtime add table public.inventory_transactions;
alter publication supabase_realtime add table public.stock_counts;
alter publication supabase_realtime add table public.customers;
alter publication supabase_realtime add table public.transactions;
alter publication supabase_realtime add table public.cash_accounts;
alter publication supabase_realtime add table public.debts;
alter publication supabase_realtime add table public.debt_transactions;
alter publication supabase_realtime add table public.salary_payments;
alter publication supabase_realtime add table public.profiles;
alter publication supabase_realtime add table public.part_categories;
alter publication supabase_realtime add table public.app_logs;

-- =========================================================
-- STORAGE: bucket lưu ảnh thiết bị (mặt trước/sau) của đơn sửa chữa
-- =========================================================
insert into storage.buckets (id, name, public)
values ('repair-photos', 'repair-photos', false)
on conflict (id) do nothing;

-- Đường dẫn file quy ước: {store_id}/{order_id}/front.jpg | back.jpg
-- storage.foldername(name) trả về mảng các thư mục cha, phần tử đầu = store_id
create policy "repair_photos_select" on storage.objects
  for select using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
create policy "repair_photos_insert" on storage.objects
  for insert with check (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
create policy "repair_photos_update" on storage.objects
  for update using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
create policy "repair_photos_delete" on storage.objects
  for delete using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

-- =========================================================
-- BACKUP DỰ PHÒNG
-- Bucket "backups" (private) lưu file backup JSON của cửa hàng.
-- Đường dẫn file: {store_id}/backup_<timestamp>.json — chỉ admin truy cập.
-- RPC restore_store_data: khôi phục dữ liệu (atomic, 1 transaction).
-- =========================================================
insert into storage.buckets (id, name, public)
values ('backups', 'backups', false)
on conflict (id) do nothing;

create policy "backups_admin_select" on storage.objects
  for select using (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
create policy "backups_admin_insert" on storage.objects
  for insert with check (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
create policy "backups_admin_delete" on storage.objects
  for delete using (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

-- Khôi phục toàn bộ dữ liệu cửa hàng từ file backup (atomic).
create or replace function public.restore_store_data(p_store_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb := p_data;
begin
  if not (
    (select public.current_role()) = 'admin'
    and (select public.current_store_id()) = p_store_id
  ) then
    raise exception 'forbidden: chỉ admin của cửa hàng mới được khôi phục dữ liệu';
  end if;

  delete from public.repair_order_status_history
    where repair_order_id in (select id from public.repair_orders where store_id = p_store_id);
  delete from public.qr_codes where store_id = p_store_id;
  delete from public.inventory_transactions where store_id = p_store_id;
  delete from public.stock_counts where store_id = p_store_id;
  delete from public.salary_payments where store_id = p_store_id;
  delete from public.transactions where store_id = p_store_id;
  delete from public.debt_transactions where store_id = p_store_id;
  delete from public.notifications where store_id = p_store_id;
  delete from public.employee_invites where store_id = p_store_id;
  delete from public.debts where store_id = p_store_id;
  delete from public.cash_accounts where store_id = p_store_id;
  delete from public.repair_orders where store_id = p_store_id;
  delete from public.inventory_parts where store_id = p_store_id;
  delete from public.part_categories where store_id = p_store_id;
  delete from public.customers where store_id = p_store_id;

  insert into public.part_categories (id, store_id, name, created_at)
  select x.id, x.store_id, x.name, x.created_at
  from jsonb_to_recordset(coalesce(j->'part_categories', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, created_at timestamptz
  );

  insert into public.customers (id, store_id, name, phone, address, note, customer_type, created_at, deleted_at, deleted_by)
  select x.id, x.store_id, x.name, x.phone, x.address, x.note, x.customer_type, x.created_at, x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'customers', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, phone text, address text, note text,
    customer_type text, created_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.repair_orders (
    id, store_id, code, customer_id, device_model, imei, issue_description,
    note, photo_front_path, photo_back_path, status, status_changed_at, aging_alert_level,
    technician_id, repaired_by, received_by, estimated_cost, final_cost, payment_method,
    paid_at, warranty_days, received_at, completed_at, delivered_at, created_at,
    deleted_at, deleted_by, discord_notified
  )
  select x.id, x.store_id, x.code, x.customer_id, x.device_model, x.imei,
    x.issue_description, x.note, x.photo_front_path, x.photo_back_path,
    x.status::public.repair_status, x.status_changed_at, x.aging_alert_level,
    x.technician_id, x.repaired_by, x.received_by, x.estimated_cost, x.final_cost,
    x.payment_method, x.paid_at, x.warranty_days, x.received_at, x.completed_at,
    x.delivered_at, x.created_at, x.deleted_at, x.deleted_by, x.discord_notified
  from jsonb_to_recordset(coalesce(j->'repair_orders', '[]'::jsonb)) as x(
    id uuid, store_id uuid, code text, customer_id uuid, device_model text,
    imei text, issue_description text, note text, photo_front_path text, photo_back_path text,
    status text, status_changed_at timestamptz, aging_alert_level int,
    technician_id uuid, repaired_by uuid, received_by uuid, estimated_cost numeric,
    final_cost numeric, payment_method text, paid_at timestamptz, warranty_days int,
    received_at timestamptz, completed_at timestamptz, delivered_at timestamptz,
    created_at timestamptz, deleted_at timestamptz, deleted_by uuid, discord_notified boolean
  );

  insert into public.repair_order_status_history (id, repair_order_id, status, changed_by, note, changed_at)
  select x.id, x.repair_order_id, x.status::public.repair_status, x.changed_by, x.note, x.changed_at
  from jsonb_to_recordset(coalesce(j->'repair_order_status_history', '[]'::jsonb)) as x(
    id uuid, repair_order_id uuid, status text, changed_by uuid, note text, changed_at timestamptz
  );

  insert into public.inventory_parts (
    id, store_id, name, sku, category_id, quantity, unit_cost, unit_price, wholesale_price,
    low_stock_threshold, barcode, imei,
    created_at, updated_at, deleted_at, deleted_by
  )
  select x.id, x.store_id, x.name, x.sku, x.category_id, x.quantity, x.unit_cost,
    x.unit_price, x.wholesale_price, x.low_stock_threshold, x.barcode, x.imei,
    x.created_at, x.updated_at, x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'inventory_parts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, sku text, category_id uuid, quantity int,
    unit_cost numeric, unit_price numeric, wholesale_price numeric, low_stock_threshold int,
    barcode text, imei text,
    created_at timestamptz, updated_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.inventory_transactions (
    id, store_id, part_id, type, quantity, repair_order_id, note, created_by, created_at
  )
  select x.id, x.store_id, x.part_id, x.type::public.inventory_tx_type, x.quantity,
    x.repair_order_id, x.note, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'inventory_transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, part_id uuid, type text, quantity int, repair_order_id uuid,
    note text, created_by uuid, created_at timestamptz
  );

  insert into public.stock_counts (
    id, store_id, counted_by, part_id, system_qty, actual_qty, diff_qty, damaged_qty,
    lost_qty, note, created_at
  )
  select x.id, x.store_id, x.counted_by, x.part_id, x.system_qty, x.actual_qty,
    x.diff_qty, x.damaged_qty, x.lost_qty, x.note, x.created_at
  from jsonb_to_recordset(coalesce(j->'stock_counts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, counted_by uuid, part_id uuid, system_qty int, actual_qty int,
    diff_qty int, damaged_qty int, lost_qty int, note text, created_at timestamptz
  );

  insert into public.cash_accounts (
    id, store_id, name, type, account_number, bank_name, balance, is_active,
    created_at, updated_at
  )
  select x.id, x.store_id, x.name, x.type, x.account_number, x.bank_name, x.balance,
    x.is_active, x.created_at, x.updated_at
  from jsonb_to_recordset(coalesce(j->'cash_accounts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, type text, account_number text, bank_name text,
    balance numeric, is_active boolean, created_at timestamptz, updated_at timestamptz
  );

  insert into public.debts (
    id, store_id, type, contact_name, contact_phone, contact_address, total_debt,
    note, created_at, updated_at
  )
  select x.id, x.store_id, x.type, x.contact_name, x.contact_phone, x.contact_address,
    x.total_debt, x.note, x.created_at, x.updated_at
  from jsonb_to_recordset(coalesce(j->'debts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, type text, contact_name text, contact_phone text,
    contact_address text, total_debt numeric, note text, created_at timestamptz,
    updated_at timestamptz
  );

  insert into public.debt_transactions (
    id, store_id, debt_id, type, amount, description, created_by, created_at
  )
  select x.id, x.store_id, x.debt_id, x.type, x.amount, x.description, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'debt_transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, debt_id uuid, type text, amount numeric, description text,
    created_by uuid, created_at timestamptz
  );

  insert into public.transactions (
    id, store_id, type, category, amount, description, repair_order_id, account_id,
    debt_id, created_by, created_at, deleted_at, deleted_by
  )
  select x.id, x.store_id, x.type::public.tx_type, x.category, x.amount, x.description,
    x.repair_order_id, x.account_id, x.debt_id, x.created_by, x.created_at,
    x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, type text, category text, amount numeric, description text,
    repair_order_id uuid, account_id uuid, debt_id uuid, created_by uuid,
    created_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.salary_payments (
    id, store_id, employee_id, period_start, period_end, commission_type, commission_rate,
    commission_amount, total_commission, total_deductions, net_amount, order_count,
    assigned_count, completed_count, labor_total, profit_total, pay_method, transaction_id,
    note, created_by, created_at
  )
  select x.id, x.store_id, x.employee_id, x.period_start, x.period_end, x.commission_type,
    x.commission_rate, x.commission_amount, x.total_commission, x.total_deductions,
    x.net_amount, x.order_count, x.assigned_count, x.completed_count, x.labor_total,
    x.profit_total, x.pay_method, x.transaction_id, x.note, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'salary_payments', '[]'::jsonb)) as x(
    id uuid, store_id uuid, employee_id uuid, period_start date, period_end date,
    commission_type text, commission_rate numeric, commission_amount numeric,
    total_commission numeric, total_deductions numeric, net_amount numeric, order_count int,
    assigned_count int, completed_count int, labor_total numeric, profit_total numeric,
    pay_method text, transaction_id uuid, note text, created_by uuid, created_at timestamptz
  );

  insert into public.qr_codes (id, store_id, order_id, code, warranty_expires_at, created_at)
  select x.id, x.store_id, x.order_id, x.code, x.warranty_expires_at, x.created_at
  from jsonb_to_recordset(coalesce(j->'qr_codes', '[]'::jsonb)) as x(
    id uuid, store_id uuid, order_id uuid, code text, warranty_expires_at timestamptz,
    created_at timestamptz
  );

  insert into public.notifications (id, store_id, user_id, title, body, data, is_read, created_at)
  select x.id, x.store_id, x.user_id, x.title, x.body, x.data, x.is_read, x.created_at
  from jsonb_to_recordset(coalesce(j->'notifications', '[]'::jsonb)) as x(
    id uuid, store_id uuid, user_id uuid, title text, body text, data jsonb,
    is_read boolean, created_at timestamptz
  );

  insert into public.employee_invites (
    id, store_id, email, full_name, role, status, invited_by, invited_at, accepted_at
  )
  select x.id, x.store_id, x.email, x.full_name, x.role::public.user_role, x.status,
    x.invited_by, x.invited_at, x.accepted_at
  from jsonb_to_recordset(coalesce(j->'employee_invites', '[]'::jsonb)) as x(
    id uuid, store_id uuid, email text, full_name text, role text, status text,
    invited_by uuid, invited_at timestamptz, accepted_at timestamptz
  );
end;
$$;

grant execute on function public.restore_store_data(uuid, jsonb) to authenticated;

-- Làm sạch cửa hàng: xóa toàn bộ dữ liệu nghiệp vụ (atomic).
-- KHÔNG xóa: stores, profiles, file backup trong bucket "backups".
create or replace function public.clear_store_data(p_store_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    (select public.current_role()) = 'admin'
    and (select public.current_store_id()) = p_store_id
  ) then
    raise exception 'forbidden: chỉ admin của cửa hàng mới được xóa dữ liệu';
  end if;

  delete from public.repair_order_status_history
    where repair_order_id in (select id from public.repair_orders where store_id = p_store_id);
  delete from public.qr_codes where store_id = p_store_id;
  delete from public.inventory_transactions where store_id = p_store_id;
  delete from public.stock_counts where store_id = p_store_id;
  delete from public.salary_payments where store_id = p_store_id;
  delete from public.transactions where store_id = p_store_id;
  delete from public.debt_transactions where store_id = p_store_id;
  delete from public.notifications where store_id = p_store_id;
  delete from public.employee_invites where store_id = p_store_id;
  delete from public.debts where store_id = p_store_id;
  delete from public.cash_accounts where store_id = p_store_id;
  delete from public.repair_orders where store_id = p_store_id;
  delete from public.inventory_parts where store_id = p_store_id;
  delete from public.part_categories where store_id = p_store_id;
  delete from public.customers where store_id = p_store_id;

  delete from storage.objects
    where bucket_id = 'repair-photos'
      and (storage.foldername(name))[1] = p_store_id::text;
end;
$$;

-- Ép owner = postgres (superuser) để security definer bỏ qua RLS storage.objects.
alter function public.clear_store_data(uuid) owner to postgres;

-- Phòng trường hợp môi trường không chạy với superuser: cấp quyền tường minh
-- cho vai trò chủ sở hữu hàm trên schema/tabel storage.
grant usage on schema storage to postgres;
grant select, delete on table storage.objects to postgres;

grant execute on function public.clear_store_data(uuid) to authenticated;

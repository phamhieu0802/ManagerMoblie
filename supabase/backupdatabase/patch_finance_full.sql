-- Nâng cấp module Tài chính: tài khoản, công nợ, lương & hoa hồng

-- 1. Tài khoản tiền mặt / ngân hàng
create table if not exists public.cash_accounts (
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

-- 2. Công nợ (khách hàng / nhà cung cấp)
create table if not exists public.debts (
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

create table if not exists public.debt_transactions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  debt_id uuid not null references public.debts(id) on delete cascade,
  type text not null check (type in ('add', 'pay', 'deduct')),
  amount numeric(14,0) not null,
  description text,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

-- 3. Lương & hoa hồng KTV
create table if not exists public.salary_payments (
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
  transaction_id uuid references public.transactions(id),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

-- 4. Gắn tài khoản & công nợ vào giao dịch
alter table public.transactions
  add column if not exists account_id uuid references public.cash_accounts(id),
  add column if not exists debt_id uuid references public.debts(id);

-- 5. RLS
alter table public.cash_accounts enable row level security;
alter table public.debts enable row level security;
alter table public.debt_transactions enable row level security;
alter table public.salary_payments enable row level security;

drop policy if exists "cash_accounts_select" on public.cash_accounts;
create policy "cash_accounts_select" on public.cash_accounts
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));
drop policy if exists "cash_accounts_insert" on public.cash_accounts;
create policy "cash_accounts_insert" on public.cash_accounts
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));
drop policy if exists "cash_accounts_update" on public.cash_accounts;
create policy "cash_accounts_update" on public.cash_accounts
  for update using (exists (select 1 from profiles where id = auth.uid() and store_id = cash_accounts.store_id));

drop policy if exists "debts_select" on public.debts;
create policy "debts_select" on public.debts
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));
drop policy if exists "debts_insert" on public.debts;
create policy "debts_insert" on public.debts
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));
drop policy if exists "debts_update" on public.debts;
create policy "debts_update" on public.debts
  for update using (exists (select 1 from profiles where id = auth.uid() and store_id = debts.store_id));

drop policy if exists "debt_tx_select" on public.debt_transactions;
create policy "debt_tx_select" on public.debt_transactions
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id));
drop policy if exists "debt_tx_insert" on public.debt_transactions;
create policy "debt_tx_insert" on public.debt_transactions
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = debt_transactions.store_id));

drop policy if exists "salary_select" on public.salary_payments;
create policy "salary_select" on public.salary_payments
  for select using (exists (select 1 from profiles where id = auth.uid() and store_id = salary_payments.store_id));
drop policy if exists "salary_insert" on public.salary_payments;
create policy "salary_insert" on public.salary_payments
  for insert with check (exists (select 1 from profiles where id = auth.uid() and store_id = salary_payments.store_id));

-- 6. Real-time
do $$ begin
  alter publication supabase_realtime add table public.cash_accounts;
exception when sqlstate '42710' then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.debts;
exception when sqlstate '42710' then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.debt_transactions;
exception when sqlstate '42710' then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.salary_payments;
exception when sqlstate '42710' then null;
end $$;

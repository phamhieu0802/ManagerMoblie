-- Bổ sung cột cho inventory_parts: barcode, imei, brand, compatible_models, location, wholesale_price
-- Chạy: psql -f patch_inventory_fields.sql

alter table public.inventory_parts
  add column if not exists barcode text,
  add column if not exists imei text,
  add column if not exists brand text,
  add column if not exists compatible_models text,
  add column if not exists location text,
  add column if not exists wholesale_price numeric(14,0) default 0,
  add column if not exists updated_at timestamptz default now();

-- Tạo bảng stock_count để ghi nhận kiểm kho
create table if not exists public.stock_counts (
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

-- Cập nhật RLS cho stock_counts
alter table public.stock_counts enable row level security;

drop policy if exists "stock_counts_select" on public.stock_counts;
create policy "stock_counts_select" on public.stock_counts
  for select using (exists (
    select 1 from profiles where id = auth.uid() and store_id = stock_counts.store_id
  ));
drop policy if exists "stock_counts_insert" on public.stock_counts;
create policy "stock_counts_insert" on public.stock_counts
  for insert with check (exists (
    select 1 from profiles where id = auth.uid() and store_id = stock_counts.store_id
  ));

-- Thêm realtime cho stock_counts
do $$ begin
  alter publication supabase_realtime add table public.stock_counts;
exception when sqlstate '42710' then null;
end $$;

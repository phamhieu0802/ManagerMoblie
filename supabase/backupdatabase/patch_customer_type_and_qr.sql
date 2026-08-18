-- Thêm customer_type cho bảng customers (lẻ/sỉ)
alter table public.customers
  add column if not exists customer_type text not null default 'retail'
  check (customer_type in ('retail', 'wholesale'));

-- Bảng QR codes cho biên nhận bảo hành điện tử
create table if not exists public.qr_codes (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  order_id uuid not null references public.repair_orders(id) on delete cascade,
  code text not null,
  warranty_expires_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.qr_codes enable row level security;

drop policy if exists "qr_codes_select" on public.qr_codes;
create policy "qr_codes_select" on public.qr_codes
  for select using (exists (
    select 1 from profiles where id = auth.uid() and store_id = qr_codes.store_id
  ));
drop policy if exists "qr_codes_insert" on public.qr_codes;
create policy "qr_codes_insert" on public.qr_codes
  for insert with check (exists (
    select 1 from profiles where id = auth.uid() and store_id = qr_codes.store_id
  ));

do $$ begin
  alter publication supabase_realtime add table public.qr_codes;
exception when sqlstate '42710' then null;
end $$;

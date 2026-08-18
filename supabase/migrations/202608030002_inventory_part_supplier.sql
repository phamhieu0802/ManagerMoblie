-- Nhà cung cấp (NCC) mặc định của linh kiện trong kho.
alter table public.inventory_parts
  add column if not exists supplier_id uuid,
  add column if not exists supplier_name text;

create index if not exists idx_inventory_parts_supplier_id
  on public.inventory_parts(supplier_id);

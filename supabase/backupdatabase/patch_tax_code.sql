-- Add tax_code column to stores table (missing from original schema)
alter table public.stores
  add column if not exists tax_code text;

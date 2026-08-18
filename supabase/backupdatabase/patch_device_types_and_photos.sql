-- Patch an toàn: KHÔNG xóa dữ liệu. Thêm:
--  1. Bảng device_types (danh sách loại máy quản lý được, giống part_categories)
--  2. Cột ảnh mặt trước/sau cho repair_orders
--  3. Storage bucket "repair-photos" + RLS
--  4. Bù lại RLS cho part_categories (bản patch trước đã tạo bảng nhưng quên
--     bật row level security ở schema.sql gốc — nếu bạn đã chạy patch
--     patch_trash_and_categories.sql trước đó thì bước này chỉ chạy lại vô hại)
-- Chạy trong Supabase Dashboard -> SQL Editor.

create table if not exists public.device_types (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (store_id, name)
);
alter table public.device_types enable row level security;
drop policy if exists "device_types_all" on public.device_types;
create policy "device_types_all" on public.device_types
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

alter table public.part_categories enable row level security;
drop policy if exists "part_categories_all" on public.part_categories;
create policy "part_categories_all" on public.part_categories
  for all using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

alter table public.repair_orders add column if not exists photo_front_path text;
alter table public.repair_orders add column if not exists photo_back_path text;

-- ---------- Storage bucket cho ảnh thiết bị ----------
insert into storage.buckets (id, name, public)
values ('repair-photos', 'repair-photos', false)
on conflict (id) do nothing;

drop policy if exists "repair_photos_select" on storage.objects;
create policy "repair_photos_select" on storage.objects
  for select using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
drop policy if exists "repair_photos_insert" on storage.objects;
create policy "repair_photos_insert" on storage.objects
  for insert with check (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
drop policy if exists "repair_photos_update" on storage.objects;
create policy "repair_photos_update" on storage.objects
  for update using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );
drop policy if exists "repair_photos_delete" on storage.objects;
create policy "repair_photos_delete" on storage.objects
  for delete using (
    bucket_id = 'repair-photos'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

-- ---------- Realtime ----------
do $$
begin
  begin
    alter publication supabase_realtime add table public.device_types;
  exception when duplicate_object then null;
  end;
end $$;

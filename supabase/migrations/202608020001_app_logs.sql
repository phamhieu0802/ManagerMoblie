-- Bảng log hoạt động & lỗi ứng dụng (xem trong Cài đặt → Log)
-- Ghi song song: file local (app_logger.dart) + bảng Supabase này.

create table if not exists public.app_logs (
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

drop policy if exists "app_logs_select" on public.app_logs;
create policy "app_logs_select" on public.app_logs
  for select using (
    exists (select 1 from profiles where id = auth.uid() and store_id = app_logs.store_id)
  );

drop policy if exists "app_logs_insert" on public.app_logs;
create policy "app_logs_insert" on public.app_logs
  for insert with check (
    exists (select 1 from profiles where id = auth.uid() and store_id = app_logs.store_id)
  );

-- Real-time để màn Log cập nhật ngay khi có log mới.
do $$ begin
  alter publication supabase_realtime add table public.app_logs;
exception when sqlstate '42710' then null;
end $$;

-- Patch an toàn: KHÔNG xóa dữ liệu, chỉ sửa function + thêm 1 policy còn thiếu.
-- Chạy trực tiếp trong Supabase Dashboard -> SQL Editor.

-- ============================================================
-- FIX CHÍNH: lỗi "stack depth limit exceeded" (Postgres code 54001)
-- ============================================================
-- Nguyên nhân: current_store_id() / current_role() truy vấn bảng
-- `profiles`, mà bảng `profiles` lại có RLS policy gọi ngược lại 2 hàm
-- này -> đệ quy vô hạn -> tràn stack Postgres mỗi khi query profiles.
-- Cách sửa: đặt SECURITY DEFINER để hàm bỏ qua RLS khi tự truy vấn.

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

-- ============================================================
-- FIX PHỤ: thêm policy INSERT còn thiếu cho profiles (phòng khi
-- trigger handle_new_user không chạy vì lý do nào đó)
-- ============================================================
drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self" on public.profiles
  for insert with check (id = auth.uid());

-- Kiểm tra nhanh sau khi chạy:
-- select * from public.profiles order by created_at desc limit 5;

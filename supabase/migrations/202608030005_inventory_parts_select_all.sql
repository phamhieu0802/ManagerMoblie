-- Sửa lỗi: xóa linh kiện (soft delete) báo thành công nhưng vẫn còn trong kho.
-- Nguyên nhân: policy select chỉ cho đọc row có deleted_at is null (trừ admin)
-- → Supabase Realtime không gửi event UPDATE của row vừa bị xóa cho người dùng
-- không phải admin → màn Kho giữ row cũ, linh kiện vẫn hiển thị.
--
-- Giải pháp: cho phép mọi nhân viên cùng store ĐỌC cả linh kiện đã soft-delete.
-- App đã tự lọc deleted_at == null ở client ở mọi màn hình; việc này chỉ giúp
-- realtime phản hồi đúng và màn Kho tự ẩn linh kiện vừa xóa. Thùng rác vẫn chỉ
-- hiển thị cho Admin (nút Thùng rác chỉ xuất hiện với vai trò admin).
drop policy if exists "inventory_parts_select" on public.inventory_parts;
create policy "inventory_parts_select" on public.inventory_parts
  for select using (
    store_id = public.current_store_id()
  );

-- Patch an toàn: KHÔNG xóa dữ liệu, chỉ thêm cột mới.
-- Chạy trong Supabase Dashboard -> SQL Editor.

alter table public.repair_orders add column if not exists repaired_by uuid references public.profiles(id);

-- Với các đơn cũ đã "đã sửa xong"/"đã trả máy" từ trước khi có cột này,
-- tạm gán repaired_by = technician_id hiện tại (tốt hơn để trống, dù có thể
-- không hoàn toàn chính xác nếu đơn đó đã bị đổi người giao sau khi sửa xong).
update public.repair_orders
set repaired_by = technician_id
where repaired_by is null and status in ('repaired', 'delivered') and technician_id is not null;

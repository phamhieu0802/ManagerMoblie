-- Nâng cấp phiếu lương: đếm riêng "số máy được giao" và "số máy hoàn thành"
-- để màn Lịch sử trả lương + phiếu chi tiết hiển thị đúng.
-- Quy ước: lễ tân được tính khi tạo đơn (received_by); KTV được tính khi
-- đơn được giao cho họ sửa (technician_id) và đã trả máy (delivered).

alter table public.salary_payments
  add column if not exists assigned_count int not null default 0,
  add column if not exists completed_count int not null default 0;

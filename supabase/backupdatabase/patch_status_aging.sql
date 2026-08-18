-- Patch an toàn: KHÔNG xóa dữ liệu, chỉ thêm cột mới cho tính năng
-- "cảnh báo đơn lâu chưa đổi trạng thái" (mã phiếu chuyển màu cam/đỏ/xanh
-- + tự thông báo cho người liên quan).
-- Chạy trong Supabase Dashboard -> SQL Editor.

alter table public.repair_orders add column if not exists status_changed_at timestamptz not null default now();
alter table public.repair_orders add column if not exists aging_alert_level int not null default 0;

-- Với các đơn cũ đã có sẵn trước khi patch này chạy, coi như "vừa đổi trạng
-- thái" tại thời điểm chạy patch (tránh bị báo "ì" ngay lập tức cho toàn bộ
-- dữ liệu cũ). Nếu muốn tính từ received_at gốc, đổi dòng dưới thành:
-- update public.repair_orders set status_changed_at = received_at where true;
update public.repair_orders set status_changed_at = now() where status_changed_at is null;

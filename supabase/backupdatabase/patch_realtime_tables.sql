-- Patch an toàn: KHÔNG xóa dữ liệu, chỉ bật Realtime cho các bảng còn thiếu.
-- Đây là nguyên nhân khiến màn hình Khách hàng / Thu chi / Nhân viên bị
-- treo loading vô hạn: app dùng .stream() (dựa trên Supabase Realtime) để
-- lấy dữ liệu các bảng này, nhưng bảng chưa được thêm vào publication
-- "supabase_realtime" nên kênh không bao giờ subscribe xong -> không bao
-- giờ có dữ liệu trả về.
--
-- Chạy trong Supabase Dashboard -> SQL Editor. An toàn để chạy nhiều lần
-- (sẽ báo lỗi "already member of publication" nếu bảng đã có -- bỏ qua
-- lỗi đó là bình thường, hoặc dùng khối DO bên dưới để tự bỏ qua).

do $$
begin
  begin
    alter publication supabase_realtime add table public.customers;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.transactions;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.profiles;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.inventory_transactions;
  exception when duplicate_object then null;
  end;
end $$;

-- Kiểm tra lại danh sách bảng đã bật realtime:
-- select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';

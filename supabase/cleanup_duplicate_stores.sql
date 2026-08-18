-- Dọn dẹp các dòng "Hieu Smarphone" bị trùng do bug cũ (app bị bấm nhiều
-- lần vì không điều hướng sau khi tạo cửa hàng thành công). Chạy trong
-- Supabase Dashboard -> SQL Editor.

-- B1. Xem profile của bạn hiện đang trỏ store_id nào (đây là dòng ĐÚNG cần giữ lại):
select p.id as user_id, p.full_name, p.store_id, s.store_code, s.created_at
from public.profiles p
left join public.stores s on s.id = p.store_id
where p.id = auth.uid();

-- B2. Xem tất cả các dòng "rác" (cùng owner_id, KHÁC store_id đang được profile trỏ tới):
select id, name, store_code, created_at
from public.stores
where owner_id = auth.uid()
  and id <> (select store_id from public.profiles where id = auth.uid())
order by created_at;

-- B3. Sau khi xác nhận đúng các dòng rác ở B2, xoá chúng:
delete from public.stores
where owner_id = auth.uid()
  and id <> (select store_id from public.profiles where id = auth.uid());

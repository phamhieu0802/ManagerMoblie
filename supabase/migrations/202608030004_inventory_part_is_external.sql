-- Đánh dấu linh kiện ngoài (tạo tự động khi "Thêm linh kiện" trong đơn sửa,
-- mua riêng cho 1 đơn). Khi đơn không dùng nữa (hủy/bỏ khỏi đơn) thì bản ghi
-- này sẽ được xóa khỏi kho (soft delete), không để lại linh kiện "ảo".
alter table public.inventory_parts
  add column if not exists is_external boolean not null default false;

create index if not exists idx_inventory_parts_external
  on public.inventory_parts(is_external) where is_external = true;

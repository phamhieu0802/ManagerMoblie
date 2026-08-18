-- Làm sạch cửa hàng: xóa TOÀN BỘ dữ liệu nghiệp vụ của cửa hàng
-- (khách, đơn, kho, thu chi, công nợ, lương, QR, thông báo, mời nhân viên...)
-- trong 1 transaction (lỗi giữa chừng thì hoàn tác toàn bộ).
--
-- KHÔNG xóa: bảng stores, profiles (tài khoản đăng nhập), file backup trong
-- bucket "backups" (để người dùng còn có thể khôi phục lại nếu cần).
-- Có xóa ảnh thiết bị trong bucket "repair-photos" của cửa hàng.
--
-- FIX 42501: nếu hàm được tạo bởi vai trò không phải superuser (hoặc owner cũ
-- không có quyền), câu `delete from storage.objects` bên trong sẽ bị từ chối.
-- Ép chủ sở hữu về postgres + cấp quyền tường minh để chạy được ở mọi môi trường.

create or replace function public.clear_store_data(p_store_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    (select public.current_role()) = 'admin'
    and (select public.current_store_id()) = p_store_id
  ) then
    raise exception 'forbidden: chỉ admin của cửa hàng mới được xóa dữ liệu';
  end if;

  delete from public.repair_order_status_history
    where repair_order_id in (select id from public.repair_orders where store_id = p_store_id);
  delete from public.qr_codes where store_id = p_store_id;
  delete from public.inventory_transactions where store_id = p_store_id;
  delete from public.stock_counts where store_id = p_store_id;
  delete from public.salary_payments where store_id = p_store_id;
  delete from public.transactions where store_id = p_store_id;
  delete from public.debt_transactions where store_id = p_store_id;
  delete from public.notifications where store_id = p_store_id;
  delete from public.employee_invites where store_id = p_store_id;
  delete from public.debts where store_id = p_store_id;
  delete from public.cash_accounts where store_id = p_store_id;
  delete from public.repair_orders where store_id = p_store_id;
  delete from public.inventory_parts where store_id = p_store_id;
  delete from public.part_categories where store_id = p_store_id;
  delete from public.device_types where store_id = p_store_id;
  delete from public.customers where store_id = p_store_id;

  -- Xóa ảnh thiết bị của cửa hàng trong Storage (bucket repair-photos).
  delete from storage.objects
    where bucket_id = 'repair-photos'
      and (storage.foldername(name))[1] = p_store_id::text;
end;
$$;

-- Ép owner = postgres (superuser) để security definer bỏ qua RLS storage.objects.
alter function public.clear_store_data(uuid) owner to postgres;

-- Phòng trường hợp môi trường không chạy với superuser: cấp quyền tường minh
-- cho vai trò chủ sở hữu hàm trên schema/tabel storage.
grant usage on schema storage to postgres;
grant select, delete on table storage.objects to postgres;

grant execute on function public.clear_store_data(uuid) to authenticated;

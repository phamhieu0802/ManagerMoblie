-- Fix clear_store_data: thêm xóa app_logs, giữ nguyên profiles + stores.
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

  -- Con trước cha
  delete from public.repair_order_status_history
    where repair_order_id in (select id from public.repair_orders where store_id = p_store_id);
  delete from public.qr_codes where store_id = p_store_id;
  delete from public.salary_payments where store_id = p_store_id;
  delete from public.debt_transactions where store_id = p_store_id;
  delete from public.inventory_transactions where store_id = p_store_id;
  delete from public.stock_counts where store_id = p_store_id;
  delete from public.transactions where store_id = p_store_id;
  delete from public.notifications where store_id = p_store_id;
  delete from public.employee_invites where store_id = p_store_id;
  delete from public.debts where store_id = p_store_id;
  delete from public.repair_orders where store_id = p_store_id;
  delete from public.inventory_parts where store_id = p_store_id;
  delete from public.part_categories where store_id = p_store_id;
  delete from public.customers where store_id = p_store_id;
  delete from public.cash_accounts where store_id = p_store_id;

  -- Logs
  delete from public.app_logs where store_id = p_store_id;

  -- KHÔNG xóa: profiles (giữ admin), stores (giữ thông tin cửa hàng)
end;
$$;

alter function public.clear_store_data(uuid) owner to postgres;
grant execute on function public.clear_store_data(uuid) to authenticated;

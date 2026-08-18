-- Backup dự phòng: bucket storage + RPC khôi phục dữ liệu (atomic) + cột auto-backup.
-- =========================================================
-- 1) Cột auto backup trên bảng stores
-- =========================================================
alter table public.stores
  add column if not exists auto_backup boolean not null default false;
alter table public.stores
  add column if not exists last_backup_at timestamptz;

-- =========================================================
-- 2) Bucket 'backups' (private) — chỉ admin của cửa hàng truy cập
--    Đường dẫn file: {store_id}/backup_<timestamp>.json
-- =========================================================
insert into storage.buckets (id, name, public)
values ('backups', 'backups', false)
on conflict (id) do nothing;

drop policy if exists "backups_admin_select" on storage.objects;
create policy "backups_admin_select" on storage.objects
  for select using (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

drop policy if exists "backups_admin_insert" on storage.objects;
create policy "backups_admin_insert" on storage.objects
  for insert with check (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

drop policy if exists "backups_admin_delete" on storage.objects;
create policy "backups_admin_delete" on storage.objects
  for delete using (
    bucket_id = 'backups'
    and public.current_role() = 'admin'
    and (storage.foldername(name))[1] = public.current_store_id()::text
  );

-- =========================================================
-- 3) RPC khôi phục dữ liệu
--    - Chỉ admin của đúng cửa hàng (kiểm tra qua JWT) mới chạy được.
--    - Chạy trong 1 transaction: nếu lỗi giữa chừng thì TẤT CẢ hoàn tác,
--      không để dữ liệu khôi phục dở dang.
--    - Xoá sạch dữ liệu cũ của cửa hàng rồi chèn lại toàn bộ từ backup.
--    - KHÔNG xoá/ghi profiles (tài khoản nhân viên), tránh xung đột auth.
-- =========================================================
create or replace function public.restore_store_data(p_store_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb := p_data;
begin
  if not (
    (select public.current_role()) = 'admin'
    and (select public.current_store_id()) = p_store_id
  ) then
    raise exception 'forbidden: chỉ admin của cửa hàng mới được khôi phục dữ liệu';
  end if;

  -- ---------- XOÁ DỮ LIỆU CŨ (thứ tự: con trước cha) ----------
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

  -- ---------- CHÈN LẠI DỮ LIỆU (thứ tự: cha trước con) ----------
  insert into public.device_types (id, store_id, name, created_at)
  select x.id, x.store_id, x.name, x.created_at
  from jsonb_to_recordset(coalesce(j->'device_types', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, created_at timestamptz
  );

  insert into public.part_categories (id, store_id, name, created_at)
  select x.id, x.store_id, x.name, x.created_at
  from jsonb_to_recordset(coalesce(j->'part_categories', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, created_at timestamptz
  );

  insert into public.customers (id, store_id, name, phone, address, note, customer_type, created_at, deleted_at, deleted_by)
  select x.id, x.store_id, x.name, x.phone, x.address, x.note, x.customer_type, x.created_at, x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'customers', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, phone text, address text, note text,
    customer_type text, created_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.repair_orders (
    id, store_id, code, customer_id, device_type, device_model, imei, issue_description,
    note, photo_front_path, photo_back_path, status, status_changed_at, aging_alert_level,
    technician_id, repaired_by, received_by, estimated_cost, final_cost, payment_method,
    paid_at, warranty_days, received_at, completed_at, delivered_at, created_at,
    deleted_at, deleted_by, discord_notified
  )
  select x.id, x.store_id, x.code, x.customer_id, x.device_type, x.device_model, x.imei,
    x.issue_description, x.note, x.photo_front_path, x.photo_back_path,
    x.status::public.repair_status, x.status_changed_at, x.aging_alert_level,
    x.technician_id, x.repaired_by, x.received_by, x.estimated_cost, x.final_cost,
    x.payment_method, x.paid_at, x.warranty_days, x.received_at, x.completed_at,
    x.delivered_at, x.created_at, x.deleted_at, x.deleted_by, x.discord_notified
  from jsonb_to_recordset(coalesce(j->'repair_orders', '[]'::jsonb)) as x(
    id uuid, store_id uuid, code text, customer_id uuid, device_type text, device_model text,
    imei text, issue_description text, note text, photo_front_path text, photo_back_path text,
    status text, status_changed_at timestamptz, aging_alert_level int,
    technician_id uuid, repaired_by uuid, received_by uuid, estimated_cost numeric,
    final_cost numeric, payment_method text, paid_at timestamptz, warranty_days int,
    received_at timestamptz, completed_at timestamptz, delivered_at timestamptz,
    created_at timestamptz, deleted_at timestamptz, deleted_by uuid, discord_notified boolean
  );

  insert into public.repair_order_status_history (id, repair_order_id, status, changed_by, note, changed_at)
  select x.id, x.repair_order_id, x.status::public.repair_status, x.changed_by, x.note, x.changed_at
  from jsonb_to_recordset(coalesce(j->'repair_order_status_history', '[]'::jsonb)) as x(
    id uuid, repair_order_id uuid, status text, changed_by uuid, note text, changed_at timestamptz
  );

  insert into public.inventory_parts (
    id, store_id, name, sku, category_id, quantity, unit_cost, unit_price, wholesale_price,
    low_stock_threshold, barcode, imei, brand, compatible_models, location,
    created_at, updated_at, deleted_at, deleted_by
  )
  select x.id, x.store_id, x.name, x.sku, x.category_id, x.quantity, x.unit_cost,
    x.unit_price, x.wholesale_price, x.low_stock_threshold, x.barcode, x.imei, x.brand,
    x.compatible_models, x.location, x.created_at, x.updated_at, x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'inventory_parts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, sku text, category_id uuid, quantity int,
    unit_cost numeric, unit_price numeric, wholesale_price numeric, low_stock_threshold int,
    barcode text, imei text, brand text, compatible_models text, location text,
    created_at timestamptz, updated_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.inventory_transactions (
    id, store_id, part_id, type, quantity, repair_order_id, note, created_by, created_at
  )
  select x.id, x.store_id, x.part_id, x.type::public.inventory_tx_type, x.quantity,
    x.repair_order_id, x.note, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'inventory_transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, part_id uuid, type text, quantity int, repair_order_id uuid,
    note text, created_by uuid, created_at timestamptz
  );

  insert into public.stock_counts (
    id, store_id, counted_by, part_id, system_qty, actual_qty, diff_qty, damaged_qty,
    lost_qty, note, created_at
  )
  select x.id, x.store_id, x.counted_by, x.part_id, x.system_qty, x.actual_qty,
    x.diff_qty, x.damaged_qty, x.lost_qty, x.note, x.created_at
  from jsonb_to_recordset(coalesce(j->'stock_counts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, counted_by uuid, part_id uuid, system_qty int, actual_qty int,
    diff_qty int, damaged_qty int, lost_qty int, note text, created_at timestamptz
  );

  insert into public.cash_accounts (
    id, store_id, name, type, account_number, bank_name, balance, is_active,
    created_at, updated_at
  )
  select x.id, x.store_id, x.name, x.type, x.account_number, x.bank_name, x.balance,
    x.is_active, x.created_at, x.updated_at
  from jsonb_to_recordset(coalesce(j->'cash_accounts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, name text, type text, account_number text, bank_name text,
    balance numeric, is_active boolean, created_at timestamptz, updated_at timestamptz
  );

  insert into public.debts (
    id, store_id, type, contact_name, contact_phone, contact_address, total_debt,
    note, created_at, updated_at
  )
  select x.id, x.store_id, x.type, x.contact_name, x.contact_phone, x.contact_address,
    x.total_debt, x.note, x.created_at, x.updated_at
  from jsonb_to_recordset(coalesce(j->'debts', '[]'::jsonb)) as x(
    id uuid, store_id uuid, type text, contact_name text, contact_phone text,
    contact_address text, total_debt numeric, note text, created_at timestamptz,
    updated_at timestamptz
  );

  insert into public.debt_transactions (
    id, store_id, debt_id, type, amount, description, created_by, created_at
  )
  select x.id, x.store_id, x.debt_id, x.type, x.amount, x.description, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'debt_transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, debt_id uuid, type text, amount numeric, description text,
    created_by uuid, created_at timestamptz
  );

  insert into public.transactions (
    id, store_id, type, category, amount, description, repair_order_id, account_id,
    debt_id, created_by, created_at, deleted_at, deleted_by
  )
  select x.id, x.store_id, x.type::public.tx_type, x.category, x.amount, x.description,
    x.repair_order_id, x.account_id, x.debt_id, x.created_by, x.created_at,
    x.deleted_at, x.deleted_by
  from jsonb_to_recordset(coalesce(j->'transactions', '[]'::jsonb)) as x(
    id uuid, store_id uuid, type text, category text, amount numeric, description text,
    repair_order_id uuid, account_id uuid, debt_id uuid, created_by uuid,
    created_at timestamptz, deleted_at timestamptz, deleted_by uuid
  );

  insert into public.salary_payments (
    id, store_id, employee_id, period_start, period_end, commission_type, commission_rate,
    commission_amount, total_commission, total_deductions, net_amount, order_count,
    assigned_count, completed_count, labor_total, profit_total, pay_method, transaction_id,
    note, created_by, created_at
  )
  select x.id, x.store_id, x.employee_id, x.period_start, x.period_end, x.commission_type,
    x.commission_rate, x.commission_amount, x.total_commission, x.total_deductions,
    x.net_amount, x.order_count, x.assigned_count, x.completed_count, x.labor_total,
    x.profit_total, x.pay_method, x.transaction_id, x.note, x.created_by, x.created_at
  from jsonb_to_recordset(coalesce(j->'salary_payments', '[]'::jsonb)) as x(
    id uuid, store_id uuid, employee_id uuid, period_start date, period_end date,
    commission_type text, commission_rate numeric, commission_amount numeric,
    total_commission numeric, total_deductions numeric, net_amount numeric, order_count int,
    assigned_count int, completed_count int, labor_total numeric, profit_total numeric,
    pay_method text, transaction_id uuid, note text, created_by uuid, created_at timestamptz
  );

  insert into public.qr_codes (id, store_id, order_id, code, warranty_expires_at, created_at)
  select x.id, x.store_id, x.order_id, x.code, x.warranty_expires_at, x.created_at
  from jsonb_to_recordset(coalesce(j->'qr_codes', '[]'::jsonb)) as x(
    id uuid, store_id uuid, order_id uuid, code text, warranty_expires_at timestamptz,
    created_at timestamptz
  );

  insert into public.notifications (id, store_id, user_id, title, body, data, is_read, created_at)
  select x.id, x.store_id, x.user_id, x.title, x.body, x.data, x.is_read, x.created_at
  from jsonb_to_recordset(coalesce(j->'notifications', '[]'::jsonb)) as x(
    id uuid, store_id uuid, user_id uuid, title text, body text, data jsonb,
    is_read boolean, created_at timestamptz
  );

  insert into public.employee_invites (
    id, store_id, email, full_name, role, status, invited_by, invited_at, accepted_at
  )
  select x.id, x.store_id, x.email, x.full_name, x.role::public.user_role, x.status,
    x.invited_by, x.invited_at, x.accepted_at
  from jsonb_to_recordset(coalesce(j->'employee_invites', '[]'::jsonb)) as x(
    id uuid, store_id uuid, email text, full_name text, role text, status text,
    invited_by uuid, invited_at timestamptz, accepted_at timestamptz
  );
end;
$$;

grant execute on function public.restore_store_data(uuid, jsonb) to authenticated;

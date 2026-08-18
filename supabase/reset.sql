-- =========================================================
-- CHẠY FILE NÀY TRƯỚC, SAU ĐÓ MỚI CHẠY LẠI schema.sql
-- Mục đích: xóa sạch bảng/type/function cũ (nếu lần chạy trước bị lỗi giữa chừng)
-- An toàn cho project mới (chưa có dữ liệu thật) — KHÔNG chạy trên project đã có dữ liệu quan trọng.
-- =========================================================

drop table if exists public.employees cascade;
drop table if exists public.fcm_tokens cascade;
drop table if exists public.notifications cascade;
drop table if exists public.qr_codes cascade;
drop table if exists public.employee_invites cascade;
drop table if exists public.salary_payments cascade;
drop table if exists public.stock_counts cascade;
drop table if exists public.transactions cascade;
drop table if exists public.debt_transactions cascade;
drop table if exists public.debts cascade;
drop table if exists public.cash_accounts cascade;
drop table if exists public.inventory_transactions cascade;
drop table if exists public.inventory_parts cascade;
drop table if exists public.part_categories cascade;
drop table if exists public.repair_order_status_history cascade;
drop table if exists public.repair_orders cascade;
drop table if exists public.customers cascade;
drop table if exists public.app_logs cascade;
drop table if exists public.profiles cascade;
drop table if exists public.stores cascade;

drop function if exists public.handle_new_user() cascade;
drop function if exists public.current_profile() cascade;
drop function if exists public.current_store_id() cascade;
drop function if exists public.current_role() cascade;

drop trigger if exists on_auth_user_created on auth.users;

drop policy if exists "repair_photos_select" on storage.objects;
drop policy if exists "repair_photos_insert" on storage.objects;
drop policy if exists "repair_photos_update" on storage.objects;
drop policy if exists "repair_photos_delete" on storage.objects;

drop type if exists public.user_role cascade;
drop type if exists public.repair_status cascade;
drop type if exists public.tx_type cascade;
drop type if exists public.inventory_tx_type cascade;

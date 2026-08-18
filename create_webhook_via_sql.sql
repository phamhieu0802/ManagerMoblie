-- Tạo Database Webhook: send-push-on-notification
-- Bảng: notifications | Sự kiện: INSERT | Gọi Edge Function: send-push
--
-- THAY THẾ <YOUR_SERVICE_ROLE_KEY> bằng service_role key của project trước khi chạy.
-- Lấy key: Supabase Dashboard → Settings → API → service_role (secret)

-- 1. Tạo schema cho Supabase Functions (nếu chưa có)
CREATE SCHEMA IF NOT EXISTS supabase_functions;

-- 2. Tạo function HTTP request
CREATE OR REPLACE FUNCTION supabase_functions.http_request()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  request_id bigint;
  json_body jsonb;
BEGIN
  json_body := jsonb_build_object(
    'old_record', CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE NULL END,
    'record', CASE WHEN TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN to_jsonb(NEW) ELSE NULL END,
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA
  );

  SELECT INTO request_id
    net.http_post(
      url    := current_setting('request.jwt.claims', true)::json->>'supabase_url',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', current_setting('request.jwt.claims', true)::json->>'authorization'
      ),
      body := json_body::text
    );

  RETURN NULL;
END;
$$;

-- 3. Webhook trỏ đến Edge Function send-push
-- Chạy SQL này trong SQL Editor trên Supabase Dashboard:
--   Thay YOUR_SERVICE_ROLE_KEY bằng service_role key thật

-- Cách đơn giản nhất: dùng Dashboard → Database → Webhooks → New webhook
--   - Name: send-push-on-notification
--   - Table: notifications
--   - Events: Insert
--   - Type: HTTP Request
--   - Method: POST
--   - URL: https://YOUR_PROJECT.supabase.co/functions/v1/send-push
--   - Headers: Authorization: Bearer YOUR_SERVICE_ROLE_KEY

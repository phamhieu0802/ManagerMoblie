-- Fix RLS: policy "profiles_update_self" trước đây chặn tuyệt đối việc
-- đổi store_id của chính mình, làm vỡ luồng TẠO CỬA HÀNG mới
-- (profile.store_id từ NULL -> store vừa tạo) -> lỗi 42501
-- "new row violates row-level security policy for table profiles".
--
-- Vẫn giữ bảo mật: role KHÔNG đổi; store_id chỉ được gán LẦN ĐẦU
-- (từ NULL) và chỉ gán đúng store mà mình là owner.

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid())
  with check (
    id = auth.uid()
    and role = (select role from profiles where id = auth.uid())
    and (
      -- (a) Giữ nguyên store_id (đổi tên, SĐT, avatar, ...)
      (store_id is not distinct from (select store_id from profiles where id = auth.uid()))
      or
      -- (b) Lần đầu gán store_id khi tạo cửa hàng:
      --     hiện chưa thuộc store nào VÀ store được gán do chính mình tạo.
      (
        (select store_id from profiles where id = auth.uid()) is null
        and exists (
          select 1 from public.stores
          where stores.id = profiles.store_id
            and stores.owner_id = auth.uid()
        )
      )
    )
  );

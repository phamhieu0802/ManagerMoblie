// Supabase Edge Function: invite-employee-google
// Chỉ admin (chủ cửa hàng) được gọi hàm này để mời nhân viên bằng email Google.
// Luồng: admin nhập email Gmail của nhân viên -> hàm này tạo tài khoản Supabase
// (chưa có mật khẩu) + gửi email mời (Supabase Auth invite email) -> nhân viên
// bấm link xác nhận trong email -> sau đó nhân viên mở app, chọn "Đăng nhập
// nhân viên", nhập mã cửa hàng, rồi đăng nhập bằng Google (cùng email này).
// Vì auth.users đã tồn tại sẵn với email đã xác nhận, Supabase sẽ tự liên kết
// (link) danh tính Google vào đúng tài khoản đó khi email trùng khớp.
//
// Deploy: supabase functions deploy invite-employee-google
// Cần set biến môi trường: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Thiếu token xác thực" }), { status: 401 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Client dùng để xác thực người gọi (admin)
    const callerClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: "Không xác thực được người dùng" }), { status: 401 });
    }

    const { data: callerProfile, error: profileErr } = await callerClient
      .from("profiles")
      .select("role, store_id")
      .eq("id", user.id)
      .single();

    if (profileErr || !callerProfile || callerProfile.role !== "admin") {
      return new Response(JSON.stringify({ error: "Chỉ admin mới được mời nhân viên" }), { status: 403 });
    }

    const body = await req.json();
    const { email, full_name, role, redirect_to } = body;

    if (!email || !full_name || !role) {
      return new Response(JSON.stringify({ error: "Thiếu thông tin bắt buộc" }), { status: 400 });
    }
    if (!["receptionist", "technician"].includes(role)) {
      return new Response(JSON.stringify({ error: "role không hợp lệ" }), { status: 400 });
    }
    const normalizedEmail = String(email).trim().toLowerCase();

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    // Gửi lời mời qua Supabase Auth (tự tạo user + tự gửi email xác nhận có link mời).
    const { data: invited, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
      normalizedEmail,
      {
        data: { full_name },
        redirectTo: redirect_to || undefined,
      },
    );

    // Nếu user email này đã tồn tại từ trước (VD: đã tự đăng ký), Supabase sẽ báo lỗi
    // "User already registered" -> vẫn tiếp tục gán họ vào cửa hàng như nhân viên.
    let userId = invited?.user?.id;
    if (inviteErr && !userId) {
      const { data: existingList } = await adminClient.auth.admin.listUsers();
      const existing = existingList?.users?.find(
        (u) => (u.email ?? "").toLowerCase() === normalizedEmail,
      );
      if (existing) {
        userId = existing.id;
      } else {
        return new Response(JSON.stringify({ error: inviteErr.message }), { status: 400 });
      }
    }

    if (!userId) {
      return new Response(JSON.stringify({ error: "Không tạo được lời mời" }), { status: 400 });
    }

    // Trigger handle_new_user() (nếu là user mới) đã tự tạo 1 profile role=admin
    // -> cập nhật lại đúng vai trò + cửa hàng của nhân viên được mời.
    const { error: upsertErr } = await adminClient
      .from("profiles")
      .update({
        store_id: callerProfile.store_id,
        full_name,
        role,
      })
      .eq("id", userId);

    if (upsertErr) {
      return new Response(JSON.stringify({ error: upsertErr.message }), { status: 400 });
    }

    // Lưu lịch sử lời mời để admin xem trạng thái trong app.
    const { error: inviteRowErr } = await adminClient
      .from("employee_invites")
      .upsert(
        {
          store_id: callerProfile.store_id,
          email: normalizedEmail,
          full_name,
          role,
          status: "pending",
          invited_by: user.id,
          invited_at: new Date().toISOString(),
          accepted_at: null,
        },
        { onConflict: "store_id,email" },
      );

    if (inviteRowErr) {
      return new Response(JSON.stringify({ error: inviteRowErr.message }), { status: 400 });
    }

    return new Response(JSON.stringify({ success: true, user_id: userId }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

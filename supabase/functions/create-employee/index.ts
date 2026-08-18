// Supabase Edge Function: create-employee
// Chỉ admin (chủ cửa hàng) được gọi hàm này để tạo tài khoản nhân viên.
// Nhân viên đăng nhập bằng "username" + "password" (không cần email thật),
// nên ta tạo email giả nội bộ dạng: <username>@<store_code>.employee.local
//
// Deploy: supabase functions deploy create-employee
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

    // Kiểm tra người gọi có phải admin không
    const { data: callerProfile, error: profileErr } = await callerClient
      .from("profiles")
      .select("role, store_id")
      .eq("id", user.id)
      .single();

    if (profileErr || !callerProfile || callerProfile.role !== "admin") {
      return new Response(JSON.stringify({ error: "Chỉ admin mới được thêm nhân viên" }), { status: 403 });
    }

    const body = await req.json();
    const { username, password, full_name, role, phone } = body;

    if (!username || !password || !full_name || !role) {
      return new Response(JSON.stringify({ error: "Thiếu thông tin bắt buộc" }), { status: 400 });
    }
    if (!["receptionist", "technician"].includes(role)) {
      return new Response(JSON.stringify({ error: "role không hợp lệ" }), { status: 400 });
    }
    // Username được dùng để tạo email nội bộ -> chỉ chữ thường, số, gạch dưới.
    if (!/^[a-z0-9_]+$/.test(username)) {
      return new Response(JSON.stringify({ error: "Username chỉ gồm chữ thường, số và gạch dưới (_)" }), { status: 400 });
    }

    // Lấy store_code để tạo email nội bộ + kiểm tra username trùng
    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data: store } = await adminClient
      .from("stores")
      .select("store_code")
      .eq("id", callerProfile.store_id)
      .single();

    const internalEmail = `${username}.${store?.store_code}@employee.local`;

    const { data: created, error: createErr } = await adminClient.auth.admin.createUser({
      email: internalEmail,
      password,
      email_confirm: true,
      user_metadata: { full_name },
    });

    if (createErr || !created?.user) {
      return new Response(JSON.stringify({ error: createErr?.message ?? "Tạo tài khoản thất bại" }), { status: 400 });
    }

    // Trigger handle_new_user() đã tự tạo 1 profile role=admin -> cập nhật lại đúng thông tin nhân viên
    const { error: upsertErr } = await adminClient
      .from("profiles")
      .update({
        store_id: callerProfile.store_id,
        full_name,
        role,
        phone,
        username: `${username}.${store?.store_code}`,
      })
      .eq("id", created.user.id);

    if (upsertErr) {
      return new Response(JSON.stringify({ error: upsertErr.message }), { status: 400 });
    }

    return new Response(JSON.stringify({ success: true, user_id: created.user.id }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

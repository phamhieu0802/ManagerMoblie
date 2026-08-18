import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Thiếu token xác thực" }), { status: 401 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
      return new Response(JSON.stringify({ error: "Chỉ admin mới được cập nhật nhân viên" }), { status: 403 });
    }

    const body = await req.json();
    const { employee_id, commission_rate, commission_type, commission_amount, is_active } = body;

    if (!employee_id) {
      return new Response(JSON.stringify({ error: "Thiếu employee_id" }), { status: 400 });
    }

    if (commission_type !== undefined &&
        !["labor_fixed", "profit_pct", null].includes(commission_type)) {
      return new Response(JSON.stringify({ error: "Cơ chế tính lương không hợp lệ" }), { status: 400 });
    }

    if (commission_amount !== undefined && commission_amount !== null &&
        (typeof commission_amount !== "number" || commission_amount < 0)) {
      return new Response(JSON.stringify({ error: "Số tiền hoa hồng không hợp lệ" }), { status: 400 });
    }

    const updates: Record<string, unknown> = {};
    if (commission_rate !== undefined) updates.commission_rate = commission_rate;
    if (commission_type !== undefined) updates.commission_type = commission_type;
    if (commission_amount !== undefined) updates.commission_amount = commission_amount;
    if (is_active !== undefined) updates.is_active = is_active;

    if (Object.keys(updates).length === 0) {
      return new Response(JSON.stringify({ error: "Không có trường nào để cập nhật" }), { status: 400 });
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    // Xác minh nhân viên thuộc cửa hàng của admin trước khi cập nhật
    // (service role bỏ qua RLS, nên phải tự kiểm tra để không sửa được
    // nhân viên của cửa hàng khác).
    const { data: employeeProfile, error: empErr } = await adminClient
      .from("profiles")
      .select("store_id")
      .eq("id", employee_id)
      .maybeSingle();

    if (empErr) {
      return new Response(JSON.stringify({ error: empErr.message }), { status: 400 });
    }
    if (!employeeProfile || employeeProfile.store_id !== callerProfile.store_id) {
      return new Response(JSON.stringify({ error: "Nhân viên không thuộc cửa hàng của bạn" }), { status: 403 });
    }

    const { error: updateErr } = await adminClient
      .from("profiles")
      .update(updates)
      .eq("id", employee_id);

    if (updateErr) {
      return new Response(JSON.stringify({ error: updateErr.message }), { status: 400 });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

// Supabase Edge Function: send-push
// Được gọi tự động bởi Database Webhook khi có INSERT vào bảng `notifications`
// (Dashboard > Database > Webhooks > tạo webhook trỏ tới function này).
// Function này gửi push qua Firebase Cloud Messaging (HTTP v1 API).
//
// Cần set biến môi trường:
//  - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//  - FCM_PROJECT_ID (project_id trong file service-account của Firebase)
//  - FCM_SERVICE_ACCOUNT_JSON (nội dung JSON service account, dạng chuỗi)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function getAccessToken(serviceAccount: any): Promise<string> {
  // Dùng thư viện google-auth đơn giản qua JWT (rút gọn, có thể thay bằng thư viện chuẩn khi triển khai)
  const { GoogleAuth } = await import("https://esm.sh/google-auth-library@9?target=deno");
  const auth = new GoogleAuth({
    credentials: serviceAccount,
    scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
  });
  const client = await auth.getClient();
  const token = await client.getAccessToken();
  return token.token as string;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload.record; // hàng vừa insert vào bảng notifications

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // Xác định danh sách token cần gửi: 1 user cụ thể hoặc cả cửa hàng
    let query = supabase.from("profiles").select("fcm_token").eq("store_id", record.store_id);
    if (record.user_id) query = query.eq("id", record.user_id);
    const { data: profiles } = await query;

    const tokens = (profiles ?? [])
      .map((p: any) => p.fcm_token)
      .filter((t: string | null) => !!t);

    if (tokens.length === 0) {
      return new Response(JSON.stringify({ skipped: true, reason: "no tokens" }), { status: 200 });
    }

    const serviceAccount = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT_JSON")!);
    const projectId = Deno.env.get("FCM_PROJECT_ID")!;
    const accessToken = await getAccessToken(serviceAccount);

    await Promise.all(
      tokens.map((token: string) =>
        fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: record.title, body: record.body ?? "" },
              data: record.data ?? {},
            },
          }),
        })
      )
    );

    return new Response(JSON.stringify({ sent: tokens.length }), { status: 200 });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

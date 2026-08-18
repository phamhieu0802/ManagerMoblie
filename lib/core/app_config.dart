/// Cấu hình chung của app.
/// Các giá trị bên dưới lấy từ file cofigOAuth.txt bạn đã cung cấp.
/// LƯU Ý: publishable key là an toàn để để trong client (đã được thiết kế cho việc đó),
/// nhưng client secret Google OAuth và Supabase service_role key KHÔNG BAO GIỜ được đưa vào app.
class AppConfig {
  // ---- Supabase ----
  static const supabaseUrl = 'https://rsjonbpkocfylnpdvach.supabase.co';
  static const supabaseAnonKey = 'sb_publishable_KxEC8TOsbbqSi1SNcX42TA_tIqZ6_ew';

  // ---- Google OAuth ----
  // Android dùng Google Sign-In native (account picker),
  // cần Web Client ID để lấy idToken hợp lệ cho Supabase.
  static const googleWebClientId =
      '673017899305-52iugltftlg8b2kt7cimketm1heg31u2.apps.googleusercontent.com';

  static const googleAndroidClientId =
      '673017899305-iam9d16goiikfqqbprkl9ds5lhup3tgf.apps.googleusercontent.com';

  static const androidPackageName = 'com.phonerepair.phone_repair_shop';

  // Deep link callback dùng cho OAuth trên mobile (đã cấu hình trong Supabase URL Configuration)
  static const oauthRedirectUri = 'io.supabase.flutter://login-callback/';
}

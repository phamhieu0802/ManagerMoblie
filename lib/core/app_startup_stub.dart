/// Bản rỗng dùng cho web/nền tảng không có registry (xem app_startup.dart).
/// Hàm tự động mở cùng Windows chỉ có ý nghĩa trên Windows.
Future<bool> isAutoStartEnabled() async => false;

Future<bool> setAutoStartEnabled(bool enabled) async => false;
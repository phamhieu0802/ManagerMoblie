import '../core/supabase_service.dart';

/// Gửi thông báo đến 1 nhân viên cụ thể (user_id) và toàn bộ admin của cửa hàng.
/// Pattern giống repair_orders_list_screen: insert từng dòng vào bảng
/// `notifications`; webhook `send-push` sẽ đẩy FCM nếu đã cấu hình.
Future<void> notifyEmployeeAndAdmins({
  required String storeId,
  required String userId,
  required String title,
  String? body,
  Map<String, dynamic>? data,
}) async {
  final recipients = <String>{userId};
  try {
    final admins = await SupabaseService.client
        .from('profiles')
        .select('id')
        .eq('store_id', storeId)
        .eq('role', 'admin');
    for (final a in admins as List) {
      recipients.add(a['id'] as String);
    }
  } catch (_) {}

  for (final uid in recipients) {
    try {
      await SupabaseService.client.from('notifications').insert({
        'store_id': storeId,
        'user_id': uid,
        'title': title,
        'body': body ?? '',
        if (data != null) 'data': data,
      });
    } catch (_) {}
  }
}

/// Gửi thông báo cho toàn bộ cửa hàng (user_id = null).
Future<void> notifyWholeStore({
  required String storeId,
  required String title,
  String? body,
  Map<String, dynamic>? data,
}) async {
  try {
    await SupabaseService.client.from('notifications').insert({
      'store_id': storeId,
      'user_id': null,
      'title': title,
      'body': body ?? '',
      if (data != null) 'data': data,
    });
  } catch (_) {}
}

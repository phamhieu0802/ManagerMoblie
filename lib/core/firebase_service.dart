import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'supabase_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

class FirebaseService {
  FirebaseService._();

  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static StreamSubscription? _windowsNotificationSub;

  static Future<void> init() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _initAndroid();
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      await _initWindows();
    }
  }

  static Future<void> _initAndroid() async {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit),
    );

    FirebaseMessaging.onMessage.listen(_showAndroidNotification);

    final token = await messaging.getToken();
    if (token != null) await _saveToken(token);
    messaging.onTokenRefresh.listen(_saveToken);
  }

  static Future<void> _initWindows() async {
    try {
      const macInit = DarwinInitializationSettings();
      await _localNotifications.initialize(
        const InitializationSettings(macOS: macInit, iOS: macInit),
      );
    } catch (_) {
      // Local notifications plugin not available on this platform — non-critical
    }

    _windowsNotificationSub = autoReconnectStream(
      () => SupabaseService.client
          .from('notifications')
          .stream(primaryKey: ['id']),
      label: 'notifications_win',
    ).listen(
          (rows) {
            for (final row in rows) {
              final userId = row['user_id'] as String?;
              if (userId != null && userId != SupabaseService.currentUser?.id) continue;
              final title = row['title'] as String? ?? 'Thông báo';
              final body = row['body'] as String? ?? '';
              _showLocalNotification(title, body);
            }
          },
          // Bỏ qua lỗi realtime tạm thời (socket rớt khi reconnect) — không
          // để thành lỗi unhandled; socket tự reconnect và dữ liệu sẽ được tải lại.
          onError: (_) {},
        );
  }

  static void dispose() {
    _windowsNotificationSub?.cancel();
  }

  static Future<void> _saveToken(String token) async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) return;
    await SupabaseService.client
        .from('profiles')
        .update({'fcm_token': token}).eq('id', userId);
  }

  static Future<void> _showAndroidNotification(RemoteMessage message) async {
    const androidDetails = AndroidNotificationDetails(
      'repair_shop_channel',
      'Thông báo cửa hàng',
      importance: Importance.high,
      priority: Priority.high,
    );
    await _localNotifications.show(
      message.hashCode,
      message.notification?.title ?? 'Thông báo',
      message.notification?.body ?? '',
      const NotificationDetails(android: androidDetails),
    );
  }

  static Future<void> _showLocalNotification(String title, String body) async {
    if (defaultTargetPlatform == TargetPlatform.android) return;
    try {
      await _localNotifications.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        const NotificationDetails(),
      );
    } catch (_) {
      // Local notifications not supported on this platform — non-critical
    }
  }
}

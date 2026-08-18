import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'window_focus.dart';

/// OAuth callback qua localhost — ổn định trên Windows hơn custom URL scheme.
class DesktopOAuth {
  DesktopOAuth._();

  static const callbackPort = 3000;
  static const redirectUrl = 'http://localhost:$callbackPort/';

  static Future<void> signInWithGoogle(GoTrueClient auth) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, callbackPort);
    final completer = Completer<void>();

    server.listen((request) async {
      final uri = request.requestedUri;
      final hasAuthParams = uri.queryParameters.containsKey('code') ||
          uri.queryParameters.containsKey('access_token') ||
          uri.queryParameters.containsKey('error');

      if (!hasAuthParams) {
        request.response
          ..statusCode = 404
          ..close();
        return;
      }

      try {
        await auth.getSessionFromUrl(uri);
        if (auth.currentSession == null) {
          throw const AuthException('Không tạo được phiên đăng nhập từ OAuth callback.');
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body style="font-family:sans-serif;text-align:center;padding:48px">'
            '<h2>Đăng nhập thành công</h2>'
            '<p>Bạn có thể đóng tab này và quay lại ứng dụng.</p>'
            '</body></html>',
          );
        await request.response.close();
        bringAppWindowToFront();
        if (!completer.isCompleted) completer.complete();
      } catch (e) {
        request.response
          ..statusCode = 500
          ..headers.contentType = ContentType.html
          ..write('<html><body><h2>Đăng nhập thất bại</h2><p>$e</p></body></html>');
        await request.response.close();
        if (!completer.isCompleted) completer.completeError(e);
      }
    });

    try {
      final launched = await auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw Exception('Không mở được trình duyệt để đăng nhập Google.');
      }

      await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw Exception('Hết thời gian chờ đăng nhập Google. Vui lòng thử lại.'),
      );
    } finally {
      await server.close(force: true);
    }
  }
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32_registry/win32_registry.dart';

/// Đăng ký custom URL scheme trên Windows để nhận OAuth callback.
/// Ví dụ: io.supabase.flutter://login-callback/?code=...
void registerWindowsOAuthProtocol(String scheme) {
  if (kIsWeb || !Platform.isWindows) return;

  final appPath = Platform.resolvedExecutable;
  final protocolRegKey = 'Software\\Classes\\$scheme';
  const protocolRegValue = RegistryValue(
    'URL Protocol',
    RegistryValueType.string,
    '',
  );
  const protocolCmdRegKey = 'shell\\open\\command';
  final protocolCmdRegValue = RegistryValue(
    '',
    RegistryValueType.string,
    '"$appPath" "%1"',
  );

  final regKey = Registry.currentUser.createKey(protocolRegKey);
  regKey.createValue(protocolRegValue);
  regKey.createKey(protocolCmdRegKey).createValue(protocolCmdRegValue);
}

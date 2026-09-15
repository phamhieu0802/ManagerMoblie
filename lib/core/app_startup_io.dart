import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32_registry/win32_registry.dart';

const _runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
const _valueName = 'ManagerMSR';

/// Có đang bật "tự động mở app cùng Windows" hay không (qua registry
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run). Trên nền tảng khác
/// (web, Linux, Android...) luôn trả `false`.
Future<bool> isAutoStartEnabled() async {
  if (kIsWeb || !Platform.isWindows) return false;
  try {
    final key = Registry.currentUser.createKey(_runKeyPath);
    try {
      final value = key.getValueAsString(_valueName);
      return value != null && value.trim().isNotEmpty;
    } finally {
      key.close();
    }
  } catch (_) {
    return false;
  }
}

/// Bật/tắt "tự động mở app cùng Windows". Không ảnh hưởng tới nền tảng khác.
Future<bool> setAutoStartEnabled(bool enabled) async {
  if (kIsWeb || !Platform.isWindows) return false;
  try {
    final key = Registry.currentUser.createKey(_runKeyPath);
    try {
      if (enabled) {
        final exePath = Platform.resolvedExecutable;
        key.createValue(
          RegistryValue(_valueName, RegistryValueType.string, '"$exePath"'),
        );
      } else {
        key.deleteValue(_valueName);
      }
    } finally {
      key.close();
    }
    return true;
  } catch (_) {
    return false;
  }
}
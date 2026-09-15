import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Ghi nhớ kích thước & vị trí cửa sổ app (máy tính để bàn — Windows).
/// Mỗi lần đổi kích thước / di chuyển cửa sổ đều lưu vào SharedPreferences;
/// lần mở sau sẽ khôi phục đúng kích thước & vị trí của phiên làm việc trước.
/// Trên nền tảng không phải desktop (web, Android...) hàm [init] không làm gì.
class WindowStateService {
  WindowStateService._();

  static const _kX = 'window_x';
  static const _kY = 'window_y';
  static const _kWidth = 'window_w';
  static const _kHeight = 'window_h';

  /// Kích thước tối thiểu cho phép khôi phục (tránh lưu nhầm lúc thu nhỏ).
  static const _minWidth = 400.0;
  static const _minHeight = 300.0;

  static Timer? _saveDebounce;

  static Future<void> init() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      return;
    }
    await _restoreSavedBounds();
    windowManager.addListener(_WindowStateListener());
  }

  static Future<void> _restoreSavedBounds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final x = prefs.getDouble(_kX);
      final y = prefs.getDouble(_kY);
      final w = prefs.getDouble(_kWidth);
      final h = prefs.getDouble(_kHeight);
      if (x == null || y == null || w == null || h == null) return;
      if (w < _minWidth || h < _minHeight) return;
      await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
    } catch (_) {
      // Không gây lỗi nếu không khôi phục được.
    }
  }

  static Future<void> _saveCurrentBounds() async {
    try {
      final bounds = await windowManager.getBounds();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kX, bounds.left);
      await prefs.setDouble(_kY, bounds.top);
      await prefs.setDouble(_kWidth, bounds.width);
      await prefs.setDouble(_kHeight, bounds.height);
    } catch (_) {}
  }

  /// Gộp nhiều sự kiện resize/move liên tiếp sync vào 1 lần lưu duy nhất.
  static void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      _saveCurrentBounds();
    });
  }
}

class _WindowStateListener extends WindowListener {
  @override
  void onWindowResized() => WindowStateService._scheduleSave();

  @override
  void onWindowMoved() => WindowStateService._scheduleSave();

  @override
  void onWindowMaximize() => WindowStateService._saveCurrentBounds();

  @override
  void onWindowUnmaximize() => WindowStateService._scheduleSave();
}
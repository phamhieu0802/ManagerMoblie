import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:window_manager/window_manager.dart';

/// Ghi nhớ kích thước & vị trí cửa sổ app (máy tính để bàn — Windows).
///
/// Mỗi lần đổi kích thước / di chuyển cửa sổ đều ghi bounds (logical px) ra file
/// `%APPDATA%\Manager Shop Repair\window_bounds.txt`. Vì sao dùng file thay vì
/// SharedPreferences: `windows/runner/main.cpp` mở cửa sổ TRƯỚC khi Dart chạy —
/// C++ đọc file này và tạo window với đúng kích thước & vị trí ngay từ đầu, nên
/// Flutter engine khởi tạo render surface khớp luôn, tránh hiện tượng mờ/méo khi
/// startup resize (bug DPI scaling của Flutter Windows).
///
/// Trên nền tảng không phải desktop (web, Android...) hàm [init] không làm gì.
class WindowStateService {
  WindowStateService._();

  /// Tên thư mục dưới %APPDATA% (khớp với runner C++).
  static const _dirName = 'Manager Shop Repair';
  static const _fileName = 'window_bounds.txt';

  static Timer? _saveDebounce;

  static Future<void> init() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      return;
    }
    windowManager.addListener(_WindowStateListener());
  }

  static Future<void> _saveCurrentBounds() async {
    try {
      final bounds = await windowManager.getBounds();
      final file = File('${_dirPath()}\\$_fileName');
      await file.parent.create(recursive: true);
      // 4 dòng: x, y, width, height (logical px) — C++ đọc để tạo window.
      await file.writeAsString(
        '${bounds.left}\n${bounds.top}\n${bounds.width}\n${bounds.height}',
      );
    } catch (_) {}
  }

  static String _dirPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return _dirName;
    return '$appData\\$_dirName';
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
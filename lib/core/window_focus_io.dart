import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Tiêu đề cửa sổ native, phải khớp với chuỗi truyền vào `window.Create(...)`
/// trong `windows/runner/main.cpp`.
const _windowTitle = 'Manager Mobile App';

/// Đưa cửa sổ app Windows lên trước (foreground) sau khi trình duyệt hoàn
/// tất đăng nhập Google, để người dùng không phải tự bấm lại vào app.
///
/// Windows mặc định chặn các process nền tự ý cướp foreground
/// ("foreground lock"), nên chỉ gọi SetForegroundWindow là chưa đủ —
/// cần "mượn" input state của thread đang foreground (AttachThreadInput)
/// trước khi gọi, đây là kỹ thuật chuẩn để vượt qua giới hạn này.
void bringAppWindowToFront() {
  if (kIsWeb || !Platform.isWindows) return;

  try {
    final titlePtr = _windowTitle.toNativeUtf16();
    final hwnd = FindWindow(nullptr, titlePtr);
    calloc.free(titlePtr);

    if (hwnd == 0) return;

    if (IsIconic(hwnd) != 0) {
      ShowWindow(hwnd, SW_RESTORE);
    } else {
      ShowWindow(hwnd, SW_SHOW);
    }

    final foregroundHwnd = GetForegroundWindow();
    final foregroundThread = GetWindowThreadProcessId(foregroundHwnd, nullptr);
    final currentThread = GetCurrentThreadId();

    if (foregroundThread != currentThread) {
      AttachThreadInput(foregroundThread, currentThread, 1);
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
      AttachThreadInput(foregroundThread, currentThread, 0);
    } else {
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
    }
  } catch (_) {
    // Không chặn luồng đăng nhập nếu thao tác focus cửa sổ thất bại
    // (VD: chạy trong môi trường không có cửa sổ native, sandbox, v.v.)
  }
}

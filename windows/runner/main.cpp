#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Chuyển deep link OAuth về instance app đang chạy (tránh mở app mới).
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // Mở cửa sổ với kích thước & vị trí phiên trước (nếu có) NGAY TỪ ĐẦU,
  // trước khi Flutter tạo render surface. Tạo window đúng bounds ngay lúc này
  // giúp engine dựng surface khớp kích thước thật — tránh hiện tượng mờ/méo
  // khi bị SetWindowPos resize sau khi Flutter đã khởi tạo (bug DPI scaling).
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1200, 900);
  double saved_x, saved_y, saved_w, saved_h;
  if (LoadWindowBounds(&saved_x, &saved_y, &saved_w, &saved_h)) {
    // Chỉ khôi phục khi kích thước hợp lý (không nhỏ hơn window tối thiểu của app).
    if (saved_w >= 400 && saved_h >= 300) {
      size = Win32Window::Size(static_cast<unsigned int>(saved_w),
                               static_cast<unsigned int>(saved_h));
      // Win32Window::Point dùng unsigned nên bỏ qua tọa độ âm (màn hình trái).
      if (saved_x >= 0 && saved_y >= 0) {
        origin = Win32Window::Point(static_cast<unsigned int>(saved_x),
                                    static_cast<unsigned int>(saved_y));
      }
    }
  }
  if (!window.Create(L"Manager MSR", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

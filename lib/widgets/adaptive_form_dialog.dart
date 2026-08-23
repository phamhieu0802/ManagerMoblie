import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dialog_action_row.dart';

/// Ngưỡng chiều rộng để coi là màn hình "lớn" (desktop/tablet ngang) —
/// dưới ngưỡng này (điện thoại Android) sẽ hiện dialog toàn màn hình để
/// dễ đọc/thao tác hơn thay vì 1 hộp nhỏ giữa màn hình.
const double kWideScreenBreakpoint = 700;

bool isWideScreen(BuildContext context) => MediaQuery.of(context).size.width >= kWideScreenBreakpoint;

/// Hiện 1 dialog dạng form (tiêu đề + nội dung cuộn được + hàng nút hành
/// động cố định dưới cùng), tự thích ứng:
/// - Màn hình rộng (Windows/tablet ngang): hộp thoại lớn, căn giữa, rộng
///   [desktopWidth], cao tối đa theo tỉ lệ màn hình.
/// - Màn hình hẹp (điện thoại Android): toàn màn hình, có AppBar riêng,
///   nút hành động ghim cố định ở đáy — nhìn rõ và dễ bấm hơn nhiều so với
///   hộp thoại thu nhỏ giữa màn hình cảm ứng.
///
/// [contentBuilder] và [actionsBuilder] cùng nhận chung 1 [StateSetter] duy
/// nhất (giống cách dùng StatefulBuilder thông thường) để nội dung nhập và
/// nút hành động (VD: trạng thái "đang lưu", lỗi) luôn đồng bộ với nhau.
typedef AdaptiveDialogContentBuilder = Widget Function(BuildContext context, StateSetter setStateDialog);

/// Chặn mở liên tiếp các dialog form: (1) bấm nhanh/lặp lại trong khoảng thời
/// gian ngắn, (2) bấm mở dialog khác khi 1 dialog đang hiển thị — tránh nhiều
/// dialog chồng lên nhau gây lag máy. Dialog con (allowNested) vẫn được phép.
DateTime? _lastAdaptiveDialogOpenedAt;
int _adaptiveDialogDepth = 0;

Future<T?> showAdaptiveFormDialog<T>({
  required BuildContext context,
  required String title,
  String? titleTrailing,
  required AdaptiveDialogContentBuilder contentBuilder,
  required AdaptiveDialogContentBuilder actionsBuilder,
  double desktopWidth = 460,
  bool barrierDismissible = true,
  bool allowNested = false,
  /// Khi truyền [onEscCancel], phím ESC trong dialog chạy đúng hành động hủy
  /// giống nút Hủy (kèm xác nhận nếu [escIsDirty] trả true). Dùng cho dialog
  /// `barrierDismissible: false` để vẫn đóng được bằng ESC mà không mất/không
  /// rò dữ liệu. Các dialog khác giữ hành vi mặc định của Flutter (ESC đóng
  /// dialog khi barrierDismissible).
  Future<void> Function(BuildContext dialogContext)? onEscCancel,
  bool Function()? escIsDirty,
}) {
  final now = DateTime.now();
  final prev = _lastAdaptiveDialogOpenedAt;
  if (prev != null && now.difference(prev) < const Duration(milliseconds: 350)) {
    return Future.value(null);
  }
  if (!allowNested && _adaptiveDialogDepth > 0) {
    return Future.value(null);
  }
  _lastAdaptiveDialogOpenedAt = now;
  _adaptiveDialogDepth++;

  // Tiêu đề + chuỗi theo sau (VD: "Ngày tạo: dd/mm/yyyy") nằm chung 1 hàng,
  // tiêu đề căn trái, chuỗi phụ căn phải.
  final Widget titleWidget = titleTrailing == null
      ? Text(title)
      : Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(title)),
            const SizedBox(width: 12),
            Text(
              titleTrailing,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.black54),
            ),
          ],
        );

  // Bọc dialog trong CallbackShortcuts khi có onEscCancel để phím ESC chạy
  // hành động hủy (kèm xác nhận nếu đang có dữ liệu thay đổi) — giống hệt nút
  // Hủy của DialogActionRow, tránh hai luồng xác nhận khác nhau.
  Widget wrapEsc(BuildContext dialogContext, Widget dialog) {
    final escCancel = onEscCancel;
    if (escCancel == null) return dialog;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => confirmDiscardChanges(
              dialogContext,
              isDirty: escIsDirty,
              onDiscard: () => escCancel(dialogContext),
            ),
      },
      child: dialog,
    );
  }

  final Future<T?> dialogFuture = isWideScreen(context)
      ? showDialog<T>(
          context: context,
          barrierDismissible: barrierDismissible,
          builder: (ctx) => wrapEsc(
            ctx,
            StatefulBuilder(
              builder: (ctx, setStateDialog) => AlertDialog(
                title: titleWidget,
                contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                content: SizedBox(
                  width: desktopWidth,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
                    child: SingleChildScrollView(child: contentBuilder(ctx, setStateDialog)),
                  ),
                ),
                actions: [actionsBuilder(ctx, setStateDialog)],
                actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              ),
            ),
          ),
        )
      : showDialog<T>(
          context: context,
          barrierDismissible: barrierDismissible,
          useSafeArea: false,
          builder: (ctx) => wrapEsc(
            ctx,
            StatefulBuilder(
              builder: (ctx, setStateDialog) => Dialog.fullscreen(
                child: Scaffold(
                  appBar: AppBar(title: titleWidget),
                  body: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(child: contentBuilder(ctx, setStateDialog)),
                    ),
                  ),
                  bottomNavigationBar: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: actionsBuilder(ctx, setStateDialog),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

  dialogFuture.whenComplete(() => _adaptiveDialogDepth--);
  return dialogFuture;
}

/// Bọc `showDialog` với debounce + depth guard giống [showAdaptiveFormDialog]
/// để tránh mở nhiều dialog thô chồng lên nhau. Dùng cho mọi `showDialog`
/// không đi qua `showAdaptiveFormDialog`.
Future<T?> showDialogGuarded<T>(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
  bool barrierDismissible = true,
}) {
  final now = DateTime.now();
  final prev = _lastAdaptiveDialogOpenedAt;
  if (prev != null && now.difference(prev) < const Duration(milliseconds: 350)) {
    return Future.value(null);
  }
  if (_adaptiveDialogDepth > 0) {
    return Future.value(null);
  }
  _lastAdaptiveDialogOpenedAt = now;
  _adaptiveDialogDepth++;
  final future = showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
  future.whenComplete(() => _adaptiveDialogDepth--);
  return future;
}

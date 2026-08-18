import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hiện 1 panel dạng menu sổ xuống ngay tại vị trí nút bấm (anchor) thay vì
/// bottom sheet từ dưới lên hay dialog giữa màn hình. Nếu phía dưới nút không
/// đủ chỗ (VD nút nằm sát đáy màn hình) thì tự sổ lên trên. Bấm ra ngoài panel
/// sẽ đóng (close(null)).
Future<T?> showAnchorDropdownPanel<T>({
  required BuildContext anchorContext,
  required Widget Function(BuildContext context, void Function(T? value) close) builder,
  double width = 280,
  double estimatedHeight = 240,
}) {
  final overlayState = Overlay.of(anchorContext);
  final overlayBox = overlayState.context.findRenderObject() as RenderBox;
  final box = anchorContext.findRenderObject() as RenderBox;
  // Chuyển vị trí nút về KHÔNG GIAN TỌA ĐỘ của Overlay đang chèn panel. Dùng
  // localToGlobal (tọa độ toàn màn hình) sẽ SAI khi overlay là 1 Navigator con
  // (VD: vùng nội dung cạnh sidebar trên desktop) → panel bị đẩy lệch sang phải
  // theo bề rộng sidebar và "khuyết" ra ngoài app.
  final pos = overlayBox.globalToLocal(box.localToGlobal(Offset.zero));
  final size = box.size;
  final screen = overlayBox.size;
  final panelWidth = math.min(width, screen.width - 16);
  final useAbove = pos.dy + size.height + 4 + estimatedHeight > screen.height;
  final top = useAbove ? math.max(4.0, pos.dy - estimatedHeight - 4) : pos.dy + size.height + 4;

  final completer = Completer<T?>();
  late OverlayEntry entry;
  var removed = false;

  void removeEntry() {
    // Chỉ gọi entry.remove() tối đa 1 lần. Lưu ý: `entry.mounted` vẫn trả true
    // ngay trong frame vừa remove (widget state chưa unmount) nên gọi lần 2 sẽ
    // nổ "Null check operator" ở OverlayEntry.remove.
    if (removed) return;
    removed = true;
    if (entry.mounted) entry.remove();
  }

  void close([T? value]) {
    removeEntry();
    if (!completer.isCompleted) completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => close(null),
          ),
        ),
        Positioned(
          top: top,
          left: (pos.dx + size.width - panelWidth).clamp(8.0, math.max(8.0, screen.width - panelWidth - 8)),
          width: panelWidth,
          // Nhận focus ngay khi mở để phím ESC đóng panel (close(null)) và phím
          // Tab chuyển giữa các ô trong panel. Khi panel đóng, focus quay về nút
          // đã mở nó.
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                close(null);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: builder(ctx, close),
            ),
          ),
        ),
      ],
    ),
  );
  overlayState.insert(entry);
  return completer.future.whenComplete(removeEntry);
}

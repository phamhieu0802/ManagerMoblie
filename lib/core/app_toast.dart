import 'dart:async';

import 'package:flutter/material.dart';

/// Hiển thị 1 thông báo nổi (toast banner) ở phía TRÊN màn hình.
///
/// Khác với [ScaffoldMessenger.showSnackBar] (gắn vào Scaffold nên trên Android
/// bị các dialog toàn màn hình che khuất — "chìm dưới"), thông báo này được
/// chèn vào overlay GỐC của app nên luôn hiển thị trên cùng, kể cả khi đang
/// mở dialog.
void showToast(
  BuildContext context,
  String message, {
  bool error = false,
  Duration duration = const Duration(seconds: 3),
}) {
  AppToast.show(context, message, error: error, duration: duration);
}

class AppToast {
  AppToast._();

  static OverlayEntry? _entry;

  static void show(
    BuildContext context,
    String message, {
    bool error = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // Chỉ giữ 1 thông báo tại 1 thời điểm: xóa cái cũ (nếu có) trước khi tạo mới.
    _entry?.remove();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastBanner(
        message: message,
        error: error,
        duration: duration,
        onDismissed: () {
          if (identical(_entry, entry)) {
            _entry = null;
            entry.remove();
          }
        },
      ),
    );

    _entry = entry;
    overlay.insert(entry);
  }
}

class _ToastBanner extends StatefulWidget {
  final String message;
  final bool error;
  final Duration duration;
  final VoidCallback onDismissed;

  const _ToastBanner({
    required this.message,
    required this.error,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_ToastBanner> createState() => _ToastBannerState();
}

class _ToastBannerState extends State<_ToastBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut, reverseCurve: Curves.easeIn);
    _slide = Tween(begin: const Offset(0, -0.7), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    _controller.reverse().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const infoBg = Color(0xFF1F2937);
    const errorBg = Color(0xFFDC2626);
    final bg = widget.error ? errorBg : infoBg;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: GestureDetector(
              onTap: _dismiss,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.error ? Icons.error_outline : Icons.check_circle_outline,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

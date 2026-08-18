import 'dart:async';
import 'package:flutter/material.dart';
import '../core/supabase_service.dart';

/// Bọc quanh 1 Supabase Realtime stream (`.stream()`). Nếu sau [timeout] mà
/// vẫn chưa nhận được dữ liệu lần đầu — thường do bảng chưa được bật trong
/// Supabase Realtime publication, mất mạng, hoặc JWT hết hạn (hay gặp trên
/// Windows khi app bị thu nhỏ/mất focus lâu) — sẽ hiện thông báo lỗi rõ
/// ràng kèm nút "Thử lại" thay vì treo vòng xoay loading vô hạn.
///
/// Khi lỗi là do JWT hết hạn, tự động làm mới phiên đăng nhập và thử lại
/// 1 lần mà không cần người dùng phải tự bấm.
class RealtimeStreamView<T> extends StatefulWidget {
  final Stream<T> stream;
  final Widget Function(BuildContext context, T data) builder;
  final Duration timeout;

  const RealtimeStreamView({
    super.key,
    required this.stream,
    required this.builder,
    this.timeout = const Duration(seconds: 10),
  });

  @override
  State<RealtimeStreamView<T>> createState() => _RealtimeStreamViewState<T>();
}

class _RealtimeStreamViewState<T> extends State<RealtimeStreamView<T>> {
  bool _timedOut = false;
  Timer? _timer;
  int _retryKey = 0;
  bool _autoRecoverAttempted = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timedOut = false;
    _timer = Timer(widget.timeout, () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _retry({bool refreshSession = true}) async {
    if (refreshSession) {
      await SupabaseService.ensureFreshSession();
    }
    if (!mounted) return;
    setState(() {
      _retryKey++;
      _startTimer();
    });
  }

  void _maybeAutoRecover(Object error) {
    if (_autoRecoverAttempted) return;
    if (!SupabaseService.isAuthExpiredError(error)) return;
    _autoRecoverAttempted = true;
    // Tự làm mới phiên + thử lại 1 lần mà không cần người dùng bấm "Thử lại".
    WidgetsBinding.instance.addPostFrameCallback((_) => _retry());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      key: ValueKey(_retryKey),
      stream: widget.stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final isAuthExpired = SupabaseService.isAuthExpiredError(snapshot.error!);
          if (isAuthExpired) {
            _maybeAutoRecover(snapshot.error!);
            if (!_autoRecoverAttempted) {
              // đang trong khung chờ postFrameCallback kích hoạt _retry()
            }
          }
          return _errorView(
            isAuthExpired
                ? 'Phiên đăng nhập cần được làm mới, đang tự thử lại...'
                : 'Lỗi tải dữ liệu: ${snapshot.error}',
          );
        }
        if (snapshot.hasData) {
          _timer?.cancel();
          _autoRecoverAttempted = false;
          return widget.builder(context, snapshot.data as T);
        }
        if (_timedOut) {
          return _errorView(
            'Không tải được dữ liệu sau ${widget.timeout.inSeconds}s.\n'
            'Có thể do mất mạng, phiên đăng nhập hết hạn, hoặc bảng chưa được bật Realtime trên Supabase.',
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                _autoRecoverAttempted = false;
                _retry();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}

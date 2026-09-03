import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_config.dart';
import 'app_logger.dart';

class SupabaseService {
  SupabaseService._();

  static Future<void> init() async {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
  static GoTrueClient get auth => client.auth;
  static User? get currentUser => client.auth.currentUser;

  /// Chủ động refresh JWT + cập nhật token cho Realtime để tránh lỗi hết phiên.
  /// KHÔNG tự ngắt kết nối Realtime định kỳ: mỗi lần disconnect()/connect()
  /// khiến toàn bộ channel subscribe lại cùng lúc, gây hàng loạt
  /// `RealtimeSubscribeException(status: timedOut)` trong log.
  /// Gọi định kỳ từ timer trong main.dart và mỗi khi app resume.
  static Future<void> ensureFreshSession() async {
    try {
      final session = auth.currentSession;
      if (session == null) return;
      final expiresAt = session.expiresAt;
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final needsRefresh = expiresAt == null || nowSeconds >= (expiresAt - 300);
      if (needsRefresh) {
        try {
          await auth.refreshSession();
        } catch (e) {
          AppLogger.instance.warning(
            'JWT refresh thất bại (có thể refresh_token hết hạn): $e',
            category: 'auth',
          );
        }
      }
      await refreshRealtimeAuth();
    } catch (_) {}
  }

  /// Chỉ reconnect Realtime khi socket đang thực sự rớt
  /// (connState không phải open/connecting). Nếu còn sống, chỉ đẩy token mới —
  /// tránh bão subscribe gây lỗi kết nối định kỳ như trong log.
  static Future<void> reconnectRealtimeIfNeeded() async {
    try {
      final rt = client.realtime;
      // Luôn refresh JWT (nếu sắp/hết hạn) + đẩy token mới lên socket, kể cả
      // khi socket đang mở: các channel join lúc này mới không bị server từ
      // chối vì "InvalidJWTToken: Token has expired".
      await ensureFreshSession();
      final state = rt.connState;
      if (state == SocketStates.open || state == SocketStates.connecting) {
        return;
      }
      try {
        // ignore: invalid_use_of_internal_member
        rt.connect();
      } catch (_) {}
    } catch (_) {}
  }

  /// Đẩy access token mới nhất vào Realtime để các channel đang subscribe
  /// không bị server từ chối vì JWT đã hết hạn.
  static Future<void> refreshRealtimeAuth() async {
    final token = auth.currentSession?.accessToken;
    if (token == null) return;
    try {
      // ignore: invalid_use_of_internal_member
      await client.realtime.setAuth(token);
    } catch (_) {}
  }

  /// true nếu message lỗi cho thấy JWT/token đã hết hạn.
  static bool isAuthExpiredError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('jwt expired') ||
        msg.contains('jwt is expired') ||
        msg.contains('pgrst303') ||
        msg.contains('token has expired') ||
        msg.contains('invalid jwt');
  }

  /// Thực thi query, tự động refresh + retry 1 lần nếu lỗi auth.
  static Future<T> withRetryOnAuthError<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      if (isAuthExpiredError(e)) {
        await ensureFreshSession();
        return await fn();
      }
      rethrow;
    }
  }
}

/// Bọc 1 Supabase Realtime stream (`.stream()`) để TỰ KẾT NỐI LẠI khi stream
/// lỗi hoặc bị đóng.
///
/// Bối cảnh: khi socket Realtime đang rớt trong lúc reconnect, `phx_join` bị
/// buffer chờ nhưng `Push.startTimeout` (10s) vẫn chạy → channel rơi vào
/// `timedOut` → `SupabaseStreamBuilder` phát lỗi cho stream. Stream đó KHÔNG
/// tự hồi phục (re-listen chỉ quay lại `_streamController` cũ đã chết, không
/// tạo channel mới), nên màn hình cứ hiện "mất kết nối" mãi cho tới khi mở
/// lại màn hình.
///
/// Hàm này âm thầm hủy stream cũ, đợi [initialBackoff] (tăng dần tới
/// [maxBackoff]) rồi tạo stream mới bằng [create]. Stream trả về là broadcast
/// có replay dữ liệu cuối: UI không bao giờ bị treo vòng xoay khi rebuild, và
/// lỗi realtime không bao giờ vọt lên màn hình dưới dạng "Lỗi tải dữ liệu".
/// Stream tự dừng khi không còn ai lắng nghe (tránh rò rỉ channel).
Stream<T> autoReconnectStream<T>(
  Stream<T> Function() create, {
  String label = 'realtime',
  Duration initialBackoff = const Duration(seconds: 2),
  Duration maxBackoff = const Duration(seconds: 30),
}) {
  StreamSubscription<T>? sub;
  Timer? retryTimer;
  T? last;
  var hasData = false;
  var retryCount = 0;
  var stopped = true;
  var subscribing = false;
  final currentListeners = <MultiStreamController<T>>{};

  late void Function() scheduleRetry;
  late Future<void> Function() subscribe;

  /// Phát 1 event tới TẤT CẢ subscriber đang lắng nghe.
  void emit(T value) {
    last = value;
    hasData = true;
    for (final l in [...currentListeners]) {
      l.add(value);
    }
  }

  scheduleRetry = () {
    if (stopped) return;
    retryTimer?.cancel();
    // Giới hạn retry: sau 20 lần (tối đa ~30s backoff × 20 ≈ 10 phút),
    // dừng để tránh loop vô tận khi refresh_token hết hạn.
    if (retryCount > 20) {
      AppLogger.instance.warning(
        'Realtime "$label": quá nhiều retry ($retryCount), dừng.',
        category: 'realtime_retry',
      );
      stopped = true;
      return;
    }
    final shift = (retryCount - 1).clamp(0, 6);
    final ms = (initialBackoff.inMilliseconds * (1 << shift))
        .clamp(1, maxBackoff.inMilliseconds);
    retryTimer = Timer(Duration(milliseconds: ms), subscribe);
  };

  subscribe = () async {
    if (stopped || subscribing) return;
    subscribing = true;
    try {
      sub?.cancel();
      sub = null;
      // Refresh JWT (nếu sắp/hết hạn) TRƯỚC khi (re)subscribe: nếu token đã
      // hết hạn, server sẽ từ chối với "InvalidJWTToken: Token has expired"
      // và stream cứ lặp lại lỗi mãi tới khi token được refresh.
      try {
        await SupabaseService.ensureFreshSession();
      } catch (_) {
        // Refresh thất bại — có thể refresh_token hết hạn.
        // Vẫn subscribe với token hiện tại: nếu cũng hết hạn, onError sẽ xử lý.
        // Giới hạn retry tránh loop vô tận.
        if (retryCount > 5) {
          AppLogger.instance.warning(
            'Realtime "$label": JWT refresh thất bại liên tiếp, dừng retry.',
            category: 'realtime_retry',
          );
          stopped = true;
          return;
        }
      }
      if (stopped) return;
      // Đảm bảo socket Realtime thực sự SỐNG trước khi tạo channel mới.
      // Khi socket rớt (vd: WebSocket đóng bất thường code 1006, hay
      // `RealtimeSubscribeException(status: channelError)`) mà vẫn subscribe
      // trên socket chết, phx_join bị buffer rồi timedOut → lỗi cứ lặp lại
      // mãi. Reconnect socket (nếu connState không open/connecting) rồi mới
      // tạo channel mới để lỗi không tái diễn.
      try {
        await SupabaseService.reconnectRealtimeIfNeeded();
      } catch (_) {
        // Không chặn subscribe: vẫn thử tạo channel mới, onError sẽ tự retry.
      }
      if (stopped) return;
      sub = create().listen(
        (value) {
          retryCount = 0;
          emit(value);
        },
        onError: (Object e) {
          retryCount++;
          if (retryCount == 1 || retryCount % 10 == 0) {
            AppLogger.instance.warning(
              'Realtime "$label" lỗi, tự kết nối lại (lần $retryCount): $e',
              category: 'realtime_retry',
              data: {'error': '$e', 'attempt': retryCount},
            );
          }
          // Nếu là JWT expired, force refresh trước khi retry
          if (SupabaseService.isAuthExpiredError(e)) {
            SupabaseService.ensureFreshSession().whenComplete(() {
              scheduleRetry();
            });
          } else {
            scheduleRetry();
          }
        },
        onDone: scheduleRetry,
      );
    } catch (e) {
      retryCount++;
      scheduleRetry();
    } finally {
      subscribing = false;
    }
  };

  // Dùng Stream.multi thay vì StreamController.broadcast(onListen: ...):
  // onListen của broadcast controller chỉ được gọi cho subscriber ĐẦU TIÊN
  // (Dart SDK stream_controller.dart:168) nên "replay dữ liệu gần nhất" cho
  // subscriber mới (VD: dropdown chuông thông báo mở ra khi badge đã có dữ
  // liệu) không bao giờ chạy → bảng thông báo hiện trống dù badge đang đếm.
  // Stream.multi gọi lại onListen cho TỪNG subscriber, cho phép replay `last`
  // ngay khi có người nghe mới (xem ví dụ "repeatLatest" trong Dart SDK
  // stream.dart:441). Kết nối realtime chỉ tồn tại khi có >= 1 subscriber.
  return Stream.multi((listener) {
    currentListeners.add(listener);
    if (stopped) {
      stopped = false;
      subscribe();
    } else if (hasData) {
      listener.add(last as T);
    }
    listener.onCancel = () {
      currentListeners.remove(listener);
      if (currentListeners.isEmpty) {
        stopped = true;
        retryTimer?.cancel();
        sub?.cancel();
        sub = null;
      }
    };
  });
}

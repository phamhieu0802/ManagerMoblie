import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart';
import 'core/supabase_service.dart';
import 'core/firebase_service.dart';
import 'core/app_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/windows_protocol.dart';
import 'routing/app_router.dart';
import 'features/auth/controllers/auth_controller.dart';
import 'features/settings/controllers/backup_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppLogger.instance.init();
  _installGlobalErrorHandlers();

  if (!kIsWeb && Platform.isWindows) {
    registerWindowsOAuthProtocol('io.supabase.flutter');
  }

  await SupabaseService.init();
  await FirebaseService.init();

  // Refresh JWT ngay khi mở app trước khi các realtime stream subscribe,
  // tránh lỗi "Token has expired" khi phiên đã lưu hết hạn từ trước.
  await SupabaseService.ensureFreshSession();
  _installRealtimeLogging();

  runApp(const ProviderScope(child: RepairShopApp()));
}

var _realtimeLogInstalled = false;

/// Ghi log khi Realtime mất kết nối (socket lỗi / heartbeat timeout) để dễ
/// chẩn đoán tình trạng dữ liệu ngừng cập nhật trên app.
void _installRealtimeLogging() {
  if (_realtimeLogInstalled) return;
  _realtimeLogInstalled = true;
  try {
    final rt = SupabaseService.client.realtime;
    rt.onError((e) {
      AppLogger.instance.warning(
        'Realtime mất kết nối',
        category: 'realtime',
        data: {'error': '$e'},
      );
    });
    rt.onHeartbeat.listen((status) {
      if (status == RealtimeHeartbeatStatus.timeout) {
        AppLogger.instance.warning(
          'Realtime heartbeat timeout (mất kết nối)',
          category: 'realtime',
        );
      }
    });
  } catch (_) {}
}

/// Bắt lỗi toàn app để ghi vào Log (file local + Supabase), không làm vỡ app.
void _installGlobalErrorHandlers() {
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLogger.instance.error(
      details.exceptionAsString(),
      category: 'app_error',
      error: details.exception,
      stack: details.stack,
    );
    previousFlutterError?.call(details);
  };

  final previousPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.instance.error(
      error.toString(),
      category: 'platform_error',
      error: error,
      stack: stack,
    );
    if (previousPlatformError != null) return previousPlatformError(error, stack);
    return true;
  };
}

class RepairShopApp extends ConsumerStatefulWidget {
  const RepairShopApp({super.key});

  @override
  ConsumerState<RepairShopApp> createState() => _RepairShopAppState();
}

class _RepairShopAppState extends ConsumerState<RepairShopApp> with WidgetsBindingObserver {
  Timer? _sessionRefreshTimer;
  Timer? _realtimeHealthTimer;
  Timer? _autoBackupTimer;

  static const _sessionRefreshInterval = Duration(minutes: 5);
  static const _realtimeHealthInterval = Duration(minutes: 2);
  static const _autoBackupCheckInterval = Duration(hours: 6);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AuthController.listenAuthChanges(ref);
    });

    // Làm mới JWT định kỳ tránh hết hạn phiên
    _sessionRefreshTimer = Timer.periodic(
      _sessionRefreshInterval,
      (_) => SupabaseService.ensureFreshSession(),
    );

    // Duy trì kết nối Realtime định kỳ. KHÔNG tự disconnect()+connect() mỗi
    // 2 phút như trước: việc đó khiến toàn bộ channel subscribe lại cùng lúc,
    // gây RealtimeSubscribeException(status: timedOut) hàng loạt và làm mất
    // kết nối trên màn hình đang mở. Chỉ reconnect khi socket thực sự rớt,
    // còn sống thì chỉ đẩy token mới để giữ phiên. Realtime tự có heartbeat +
    // reconnect backoff nên không cần ngắt kết nối thủ công.
    _realtimeHealthTimer = Timer.periodic(_realtimeHealthInterval, (_) {
      SupabaseService.reconnectRealtimeIfNeeded();
    });

    // Tự động sao lưu lên đám mây: kiểm tra định kỳ + 1 lần ngay sau khi mở app.
    _autoBackupTimer = Timer.periodic(_autoBackupCheckInterval, (_) => _maybeAutoBackup());
    Timer(const Duration(seconds: 10), _maybeAutoBackup);
  }

  /// Nếu cửa hàng bật "tự động sao lưu" và đã qua 24h kể từ lần sao lưu cuối
  /// thì đẩy 1 bản sao mới lên đám mây (chỉ admin / chủ cửa hàng).
  Future<void> _maybeAutoBackup() async {
    try {
      final user = SupabaseService.currentUser;
      if (user == null) return;
      final profileRow = await SupabaseService.client
          .from('profiles')
          .select('store_id, role')
          .eq('id', user.id)
          .maybeSingle();
      final storeId = profileRow?['store_id'] as String?;
      final role = profileRow?['role'] as String?;
      if (storeId == null || role != 'admin') return;

      final storeRow = await SupabaseService.client
          .from('stores')
          .select('auto_backup, last_backup_at, store_code, name')
          .eq('id', storeId)
          .maybeSingle();
      if (storeRow == null || storeRow['auto_backup'] != true) return;

      final lastStr = storeRow['last_backup_at'] as String?;
      final last = lastStr != null ? DateTime.tryParse(lastStr) : null;
      if (last != null && DateTime.now().toUtc().difference(last.toUtc()) < kAutoBackupInterval) {
        return;
      }

      final code = storeRow['store_code'] as String;
      final name = storeRow['name'] as String;

      // Luôn lưu local trước, cloud là bonus.
      await BackupController.backupToLocal(
        storeId: storeId, storeCode: code, storeName: name,
      );

      try {
        await BackupController.backupToCloud(
          storeId: storeId, storeCode: code, storeName: name,
        );
      } catch (e) {
        AppLogger.instance.error('Auto backup cloud that bai', category: 'backup', error: e);
      }

      await SupabaseService.client
          .from('stores')
          .update({'last_backup_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', storeId);
    } catch (e) {
      AppLogger.instance.error('Auto backup that bai', category: 'backup', error: e);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionRefreshTimer?.cancel();
    _realtimeHealthTimer?.cancel();
    _autoBackupTimer?.cancel();
    FirebaseService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SupabaseService.reconnectRealtimeIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Manager Mobile App',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: const Locale('vi', 'VN'),
      supportedLocales: const [
        Locale('vi', 'VN'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}

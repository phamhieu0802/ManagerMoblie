import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'supabase_service.dart';

/// Ghi log hoạt động & lỗi của app:
/// 1. Ghi vào file local (thư mục dữ liệu app) — luôn hoạt động, kể cả offline.
/// 2. Đồng thời push lên bảng `app_logs` trên Supabase (best-effort, lỗi sẽ bỏ qua).
///
/// Dùng [AppLogger.instance] cho toàn app.
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const _fileName = 'app.log';
  static const _maxFileBytes = 2 * 1024 * 1024; // 2 MB

  File? _file;
  DateTime? _ctxCacheAt;
  String? _cachedStoreId;
  String? _cachedUserId;

  /// Khởi tạo thư mục log. Gọi 1 lần từ main() (không bắt buộc, log vẫn tự tạo).
  Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final logDir = Directory('${dir.path}${Platform.pathSeparator}logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);
      _file = File('${logDir.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      _file = null;
    }
  }

  File? get _logFile => _file;

  Future<void> _resolveContext() async {
    final now = DateTime.now();
    if (_ctxCacheAt != null && now.difference(_ctxCacheAt!) < const Duration(minutes: 2)) return;
    _ctxCacheAt = now;
    _cachedStoreId = null;
    _cachedUserId = null;
    final user = SupabaseService.currentUser;
    if (user == null) return;
    _cachedUserId = user.id;
    try {
      final row = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', user.id)
          .maybeSingle();
      _cachedStoreId = row?['store_id'] as String?;
    } catch (_) {}
  }

  void _writeLocal(String level, String? category, String message, Map<String, dynamic>? data) {
    final file = _logFile;
    if (file == null) return;
    // Ghi file bất đồng bộ để không block UI thread.
    // ignore: unawaited_futures
    _writeLocalAsync(file, level, category, message, data);
  }

  Future<void> _writeLocalAsync(File file, String level, String? category, String message, Map<String, dynamic>? data) async {
    try {
      final entry = {
        'ts': DateTime.now().toIso8601String(),
        'level': level,
        'category': category,
        'message': message,
        'data': data,
      };
      final line = jsonEncode(entry);
      final raf = await file.open(mode: FileMode.append);
      try {
        await raf.writeString('$line\n');
      } finally {
        await raf.close();
      }
      _trimIfNeeded(file);
    } catch (_) {}
  }

  void _trimIfNeeded(File file) {
    // Bỏ qua nếu đang trim — tránh race condition khi nhiều log gọi cùng lúc.
    if (_trimming) return;
    _trimming = true;
    // ignore: unawaited_futures
    _trimIfNeededAsync(file).whenComplete(() => _trimming = false);
  }

  bool _trimming = false;

  Future<void> _trimIfNeededAsync(File file) async {
    try {
      if (!await file.exists()) return;
      final size = await file.length();
      if (size <= _maxFileBytes) return;
      final lines = await file.readAsLines();
      if (lines.isEmpty) return;
      var total = 0;
      var start = lines.length;
      for (var i = lines.length - 1; i >= 0; i--) {
        total += lines[i].length + 1;
        if (total > _maxFileBytes ~/ 2) break;
        start = i;
      }
      if (start >= lines.length) return;
      await file.writeAsString('${lines.sublist(start).join('\n')}\n');
    } catch (_) {}
  }

  Future<void> _pushRemote(String level, String? category, String message, Map<String, dynamic>? data) async {
    try {
      final user = SupabaseService.currentUser;
      if (user == null) return;
      await _resolveContext();
      if (_cachedStoreId == null) return;
      await SupabaseService.client.from('app_logs').insert({
        'store_id': _cachedStoreId,
        'user_id': _cachedUserId,
        'level': level,
        'category': category,
        'message': message,
        'data': data,
      });
    } catch (_) {
      // Bảng app_logs có thể chưa được tạo trên Supabase — bỏ qua, log local vẫn còn.
    }
  }

  /// Ghi 1 dòng log. [remote=false] nếu chỉ muốn ghi local.
  Future<void> log({
    required String level,
    String? category,
    required String message,
    Map<String, dynamic>? data,
    bool remote = true,
  }) async {
    _writeLocal(level, category, message, data);
    if (remote) await _pushRemote(level, category, message, data);
  }

  Future<void> action(String message, {String? category, Map<String, dynamic>? data}) =>
      log(level: 'action', category: category ?? 'hoat_dong', message: message, data: data);

  Future<void> info(String message, {String? category, Map<String, dynamic>? data}) =>
      log(level: 'info', category: category, message: message, data: data);

  Future<void> warning(String message, {String? category, Map<String, dynamic>? data}) =>
      log(level: 'warning', category: category, message: message, data: data);

  Future<void> error(String message, {String? category, Object? error, StackTrace? stack, Map<String, dynamic>? data}) =>
      log(
        level: 'error',
        category: category,
        message: message,
        data: {
          if (error != null) 'error': error.toString(),
          if (stack != null) 'stack': stack.toString().split('\n').take(20).join('\n'),
          ...?data,
        },
      );

  /// Đọc toàn bộ log local (mới nhất trước).
  Future<List<Map<String, dynamic>>> readLocal() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return [];
    try {
      final lines = await file.readAsLines();
      final entries = <Map<String, dynamic>>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) entries.add(decoded);
        } catch (_) {}
      }
      return entries.reversed.toList();
    } catch (_) {
      return [];
    }
  }

  /// Xoá toàn bộ log local.
  Future<void> clearLocal() async {
    final file = _logFile;
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/app_logger.dart';
import '../../../core/supabase_service.dart';
import '../screens/app_info_screen.dart' show kAppVersion;

const String kBackupFormat = 'repair_shop_backup';
const int kBackupVersion = 1;
const int kMaxCloudBackups = 20;
const String kBackupBucket = 'backups';
const Duration kAutoBackupInterval = Duration(hours: 24);

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

class CloudBackupInfo {
  final String fileName;
  final DateTime? createdAt;
  const CloudBackupInfo({required this.fileName, this.createdAt});
}

/// Xuất/nhập dữ liệu dự phòng:
/// - Xuất toàn bộ dữ liệu của cửa hàng ra file JSON (lưu máy) hoặc đẩy lên
///   Supabase Storage bucket "backups".
/// - Khôi phục qua RPC `restore_store_data` (security definer, chạy atomic
///   trong 1 transaction — lỗi giữa chừng thì hoàn tác toàn bộ).
class BackupController {
  static const List<String> _businessTables = [
    'customers',
    'part_categories',
    'repair_orders',
    'repair_order_status_history',
    'inventory_parts',
    'inventory_transactions',
    'stock_counts',
    'cash_accounts',
    'debts',
    'debt_transactions',
    'transactions',
    'salary_payments',
    'qr_codes',
    'notifications',
    'employee_invites',
    'profiles',
  ];

  static const int _inFilterBatchSize = 50;

  static Future<Map<String, dynamic>> buildPayload({
    required String storeId,
    required String storeCode,
    required String storeName,
  }) async {
    final data = <String, List<Map<String, dynamic>>>{};
    for (final table in _businessTables) {
      try {
        if (table == 'repair_order_status_history') {
          final orderIds = (data['repair_orders'] ?? const [])
              .map((r) => r['id'])
              .whereType<String>()
              .toList();
          if (orderIds.isEmpty) {
            data[table] = [];
            continue;
          }
          final allRows = <Map<String, dynamic>>[];
          for (var i = 0; i < orderIds.length; i += _inFilterBatchSize) {
            final batch = orderIds.sublist(i, (i + _inFilterBatchSize).clamp(0, orderIds.length));
            final res = await SupabaseService.client
                .from(table)
                .select()
                .inFilter('repair_order_id', batch);
            allRows.addAll(List<Map<String, dynamic>>.from(res));
          }
          data[table] = allRows;
          continue;
        }
        final res = await SupabaseService.client.from(table).select().eq('store_id', storeId);
        var rows = List<Map<String, dynamic>>.from(res);
        if (table == 'transactions') {
          rows = rows.map((r) {
            if (r['transaction_date'] == null && r['created_at'] != null) {
              return {...r, 'transaction_date': r['created_at']};
            }
            return r;
          }).toList();
        }
        data[table] = rows;
      } catch (e) {
        throw BackupException('Lỗi khi sao lưu bảng "$table": $e');
      }
    }
    return {
      'format': kBackupFormat,
      'version': kBackupVersion,
      'app_version': kAppVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'store_code': storeCode,
      'store_name': storeName,
      'data': data,
    };
  }

  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Lưu backup ra file JSON. Trả về đường dẫn file đã lưu.
  /// Trên desktop mở hộp thoại chọn nơi lưu; trên mobile lưu vào thư mục
  /// Documents của app (hiển thị đường dẫn cho người dùng biết).
  static Future<String> saveToLocalFile(Map<String, dynamic> payload) async {
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    if (_isDesktop) {
      final location = await getSaveLocation(
        suggestedName: 'backup_${_timestampName()}.json',
        acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
      );
      if (location == null) throw const BackupException('Đã hủy lưu file.');
      final file = File(location.path);
      await file.writeAsBytes(Uint8List.fromList(utf8.encode(json)), flush: true);
      return file.path;
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}backup_${_timestampName()}.json');
    await file.writeAsString(json, flush: true);
    return file.path;
  }

  /// Mở hộp chọn file backup, đọc + giải mã JSON. Trả null nếu người dùng hủy.
  static Future<Map<String, dynamic>?> pickBackupFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return _decodePayload(utf8.decode(bytes));
  }

  /// Kiểm tra + khôi phục dữ liệu từ payload qua RPC.
  static Future<void> restoreFromPayload(
    Map<String, dynamic> payload, {
    required String storeId,
    required String storeCode,
  }) async {
    if (payload['format'] != kBackupFormat) {
      throw const BackupException('File này không phải file backup của ứng dụng.');
    }
    final backupCode = (payload['store_code']?.toString() ?? '').trim().toUpperCase();
    final currentCode = storeCode.trim().toUpperCase();
    if (backupCode != currentCode) {
      throw BackupException(
        'File backup thuộc cửa hàng "$backupCode", không khớp cửa hàng hiện tại '
        '($currentCode). Không thể khôi phục nhầm sang cửa hàng khác.',
      );
    }
    final data = payload['data'];
    if (data is! Map) {
      throw const BackupException('File backup thiếu dữ liệu.');
    }
    await SupabaseService.client.rpc('restore_store_data', params: {
      'p_store_id': storeId,
      'p_data': data,
    });
  }

  /// Sao lưu lên đám mây. Trả về tên file đã lưu trên Storage.
  static Future<String> backupToCloud({
    required String storeId,
    required String storeCode,
    required String storeName,
  }) async {
    final payload = await buildPayload(storeId: storeId, storeCode: storeCode, storeName: storeName);
    final fileName = 'backup_${_timestampName()}.json';
    final path = '$storeId/$fileName';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    try {
      await SupabaseService.client.storage
          .from(kBackupBucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'application/json'),
          );
    } catch (e) {
      throw BackupException('Lỗi upload lên Storage ($path, ${bytes.length} bytes): $e');
    }
    await _pruneCloudBackups(storeId);
    return fileName;
  }

  static Future<List<CloudBackupInfo>> listCloudBackups(String storeId) async {
    final items = await SupabaseService.client.storage.from(kBackupBucket).list(
          path: storeId,
          searchOptions: SearchOptions(
            sortBy: SortBy(column: 'created_at', order: 'desc'),
          ),
        );
    return items
        .map((f) => CloudBackupInfo(
              fileName: f.name,
              createdAt: f.createdAt != null ? DateTime.tryParse(f.createdAt!) : null,
            ))
        .toList();
  }

  static Future<Map<String, dynamic>> downloadCloudBackup(String storeId, String fileName) async {
    final bytes = await SupabaseService.client.storage
        .from(kBackupBucket)
        .download('$storeId/$fileName');
    return _decodePayload(utf8.decode(bytes));
  }

  static Future<void> deleteCloudBackup(String storeId, String fileName) async {
    await SupabaseService.client.storage.from(kBackupBucket).remove(['$storeId/$fileName']);
  }

  /// Xóa TOÀN BỘ dữ liệu nghiệp vụ của cửa hàng (atomic, qua RPC).
  /// Không xóa tài khoản đăng nhập, không xóa store, không xóa file backup.
  static Future<void> clearStoreData(String storeId) async {
    await SupabaseService.client.rpc('clear_store_data', params: {
      'p_store_id': storeId,
    });
    try {
      const photosBucket = 'repair-photos';
      final files = await SupabaseService.client.storage.from(photosBucket).list(path: storeId);
      if (files.isNotEmpty) {
        final paths = files.map((f) => '$storeId/${f.name}').toList();
        await SupabaseService.client.storage.from(photosBucket).remove(paths);
      }
    } catch (e) {
      AppLogger.instance.warning('Xoa anh repair-photos that bai', category: 'backup', data: {'error': '$e'});
    }
  }

  /// Giữ tối đa [kMaxCloudBackups] bản gần nhất, xóa các bản cũ hơn.
  static Future<void> _pruneCloudBackups(String storeId) async {
    final items = await SupabaseService.client.storage.from(kBackupBucket).list(path: storeId);
    if (items.length <= kMaxCloudBackups) return;
    final sorted = List.of(items)
      ..sort((a, b) => (b.createdAt ?? '').compareTo(a.createdAt ?? ''));
    final toRemove = sorted
        .skip(kMaxCloudBackups)
        .map((f) => '$storeId/${f.name}')
        .toList();
    await SupabaseService.client.storage.from(kBackupBucket).remove(toRemove);
  }

  static Map<String, dynamic> _decodePayload(String text) {
    try {
      final obj = jsonDecode(text);
      if (obj is! Map<String, dynamic>) {
        throw const BackupException('File backup không hợp lệ.');
      }
      return obj;
    } on FormatException {
      throw const BackupException('File backup bị hỏng (không phải JSON hợp lệ).');
    }
  }

  // ─── Local auto-backup ────────────────────────────────────────

  static Future<Directory> _localBackupDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}${Platform.pathSeparator}backups');
    if (!backupDir.existsSync()) await backupDir.create(recursive: true);
    return backupDir;
  }

  /// Tự sao lưu vào thư mục app (không mở dialog). Trả về đường dẫn file.
  static Future<String> backupToLocal({
    required String storeId,
    required String storeCode,
    required String storeName,
  }) async {
    final payload = await buildPayload(storeId: storeId, storeCode: storeCode, storeName: storeName);
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final dir = await _localBackupDir();
    final file = File('${dir.path}${Platform.pathSeparator}backup_${_timestampName()}.json');
    await file.writeAsBytes(Uint8List.fromList(utf8.encode(json)), flush: true);
    await _pruneLocalBackups();
    return file.path;
  }

  static Future<List<CloudBackupInfo>> listLocalBackups() async {
    final dir = await _localBackupDir();
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.map((f) => CloudBackupInfo(
      fileName: f.uri.pathSegments.last,
      createdAt: f.lastModifiedSync(),
    )).toList();
  }

  static Future<Map<String, dynamic>?> loadLocalBackup(String fileName) async {
    final dir = await _localBackupDir();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    if (!file.existsSync()) return null;
    return _decodePayload(utf8.decode(await file.readAsBytes()));
  }

  static Future<void> deleteLocalBackup(String fileName) async {
    final dir = await _localBackupDir();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    if (file.existsSync()) await file.delete();
  }

  static Future<void> _pruneLocalBackups() async {
    final backups = await listLocalBackups();
    if (backups.length <= kMaxCloudBackups) return;
    for (final b in backups.skip(kMaxCloudBackups)) {
      await deleteLocalBackup(b.fileName);
    }
  }

  static String _timestampName() {
    final now = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }
}

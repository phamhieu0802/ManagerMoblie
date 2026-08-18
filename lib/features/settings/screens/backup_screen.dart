import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/app_logger.dart';
import '../../../core/app_toast.dart';
import '../../../core/error_utils.dart';
import '../../../core/supabase_service.dart';
import '../controllers/backup_controller.dart';
import '../controllers/settings_controller.dart';

/// Màn hình Sao lưu & Khôi phục dữ liệu (chỉ admin).
class BackupScreen extends ConsumerStatefulWidget {
  final String storeId;
  const BackupScreen({super.key, required this.storeId});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _saving = false;
  bool _restoring = false;
  bool _clearing = false;
  List<CloudBackupInfo> _cloudBackups = const [];
  bool _loadingCloud = false;
  List<CloudBackupInfo> _localBackups = const [];
  bool _loadingLocal = false;

  @override
  void initState() {
    super.initState();
    _refreshCloudList();
    _refreshLocalList();
  }

  Future<void> _refreshCloudList() async {
    setState(() => _loadingCloud = true);
    try {
      final items = await BackupController.listCloudBackups(widget.storeId);
      if (mounted) setState(() => _cloudBackups = items);
    } catch (_) {
      if (mounted) setState(() => _cloudBackups = const []);
    } finally {
      if (mounted) setState(() => _loadingCloud = false);
    }
  }

  Future<void> _refreshLocalList() async {
    setState(() => _loadingLocal = true);
    try {
      final items = await BackupController.listLocalBackups();
      if (mounted) setState(() => _localBackups = items);
    } catch (_) {
      if (mounted) setState(() => _localBackups = const []);
    } finally {
      if (mounted) setState(() => _loadingLocal = false);
    }
  }

  Future<void> _backupToFile() async {
    final store = ref.read(storeDetailProvider(widget.storeId)).value;
    if (store == null) {
      _toast('Không tải được thông tin cửa hàng.');
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = await BackupController.buildPayload(
        storeId: widget.storeId,
        storeCode: store.storeCode,
        storeName: store.name,
      );
      final path = await BackupController.saveToLocalFile(payload);
      if (mounted) {
        _toast('Đã sao lưu xong!\n$path');
      }
    } catch (e) {
      AppLogger.instance.error('Sao lưu file thất bại', category: 'backup', error: e);
      if (mounted) _toast('Lỗi sao lưu: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _backupToCloud() async {
    final store = ref.read(storeDetailProvider(widget.storeId)).value;
    if (store == null) return;
    setState(() => _saving = true);
    try {
      final fileName = await BackupController.backupToCloud(
        storeId: widget.storeId,
        storeCode: store.storeCode,
        storeName: store.name,
      );
      await SupabaseService.client.from('stores').update({
        'last_backup_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.storeId);
      ref.invalidate(storeDetailProvider(widget.storeId));
      await _refreshCloudList();
      if (mounted) _toast('Đã sao lưu lên đám mây: $fileName');
    } catch (e) {
      AppLogger.instance.error('Sao lưu đám mây thất bại', category: 'backup', error: e);
      if (mounted) _toast('Lỗi sao lưu lên đám mây: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _backupToLocal() async {
    final store = ref.read(storeDetailProvider(widget.storeId)).value;
    if (store == null) {
      _toast('Không tải được thông tin cửa hàng.');
      return;
    }
    setState(() => _saving = true);
    try {
      final path = await BackupController.backupToLocal(
        storeId: widget.storeId,
        storeCode: store.storeCode,
        storeName: store.name,
      );
      await _refreshLocalList();
      if (mounted) _toast('Đã sao lưu local:\n$path');
    } catch (e) {
      AppLogger.instance.error('Sao lưu local thất bại', category: 'backup', error: e);
      if (mounted) _toast('Lỗi sao lưu local: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmRestore(Future<Map<String, dynamic>?> Function() sourceLoader, {String? label}) async {
    if (_restoring) return;
    final store = ref.read(storeDetailProvider(widget.storeId)).value;
    if (store == null) return;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Khôi phục dữ liệu'),
        content: const Text(
          'Thao tác này sẽ XÓA toàn bộ dữ liệu hiện tại của cửa hàng và thay bằng dữ liệu trong backup.\n\n'
          'Việc khôi phục chạy an toàn trong 1 giao dịch: nếu lỗi thì không ảnh hưởng dữ liệu hiện có.\n\n'
          'Bạn có chắc chắn muốn tiếp tục?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xác nhận khôi phục'),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    setState(() => _restoring = true);
    try {
      final payload = await sourceLoader();
      if (payload == null) {
        if (mounted) _toast('Đã hủy chọn file.');
        return;
      }
      await BackupController.restoreFromPayload(
        payload,
        storeId: widget.storeId,
        storeCode: store.storeCode,
      );
      ref.invalidate(storeDetailProvider(widget.storeId));
      if (mounted) {
        _toast(label == null ? 'Khôi phục thành công!' : 'Khôi phục thành công từ $label!');
      }
    } catch (e) {
      AppLogger.instance.error('Khôi phục dữ liệu thất bại', category: 'backup', error: e);
      if (mounted) _toast('Khôi phục thất bại: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  /// Xóa toàn bộ dữ liệu cửa hàng — yêu cầu gõ chữ xác nhận "XÓA SẠCH".
  Future<void> _clearStore() async {
    if (_clearing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _ClearStoreConfirmDialog(),
    );
    if (confirmed != true) return;

    setState(() => _clearing = true);
    try {
      await BackupController.clearStoreData(widget.storeId);
      ref.invalidate(storeDetailProvider(widget.storeId));
      if (mounted) {
        _toast('Đã xóa toàn bộ dữ liệu cửa hàng.');
      }
    } catch (e) {
      AppLogger.instance.error('Xóa dữ liệu cửa hàng thất bại', category: 'backup', error: e);
      if (mounted) _toast('Lỗi xóa dữ liệu: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeAsync = ref.watch(storeDetailProvider(widget.storeId));
    final store = storeAsync.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Sao lưu & khôi phục')),
      body: SafeArea(
        top: false,
        child: store == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _SectionCard(
                    title: 'Sao lưu dữ liệu',
                    icon: Icons.backup_outlined,
                    color: const Color(0xFF1D4ED8),
                    children: [
                      _LastBackupInfo(store: store),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _saving ? null : _backupToFile,
                              icon: _saving
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.file_download_outlined),
                              label: const Text('Chọn nơi lưu'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _saving ? null : _backupToLocal,
                              icon: _saving
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.save_outlined),
                              label: const Text('Sao lưu local'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _saving ? null : _backupToCloud,
                              icon: _saving
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.cloud_upload_outlined),
                              label: const Text('Đám mây'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Tự động sao lưu hằng ngày',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('Tự lưu local + đẩy lên đám mây khi mở app (giữ tối đa 20 bản).'),
                        value: store.autoBackup,
                        onChanged: _saving ? null : (v) async {
                          setState(() => _saving = true);
                          try {
                            await SupabaseService.client
                                .from('stores')
                                .update({'auto_backup': v}).eq('id', widget.storeId);
                            ref.invalidate(storeDetailProvider(widget.storeId));
                          } catch (e) {
                            AppLogger.instance.error('Bật/tắt sao lưu tự động thất bại', category: 'backup', error: e);
                            _toast('Lỗi: ${friendlyError(e)}');
                          } finally {
                            if (mounted) setState(() => _saving = false);
                          }
                        },
                      ),
                      if (_localBackups.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text('Bản sao local',
                                style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
                            const Spacer(),
                            if (_loadingLocal)
                              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            else
                              IconButton(
                                icon: const Icon(Icons.refresh),
                                tooltip: 'Làm mới',
                                onPressed: _refreshLocalList,
                              ),
                          ],
                        ),
                        ..._localBackups.map((b) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.folder_outlined, color: Color(0xFF1D4ED8)),
                              title: Text(b.fileName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(b.createdAt == null ? '' : DateFormat('dd/MM/yyyy HH:mm').format(b.createdAt!.toLocal()),
                                  style: const TextStyle(fontSize: 12)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: _restoring ? null : () => _confirmRestore(
                                      () => BackupController.loadLocalBackup(b.fileName),
                                      label: b.fileName,
                                    ),
                                    child: const Text('Khôi phục', style: TextStyle(color: Color(0xFFDC2626))),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20),
                                    tooltip: 'Xóa bản sao',
                                    onPressed: () async {
                                      await BackupController.deleteLocalBackup(b.fileName);
                                      await _refreshLocalList();
                                    },
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SectionCard(
                    title: 'Khôi phục dữ liệu',
                    icon: Icons.settings_backup_restore,
                    color: const Color(0xFFDC2626),
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Khôi phục sẽ thay thế toàn bộ dữ liệu hiện tại bằng dữ liệu trong backup. '
                              'Chỉ dùng khi cần lấy lại dữ liệu cũ (đổi máy, hỏng dữ liệu, ...).',
                              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _restoring ? null : () => _confirmRestore(BackupController.pickBackupFile),
                          icon: const Icon(Icons.upload_file_outlined),
                          label: const Text('Khôi phục từ file'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text('Bản sao trên đám mây',
                              style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
                          const Spacer(),
                          if (_loadingCloud)
                            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          else
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: 'Làm mới',
                              onPressed: _refreshCloudList,
                            ),
                        ],
                      ),
                      if (_cloudBackups.isEmpty && !_loadingCloud)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('Chưa có bản sao nào trên đám mây.',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                        ),
                      ..._cloudBackups.map((b) => _CloudBackupTile(
                            info: b,
                            onRestore: _restoring
                                ? null
                                : () => _confirmRestore(
                                      () => BackupController.downloadCloudBackup(widget.storeId, b.fileName),
                                      label: b.fileName,
                                    ),
                            onDelete: () async {
                              try {
                                await BackupController.deleteCloudBackup(widget.storeId, b.fileName);
                                await _refreshCloudList();
                              } catch (e) {
                                AppLogger.instance.error('Xóa backup đám mây thất bại', category: 'backup', error: e);
                                _toast('Lỗi xóa: ${friendlyError(e)}');
                              }
                            },
                          )),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SectionCard(
                    title: 'Làm sạch cửa hàng',
                    icon: Icons.cleaning_services_outlined,
                    color: const Color(0xFFB91C1C),
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Color(0xFFB91C1C), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Xóa TOÀN BỘ dữ liệu của cửa hàng: khách hàng, đơn sửa chữa, kho, thu chi, '
                              'công nợ, lương, QR, thông báo, ảnh thiết bị... '
                              'KHÔNG xóa tài khoản đăng nhập và không xóa file backup.',
                              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFB91C1C),
                            side: const BorderSide(color: Color(0xFFB91C1C)),
                          ),
                          onPressed: _clearing ? null : _clearStore,
                          icon: _clearing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.delete_forever_outlined),
                          label: const Text('Xóa toàn bộ dữ liệu cửa hàng'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Hộp thoại xác nhận xóa toàn bộ dữ liệu — bắt buộc gõ "XÓA SẠCH".
class _ClearStoreConfirmDialog extends StatefulWidget {
  const _ClearStoreConfirmDialog();

  @override
  State<_ClearStoreConfirmDialog> createState() => _ClearStoreConfirmDialogState();
}

class _ClearStoreConfirmDialogState extends State<_ClearStoreConfirmDialog> {
  final _ctrl = TextEditingController();
  bool get _matched => _ctrl.text.trim().toUpperCase() == 'XÓA SẠCH' ||
      _ctrl.text.trim().toUpperCase() == 'XOA SACH';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Xóa toàn bộ dữ liệu cửa hàng'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_rounded, color: Color(0xFFDC2626), size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Thao tác này KHÔNG THỂ hoàn tác.\n'
                  'Toàn bộ dữ liệu của cửa hàng sẽ bị XÓA SẠCH vĩnh viễn.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFB91C1C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Nên sao lưu dữ liệu trước khi thực hiện.',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 14),
          Text(
            'Gõ chính xác "XÓA SẠCH" để xác nhận:',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'XÓA SẠCH',
              errorText: null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Hủy'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
          onPressed: _matched ? () => Navigator.pop(context, true) : null,
          child: const Text('Xóa vĩnh viễn'),
        ),
      ],
    );
  }
}

class _LastBackupInfo extends StatelessWidget {
  final dynamic store;
  const _LastBackupInfo({required this.store});

  @override
  Widget build(BuildContext context) {
    final last = store.lastBackupAt;
    final auto = store.autoBackup == true;
    final text = last == null
        ? 'Chưa từng sao lưu lên đám mây.'
        : 'Lần sao lưu cuối: ${DateFormat('dd/MM/yyyy HH:mm').format(last.toLocal())}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          Icon(Icons.history, color: auto ? const Color(0xFF1D4ED8) : Colors.grey),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey.shade800),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.icon, required this.color, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CloudBackupTile extends StatelessWidget {
  final CloudBackupInfo info;
  final VoidCallback? onRestore;
  final VoidCallback onDelete;
  const _CloudBackupTile({required this.info, this.onRestore, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final created = info.createdAt;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_done_outlined, color: Color(0xFF16A34A)),
      title: Text(info.fileName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(created == null ? '' : DateFormat('dd/MM/yyyy HH:mm').format(created.toLocal()),
          style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onRestore,
            child: const Text('Khôi phục', style: TextStyle(color: Color(0xFFDC2626))),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Xóa bản sao',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

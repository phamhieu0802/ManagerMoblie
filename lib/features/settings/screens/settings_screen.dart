import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_toast.dart';
import '../../../core/error_utils.dart';
import '../../../core/permissions.dart';
import '../../../core/printer_service.dart';
import '../../../core/printer_config_service.dart';
import '../../../core/photo_upload.dart';
import '../../../models/profile.dart';
import '../../../models/store.dart';
import '../../auth/controllers/auth_controller.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/dialog_action_row.dart';
import '../controllers/settings_controller.dart';
import 'app_info_screen.dart';
import 'backup_screen.dart';
import 'discord_settings_screen.dart';
import 'log_screen.dart';
import 'printer_settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final perms = profile != null ? Permissions(profile.role) : null;
    final isAdmin = profile?.role == UserRole.admin;

    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt'), actions: const [NotificationBell(), SizedBox(width: 4)]),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
          if (profile != null) _ProfileTile(profile: profile, ref: ref),
          const Divider(),

          if (isAdmin && profile?.storeId != null) ...[
            _StoreInfoTile(storeId: profile!.storeId!, ref: ref),
            if (perms?.can(AppFeature.bankAccounts) ?? false)
              _BankSettingsTile(storeId: profile.storeId!, ref: ref),
            if (perms?.can(AppFeature.printerSettings) ?? false)
              _PrinterSettingsTile(storeId: profile.storeId!, ref: ref),
            _BackupTile(storeId: profile.storeId!),
            if (perms?.can(AppFeature.appLogs) ?? false)
              const _LogTile(),
            const Divider(),
          ],

          if (profile?.storeId != null)
            _DiscordSettingsTile(storeId: profile!.storeId!, profile: profile, ref: ref),

          const Divider(),

          _ChangePasswordTile(),

          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Thông tin ứng dụng'),
            subtitle: const Text('Phiên bản, tính năng & hướng dẫn sử dụng'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppInfoScreen()),
            ),
          ),

          const Divider(),
          _SignOutTile(),
        ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Profile tile
// ──────────────────────────────────────────────
class _ProfileTile extends ConsumerWidget {
  final Profile profile;
  final WidgetRef ref;
  const _ProfileTile({required this.profile, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: CircleAvatar(
        child: Icon(profile.role == UserRole.admin ? Icons.storefront_rounded : Icons.person),
      ),
      title: Text(profile.fullName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(roleLabel(profile.role)),
      trailing: const Icon(Icons.edit_outlined, size: 20),
      onTap: () => _showEditProfileDialog(context, ref, profile),
    );
  }

  static Future<void> _showEditProfileDialog(BuildContext context, WidgetRef ref, Profile profile) async {
    final nameCtrl = TextEditingController(text: profile.fullName);
    final phoneCtrl = TextEditingController(text: profile.phone ?? '');
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Thông tin cá nhân',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Họ tên'), textCapitalization: TextCapitalization.words),
          const SizedBox(height: 8),
          TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Số điện thoại'), keyboardType: TextInputType.phone),
          if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => nameCtrl.text != profile.fullName || phoneCtrl.text != (profile.phone ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            if (nameCtrl.text.trim().isEmpty) { setStateDialog(() => error = 'Họ tên không được để trống.'); return; }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SettingsController.updateProfile(
                userId: profile.id, fullName: nameCtrl.text.trim(),
                phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
              );
              ref.invalidate(currentProfileProvider);
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Sao lưu & khôi phục
// ──────────────────────────────────────────────
class _BackupTile extends StatelessWidget {
  final String storeId;
  const _BackupTile({required this.storeId});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cloud_upload_outlined),
      title: const Text('Sao lưu & khôi phục'),
      subtitle: const Text('Xuất file JSON hoặc sao lưu lên đám mây'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BackupScreen(storeId: storeId)),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Log hoạt động & lỗi
// ──────────────────────────────────────────────
class _LogTile extends StatelessWidget {
  const _LogTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.receipt_long_outlined),
      title: const Text('Log hoạt động & lỗi'),
      subtitle: const Text('Xem lịch sử hoạt động và lỗi ứng dụng'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LogScreen()),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Store Info
// ──────────────────────────────────────────────
class _StoreInfoTile extends ConsumerWidget {
  final String storeId;
  final WidgetRef ref;
  const _StoreInfoTile({required this.storeId, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(storeDetailProvider(storeId));
    return storeAsync.when(
      loading: () => const ListTile(leading: Icon(Icons.storefront_outlined), title: Text('Thông tin cửa hàng'), subtitle: Text('Đang tải...')),
      error: (e, _) => ListTile(leading: const Icon(Icons.storefront_outlined), title: const Text('Thông tin cửa hàng'), subtitle: Text('Lỗi: $e')),
      data: (store) => store == null ? const SizedBox.shrink() : ListTile(
        leading: const Icon(Icons.storefront_outlined),
        title: const Text('Thông tin cửa hàng'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${store.name} · Mã: ${store.storeCode}', maxLines: 1, overflow: TextOverflow.ellipsis),
            if (store.taxCode != null && store.taxCode!.isNotEmpty)
              Text('MST: ${store.taxCode}', style: const TextStyle(fontSize: 11, color: Colors.black54), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: const Icon(Icons.edit_outlined, size: 20),
        onTap: () => _showEditStoreDialog(context, ref, store),
      ),
    );
  }

  static Future<void> _showEditStoreDialog(BuildContext context, WidgetRef ref, Store store) async {
    final nameCtrl = TextEditingController(text: store.name);
    final addressCtrl = TextEditingController(text: store.address ?? '');
    final phoneCtrl = TextEditingController(text: store.phone ?? '');
    final taxCtrl = TextEditingController(text: store.taxCode ?? '');
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Sửa thông tin cửa hàng',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tên cửa hàng'), textCapitalization: TextCapitalization.words),
          const SizedBox(height: 8),
          TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Địa chỉ'), textCapitalization: TextCapitalization.sentences, maxLines: 2),
          const SizedBox(height: 8),
          TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Số điện thoại'), keyboardType: TextInputType.phone),
          const SizedBox(height: 8),
          TextField(controller: taxCtrl, decoration: const InputDecoration(labelText: 'Mã số thuế'), textCapitalization: TextCapitalization.characters),
          if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => nameCtrl.text != store.name || addressCtrl.text != (store.address ?? '') || phoneCtrl.text != (store.phone ?? '') || taxCtrl.text != (store.taxCode ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            if (nameCtrl.text.trim().isEmpty) { setStateDialog(() => error = 'Tên cửa hàng không được để trống.'); return; }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SettingsController.updateStore(storeId: store.id, name: nameCtrl.text.trim(), address: addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(), phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(), taxCode: taxCtrl.text.trim().isEmpty ? null : taxCtrl.text.trim());
              ref.invalidate(storeDetailProvider(store.id));
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Bank settings
// ──────────────────────────────────────────────
class _BankSettingsTile extends ConsumerWidget {
  final String storeId;
  final WidgetRef ref;
  const _BankSettingsTile({required this.storeId, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(storeDetailProvider(storeId));
    return storeAsync.when(
      loading: () => const ListTile(leading: Icon(Icons.account_balance_outlined), title: Text('Tài khoản ngân hàng')),
      error: (e, _) => const ListTile(leading: Icon(Icons.account_balance_outlined), title: Text('Tài khoản ngân hàng')),
      data: (store) {
        if (store == null) return const SizedBox.shrink();
        final hasBank = store.bankName != null && store.bankName!.isNotEmpty;
        return ListTile(
          leading: const Icon(Icons.account_balance_outlined),
          title: const Text('Tài khoản chuyển khoản'),
          subtitle: Text(hasBank ? '${store.bankName} · ${store.bankAccount ?? ""}' : 'Chưa thiết lập', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 20),
          onTap: () => _showBankSettingsDialog(context, ref, store),
        );
      },
    );
  }

  static Future<void> _showBankSettingsDialog(BuildContext context, WidgetRef ref, Store store) async {
    final bankCtrl = TextEditingController(text: store.bankName ?? '');
    final branchCtrl = TextEditingController(text: store.bankBranch ?? '');
    final accountCtrl = TextEditingController(text: store.bankAccount ?? '');
    String? qrPath = store.bankQr;
    bool qrLoading = false;
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Tài khoản chuyển khoản',
      contentBuilder: (ctx, setStateDialog) => StatefulBuilder(
        builder: (ctx, setStateLocal) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: 'Ngân hàng', helperText: 'VD: Vietcombank, Techcombank...')),
              const SizedBox(height: 8),
              TextField(controller: branchCtrl, decoration: const InputDecoration(labelText: 'Chi nhánh')),
              const SizedBox(height: 8),
              TextField(controller: accountCtrl, decoration: const InputDecoration(labelText: 'Số tài khoản'), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: qrLoading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.qr_code_2),
                      label: const Text('Chọn ảnh QR'),
                      onPressed: qrLoading
                          ? null
                          : () async {
                              setStateLocal(() => qrLoading = true);
                              try {
                                final bytes = await captureAndResizePhoto();
                                if (bytes != null) {
                                  final path = await uploadStoreFile(storeId: store.id, fileName: 'bank-qr.png', bytes: bytes);
                                  setStateLocal(() { qrPath = path; qrLoading = false; });
                                } else {
                                  setStateLocal(() => qrLoading = false);
                                }
                              } on PhotoPermissionException catch (e) {
                                setStateLocal(() => qrLoading = false);
                                showToast(ctx, e.message, error: true);
                              }
                            },
                    ),
                  ),
                  if (qrPath != null && qrPath!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Xóa mã QR',
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => setStateLocal(() => qrPath = null),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (qrPath == null || qrPath!.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F4F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE4E4E7)),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.qr_code_2, color: Colors.black38, size: 40),
                      SizedBox(height: 8),
                      Text('Chưa có mã QR', style: TextStyle(color: Colors.black54)),
                      SizedBox(height: 4),
                      Text('Chọn ảnh mã QR (VD: VietQR tạo từ app ngân hàng) để in trên phiếu.',
                          textAlign: TextAlign.center, style: TextStyle(color: Colors.black45, fontSize: 12)),
                    ],
                  ),
                )
              else
                FutureBuilder<String?>(
                  future: getRepairPhotoUrl(qrPath!),
                  builder: (ctx, snap) {
                    final url = snap.data;
                    if (url == null) return const Center(child: Text('Không tải được ảnh QR'));
                    return Center(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.white,
                        child: Image.network(url, width: 150, height: 150, fit: BoxFit.contain),
                      ),
                    );
                  },
                ),
              if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
            ],
          ),
        ),
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => bankCtrl.text != (store.bankName ?? '') || branchCtrl.text != (store.bankBranch ?? '') || accountCtrl.text != (store.bankAccount ?? '') || qrPath != (store.bankQr ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            setStateDialog(() { saving = true; error = null; });
            try {
              await SettingsController.updateStore(
                storeId: store.id,
                bankName: bankCtrl.text.trim().isEmpty ? null : bankCtrl.text.trim(),
                bankBranch: branchCtrl.text.trim().isEmpty ? null : branchCtrl.text.trim(),
                bankAccount: accountCtrl.text.trim().isEmpty ? null : accountCtrl.text.trim(),
                bankQr: (qrPath != null && qrPath!.isNotEmpty) ? qrPath : null,
              );
              ref.invalidate(storeDetailProvider(store.id));
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Printer settings
// ──────────────────────────────────────────────
class _PrinterSettingsTile extends ConsumerWidget {
  final String storeId;
  final WidgetRef ref;
  const _PrinterSettingsTile({required this.storeId, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(storeDetailProvider(storeId));
    return storeAsync.when(
      loading: () => const ListTile(leading: Icon(Icons.print_outlined), title: Text('Máy in')),
      error: (e, _) => const ListTile(leading: Icon(Icons.print_outlined), title: Text('Máy in')),
      data: (store) {
        if (store == null) return const SizedBox.shrink();
        return FutureBuilder<PrinterConfig?>(
          future: PrinterConfigService.load(),
          builder: (ctx, snap) {
            final config = snap.data;
            final hasConfig = config != null && config.address.isNotEmpty;
            final typeLabel = config?.type == PrinterType.laser ? 'Máy in laser' : 'Máy in nhiệt';
            return ListTile(
              leading: Icon(config?.type == PrinterType.laser ? Icons.print : Icons.print),
              title: const Text('Máy in'),
              subtitle: Text(
                hasConfig ? '$typeLabel: ${config!.name ?? config.address}' : 'Chưa cấu hình',
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => PrinterSettingsScreen(store: store),
              )).then((_) {
                // Reload tile khi quay lại
                if (context.mounted) ref.invalidate(storeDetailProvider(storeId));
              }),
            );
          },
        );
      },
    );
  }
}

// ──────────────────────────────────────────────
// Discord settings (ghép webhook + link)
// ──────────────────────────────────────────────
class _DiscordSettingsTile extends StatelessWidget {
  final String storeId;
  final Profile? profile;
  final WidgetRef ref;
  const _DiscordSettingsTile({required this.storeId, required this.profile, required this.ref});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.discord),
      title: const Text('Cài đặt Discord'),
      subtitle: const Text('Webhook & liên kết tài khoản'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DiscordSettingsScreen()),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Change password
// ──────────────────────────────────────────────
class _ChangePasswordTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.lock_outline),
      title: const Text('Đổi mật khẩu'),
      subtitle: const Text('Thay đổi mật khẩu đăng nhập'),
      onTap: () => _showChangePasswordDialog(context),
    );
  }

  static Future<void> _showChangePasswordDialog(BuildContext context) async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Đổi mật khẩu',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: currentCtrl, decoration: const InputDecoration(labelText: 'Mật khẩu hiện tại'), obscureText: true),
          const SizedBox(height: 8),
          TextField(controller: newCtrl, decoration: const InputDecoration(labelText: 'Mật khẩu mới'), obscureText: true),
          const SizedBox(height: 8),
          TextField(controller: confirmCtrl, decoration: const InputDecoration(labelText: 'Xác nhận mật khẩu mới'), obscureText: true),
          if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => newCtrl.text.isNotEmpty || confirmCtrl.text.isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            final newPass = newCtrl.text;
            final confirmPass = confirmCtrl.text;
            if (newPass.isEmpty || confirmPass.isEmpty) { setStateDialog(() => error = 'Vui lòng nhập mật khẩu mới và xác nhận.'); return; }
            if (newPass != confirmPass) { setStateDialog(() => error = 'Mật khẩu xác nhận không khớp.'); return; }
            if (newPass.length < 6) { setStateDialog(() => error = 'Mật khẩu phải có ít nhất 6 ký tự.'); return; }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SettingsController.changePassword(newPass);
              if (ctx.mounted) {
                Navigator.pop(ctx);
                showToast(context, 'Đã đổi mật khẩu thành công.');
              }
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Đổi mật khẩu'),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Sign out
// ──────────────────────────────────────────────
class _SignOutTile extends StatefulWidget {
  @override
  State<_SignOutTile> createState() => _SignOutTileState();
}

class _SignOutTileState extends State<_SignOutTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.logout, color: Colors.red),
      title: const Text('Đăng xuất', style: TextStyle(color: Colors.red)),
      onTap: _busy ? null : _confirmSignOut,
    );
  }

  Future<void> _confirmSignOut() async {
    if (_busy) return;
    if (!mounted) return;
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Đăng xuất',
      message: 'Bạn có chắc muốn đăng xuất khỏi ứng dụng?',
      confirmLabel: 'Đăng xuất',
      danger: true,
    );
    if (!mounted) return;
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await AuthController.signOut();
    } catch (_) {}
  }
}

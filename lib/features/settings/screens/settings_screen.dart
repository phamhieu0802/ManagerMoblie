import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_toast.dart';
import '../../../core/error_utils.dart';
import '../../../core/permissions.dart';
import '../../../core/printer_service.dart';
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
import 'log_screen.dart';

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
            if (perms?.can(AppFeature.discordWebhook) ?? false)
              _DiscordWebhookTile(storeId: profile.storeId!, ref: ref),
            _BackupTile(storeId: profile.storeId!),
            if (perms?.can(AppFeature.appLogs) ?? false)
              const _LogTile(),
            const Divider(),
          ],

          _DiscordLinkTile(profile: profile, ref: ref),

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
        final hasPrinter = store.printerAddress != null && store.printerAddress!.isNotEmpty;
        return ListTile(
          leading: const Icon(Icons.print_outlined),
          title: const Text('Máy in nhiệt'),
          subtitle: Text(hasPrinter ? 'Đã kết nối: ${store.printerAddress}' : 'Chưa cấu hình', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showPrinterSettings(context, ref, store),
        );
      },
    );
  }

  static void _showPrinterSettings(BuildContext context, WidgetRef ref, Store store) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => _PrinterSettingsPage(store: store, ref: ref)));
  }
}

class _PrinterSettingsPage extends StatefulWidget {
  final Store store;
  final WidgetRef ref;
  const _PrinterSettingsPage({required this.store, required this.ref});

  @override
  State<_PrinterSettingsPage> createState() => _PrinterSettingsPageState();
}

class _PrinterSettingsPageState extends State<_PrinterSettingsPage> {
  late final TextEditingController _addrCtrl;
  late final TextEditingController _headerCtrl;
  late final TextEditingController _footerCtrl;
  late bool _showTimestamp;
  late bool _showTaxCode;
  late bool _showBank;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _addrCtrl = TextEditingController(text: widget.store.printerAddress ?? '');
    _headerCtrl = TextEditingController(text: widget.store.printHeader ?? '');
    _footerCtrl = TextEditingController(text: widget.store.printFooter ?? '');
    _showTimestamp = widget.store.printShowTimestamp;
    _showTaxCode = widget.store.printShowTaxCode;
    _showBank = widget.store.printShowBank;
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    super.dispose();
  }

  void _showPreview() {
    final s = widget.store;
    final preview = PrinterService.buildReceiptText(
      storeName: s.name,
      storeAddress: s.address ?? '',
      storePhone: s.phone ?? '',
      storeTaxCode: s.taxCode,
      bankName: s.bankName,
      bankAccount: s.bankAccount,
      bankBranch: s.bankBranch,
      orderCode: 'HD-0001',
      customerName: 'Nguyễn Văn A',
      customerPhone: '0901234567',
      deviceModel: 'iPhone 13',
      imei: '123456789012345',
      issueDescription: 'Thay màn hình cảm ứng',
      status: 'delivered',
      finalCost: 450000,
      paymentMethod: 'cash',
      receivedAt: DateTime.now(),
      warrantyDays: 90,
      headerText: _headerCtrl.text.trim().isEmpty ? null : _headerCtrl.text.trim(),
      footerText: _footerCtrl.text.trim().isEmpty ? null : _footerCtrl.text.trim(),
      staffName: 'Admin',
      showTimestamp: _showTimestamp,
      showTaxCode: _showTaxCode,
      showBank: _showBank,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xem trước mẫu in'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  preview,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3),
                ),
                if (_showBank && s.bankQr != null && s.bankQr!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  FutureBuilder<String?>(
                    future: getRepairPhotoUrl(s.bankQr!),
                    builder: (ctx, snap) {
                      final url = snap.data;
                      if (url == null) return const SizedBox.shrink();
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          color: Colors.white,
                          child: Image.network(url, width: 130, height: 130, fit: BoxFit.contain),
                        ),
                      );
                    },
                  ),
                ],
                if (_showBank && s.bankName != null && s.bankName!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    PrinterService.buildBankInfoText(
                      bankName: s.bankName!,
                      bankAccount: s.bankAccount,
                      bankBranch: s.bankBranch,
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cấu hình máy in')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          const Text('Nội dung phiếu in:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _headerCtrl,
            decoration: const InputDecoration(
              labelText: 'Lời chào (đầu phiếu)',
              helperText: 'VD: Cảm ơn quý khách đã tin tưởng!',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _footerCtrl,
            decoration: const InputDecoration(
              labelText: 'Lời nhắc (cuối phiếu)',
              helperText: 'VD: Bảo hành 90 ngày. Vui lòng giữ lại phiếu!',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          const Text('Tùy chọn hiển thị trên phiếu in:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Ngày & giờ in (hàng trên cùng)'),
            value: _showTimestamp,
            onChanged: (v) => setState(() => _showTimestamp = v ?? true),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Mã số thuế (MST)'),
            value: _showTaxCode,
            onChanged: (v) => setState(() => _showTaxCode = v ?? true),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Tài khoản ngân hàng (STK)'),
            value: _showBank,
            onChanged: (v) => setState(() => _showBank = v ?? true),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Xem mẫu'),
              onPressed: _showPreview,
            ),
          ),
          const SizedBox(height: 24),
          const Text('Cấu hình máy in:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _addrCtrl,
            decoration: const InputDecoration(
              labelText: 'Địa chỉ máy in',
              helperText: 'Android: BLE MAC (XX:XX:XX:XX:XX:XX) · Windows: IP:Port (192.168.1.100:9100)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Lưu'),
                  onPressed: () async {
                    await SettingsController.updateStore(
                      storeId: widget.store.id,
                      printerAddress: _addrCtrl.text.trim().isEmpty ? null : _addrCtrl.text.trim(),
                      printHeader: _headerCtrl.text.trim().isEmpty ? null : _headerCtrl.text.trim(),
                      printFooter: _footerCtrl.text.trim().isEmpty ? null : _footerCtrl.text.trim(),
                      printShowTimestamp: _showTimestamp,
                      printShowTaxCode: _showTaxCode,
                      printShowBank: _showBank,
                    );
                    widget.ref.invalidate(storeDetailProvider(widget.store.id));
                    if (mounted) showToast(context, 'Đã lưu cấu hình máy in.');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Kiểm tra'),
                  onPressed: () async {
                    final addr = _addrCtrl.text.trim();
                    if (addr.isEmpty) { setState(() => _testResult = 'Nhập địa chỉ máy in trước.'); return; }
                    setState(() => _testResult = 'Đang kết nối...');
                    final err = await PrinterService.testPrint(printerAddress: addr);
                    setState(() => _testResult = err ?? 'In thành công!');
                  },
                ),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(_testResult!.contains('thành công') ? Icons.check_circle : Icons.error, color: _testResult!.contains('thành công') ? Colors.green : Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_testResult!, maxLines: 2, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Hướng dẫn kết nối:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('• Android: Bật Bluetooth → Kết nối máy in trong Settings → Nhập địa chỉ MAC vào ô trên.\n'
              '• Windows: Cắm máy in qua USB hoặc dùng share TCP (máy in hỗ trợ mạng) → Nhập IP:Port.\n'
              '• Dùng nút Kiểm tra để xác nhận kết nối hoạt động.'),
        ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Discord webhook
// ──────────────────────────────────────────────
class _DiscordWebhookTile extends ConsumerWidget {
  final String storeId;
  final WidgetRef ref;
  const _DiscordWebhookTile({required this.storeId, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(storeDetailProvider(storeId));
    return storeAsync.when(
      loading: () => const ListTile(leading: Icon(Icons.discord), title: Text('Discord Webhook')),
      error: (e, _) => const ListTile(leading: Icon(Icons.discord), title: Text('Discord Webhook')),
      data: (store) {
        if (store == null) return const SizedBox.shrink();
        final hasWebhook = store.discordWebhookUrl != null && store.discordWebhookUrl!.isNotEmpty;
        return ListTile(
          leading: const Icon(Icons.discord),
          title: const Text('Thông báo Discord'),
          subtitle: Text(hasWebhook ? 'Đã kết nối webhook' : 'Chưa thiết lập'),
          trailing: const Icon(Icons.edit_outlined, size: 20),
          onTap: () => _showDiscordWebhookDialog(context, ref, store),
        );
      },
    );
  }

  static Future<void> _showDiscordWebhookDialog(BuildContext context, WidgetRef ref, Store store) async {
    final urlCtrl = TextEditingController(text: store.discordWebhookUrl ?? '');
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Discord Webhook',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Webhook URL',
              helperText: 'Tạo trong Discord Server Settings → Integrations → Webhooks',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          Text('Khi thiết lập webhook, hệ thống sẽ tự động gửi thông báo đến kênh Discord khi:\n'
              '• Tạo phiếu sửa chữa mới\n• Thay đổi trạng thái phiếu\n', style: Theme.of(context).textTheme.bodySmall),
          if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => urlCtrl.text != (store.discordWebhookUrl ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            final url = urlCtrl.text.trim();
            if (url.isNotEmpty && !url.startsWith('https://discord.com/api/webhooks/')) {
              setStateDialog(() => error = 'URL webhook không hợp lệ.');
              return;
            }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SettingsController.updateStore(
                storeId: store.id,
                discordWebhookUrl: url.isEmpty ? null : url,
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
// Discord ID link (cá nhân)
// ──────────────────────────────────────────────
class _DiscordLinkTile extends ConsumerWidget {
  final Profile? profile;
  final WidgetRef ref;
  const _DiscordLinkTile({required this.profile, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.discord),
      title: const Text('Liên kết Discord'),
      subtitle: Text(profile!.discordId != null && profile!.discordId!.isNotEmpty
          ? 'ID: ${profile!.discordId}'
          : 'Chưa liên kết', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.edit_outlined, size: 20),
      onTap: () => _showDiscordLinkDialog(context, ref, profile!),
    );
  }

  static Future<void> _showDiscordLinkDialog(BuildContext context, WidgetRef ref, Profile profile) async {
    final ctrl = TextEditingController(text: profile.discordId ?? '');
    bool saving = false;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Liên kết Discord',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'Discord User ID',
              helperText: 'Nhấp chuột phải vào tên → Copy ID (cần bật Developer Mode trong Discord)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Việc liên kết Discord ID giúp hệ thống có thể tag bạn trong thông báo (tính năng sắp ra mắt).',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => ctrl.text != (profile.discordId ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            setStateDialog(() { saving = true; });
            try {
              await SettingsController.updateProfile(
                userId: profile.id,
                discordId: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
              );
              ref.invalidate(currentProfileProvider);
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (_) { setStateDialog(() { saving = false; }); }
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

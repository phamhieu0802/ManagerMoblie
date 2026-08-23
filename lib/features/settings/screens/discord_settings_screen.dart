import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/error_utils.dart';
import '../../../models/profile.dart';
import '../../../models/store.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../auth/controllers/auth_controller.dart';
import '../controllers/settings_controller.dart';

class DiscordSettingsScreen extends ConsumerWidget {
  const DiscordSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final isAdmin = profile?.role == UserRole.admin;

    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt Discord')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── Webhook ───
          _WebhookSection(isAdmin: isAdmin, profile: profile, ref: ref),
          const SizedBox(height: 16),

          // ─── Liên kết tài khoản ───
          _AccountLinkSection(isAdmin: isAdmin, profile: profile, ref: ref),
          const SizedBox(height: 24),

          // ─── Hướng dẫn ───
          const _HelpSection(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Webhook section
// ─────────────────────────────────────────────────────────────────────────────
class _WebhookSection extends ConsumerWidget {
  final bool isAdmin;
  final Profile? profile;
  final WidgetRef ref;
  const _WebhookSection({required this.isAdmin, required this.profile, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeId = profile?.storeId;
    if (storeId == null) return const SizedBox.shrink();

    final storeAsync = ref.watch(storeDetailProvider(storeId));
    return storeAsync.when(
      loading: () => const _SectionCard(
        title: 'Máy chủ Discord Webhook',
        icon: Icons.webhook,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _SectionCard(
        title: 'Máy chủ Discord Webhook',
        icon: Icons.webhook,
        child: Text('Lỗi tải dữ liệu', style: TextStyle(color: Colors.red[400])),
      ),
      data: (store) {
        if (store == null) return const SizedBox.shrink();
        final hasUrl = store.discordWebhookUrl != null && store.discordWebhookUrl!.isNotEmpty;
        final masked = _maskUrl(store.discordWebhookUrl);

        if (isAdmin) {
          return _SectionCard(
            title: 'Máy chủ Discord Webhook',
            icon: Icons.webhook,
            trailing: hasUrl
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Sửa',
                        onPressed: () => _showEditWebhookDialog(context, ref, store),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, size: 18, color: Colors.red[400]),
                        tooltip: 'Xóa',
                        onPressed: () => _confirmDeleteWebhook(context, ref, store),
                      ),
                    ],
                  )
                : IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    tooltip: 'Thêm webhook',
                    onPressed: () => _showEditWebhookDialog(context, ref, store),
                  ),
            child: hasUrl
                ? Row(
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(masked, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  )
                : const Text('Chưa thiết lập', style: TextStyle(color: Colors.black38, fontSize: 12)),
          );
        }

        // User: read-only
        return _SectionCard(
          title: 'Máy chủ Discord Webhook',
          icon: Icons.webhook,
          child: hasUrl
              ? Row(
                  children: [
                    Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(masked, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                )
              : const Text('Chưa có (chỉ admin mới có thể thêm)', style: TextStyle(color: Colors.black38, fontSize: 12)),
        );
      },
    );
  }

  static String _maskUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    // Show only last 8 chars
    if (url.length <= 12) return url;
    return '...${url.substring(url.length - 12)}';
  }

  static Future<void> _showEditWebhookDialog(BuildContext context, WidgetRef ref, Store store) async {
    final urlCtrl = TextEditingController(text: store.discordWebhookUrl ?? '');
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Máy chủ Discord Webhook',
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
          Text('Hệ thống sẽ tự động gửi thông báo đến kênh Discord khi:\n'
              '• Tạo phiếu sửa chữa mới\n• Thay đổi trạng thái phiếu',
              style: Theme.of(ctx).textTheme.bodySmall),
          if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => urlCtrl.text != (store.discordWebhookUrl ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving
              ? null
              : () async {
                  final url = urlCtrl.text.trim();
                  if (url.isNotEmpty && !url.startsWith('https://discord.com/api/webhooks/')) {
                    setStateDialog(() => error = 'URL webhook không hợp lệ.');
                    return;
                  }
                  setStateDialog(() {
                    saving = true;
                    error = null;
                  });
                  try {
                    await SettingsController.updateStore(
                      storeId: store.id,
                      discordWebhookUrl: url.isEmpty ? null : url,
                    );
                    ref.invalidate(storeDetailProvider(store.id));
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    setStateDialog(() {
                      saving = false;
                      error = 'Lỗi: ${friendlyError(e)}';
                    });
                  }
                },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }

  static Future<void> _confirmDeleteWebhook(BuildContext context, WidgetRef ref, Store store) async {
    final confirm = await showConfirmDialog(
      context: context,
      title: 'Xóa Discord Webhook?',
      message: 'Hệ thống sẽ ngừng gửi thông báo đến Discord.',
      confirmLabel: 'Xóa',
      cancelLabel: 'Hủy',
    );
    if (!confirm) return;
    try {
      await SettingsController.updateStore(storeId: store.id, discordWebhookUrl: null);
      ref.invalidate(storeDetailProvider(store.id));
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account link section
// ─────────────────────────────────────────────────────────────────────────────
class _AccountLinkSection extends ConsumerWidget {
  final bool isAdmin;
  final Profile? profile;
  final WidgetRef ref;
  const _AccountLinkSection({required this.isAdmin, required this.profile, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile == null) return const SizedBox.shrink();
    final hasId = profile!.discordId != null && profile!.discordId!.isNotEmpty;

    return _SectionCard(
      title: 'Liên kết tài khoản Discord',
      icon: Icons.account_circle_outlined,
      trailing: hasId
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Sửa',
                  onPressed: () => _showEditIdDialog(context, ref, profile!),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 18, color: Colors.red[400]),
                  tooltip: 'Xóa',
                  onPressed: () => _confirmDeleteId(context, ref, profile!),
                ),
              ],
            )
          : IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 20),
              tooltip: 'Thêm Discord ID',
              onPressed: () => _showEditIdDialog(context, ref, profile!),
            ),
      child: hasId
          ? Row(
              children: [
                Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'ID: ${profile!.discordId}',
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          : const Text('Chưa liên kết', style: TextStyle(color: Colors.black38, fontSize: 12)),
    );
  }

  static Future<void> _showEditIdDialog(BuildContext context, WidgetRef ref, Profile profile) async {
    final ctrl = TextEditingController(text: profile.discordId ?? '');
    bool saving = false;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Liên kết tài khoản Discord',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'Discord User ID',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => ctrl.text != (profile.discordId ?? ''),
        primaryButton: ElevatedButton(
          onPressed: saving
              ? null
              : () async {
                  setStateDialog(() => saving = true);
                  try {
                    await SettingsController.updateProfile(
                      userId: profile.id,
                      discordId: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
                    );
                    ref.invalidate(currentProfileProvider);
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (_) {
                    setStateDialog(() => saving = false);
                  }
                },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }

  static Future<void> _confirmDeleteId(BuildContext context, WidgetRef ref, Profile profile) async {
    final confirm = await showConfirmDialog(
      context: context,
      title: 'Xóa liên kết Discord?',
      message: 'Bạn sẽ không được tag trong thông báo Discord.',
      confirmLabel: 'Xóa',
      cancelLabel: 'Hủy',
    );
    if (!confirm) return;
    try {
      await SettingsController.updateProfile(userId: profile.id, discordId: null);
      ref.invalidate(currentProfileProvider);
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section card wrapper
// ─────────────────────────────────────────────────────────────────────────────
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF5865F2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Help section
// ─────────────────────────────────────────────────────────────────────────────
class _HelpSection extends StatelessWidget {
  const _HelpSection();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blue[50],
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, size: 18, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text('Hướng dẫn', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.blue[800])),
              ],
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 12, height: 1.6),
                children: [
                  TextSpan(text: '1. Webhook Discord\n', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue[800])),
                  const TextSpan(
                    text: '   • Mở Discord → Server Settings → Integrations → Webhooks\n'
                        '   • Bấm "New Webhook" → đặt tên, chọn kênh\n'
                        '   • Copy URL → dán vào ô trên\n',
                  ),
                  TextSpan(text: '2. Discord User ID\n', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue[800])),
                  const TextSpan(
                    text: '   • Mở Discord → Settings → Advanced → bật Developer Mode\n'
                        '   • Quay lại server, nhấp chuột phải vào tên của bạn\n'
                        '   • Chọn "Copy User ID" → dán vào ô "Liên kết tài khoản"\n\n',
                  ),
                  TextSpan(
                    text: 'Khi thiết lập xong, hệ thống sẽ tự động gửi thông báo khi:\n'
                        '   • Tạo phiếu sửa chữa mới\n'
                        '   • Thay đổi trạng thái phiếu\n'
                        '   • Nhắc tên nhân viên liên quan trong kênh Discord',
                    style: TextStyle(color: Colors.blue[700]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

class DiscordWebhook {
  static Future<void> send({
    required String webhookUrl,
    required String title,
    required String description,
    String? color,
    Map<String, String>? fields,
    String? content,
  }) async {
    if (webhookUrl.isEmpty || !webhookUrl.startsWith('https://discord.com/api/webhooks/')) return;

    try {
      final json = <String, dynamic>{
        'username': 'Repair Shop Manager',
        'avatar_url': 'https://img.icons8.com/color/96/tools.png',
        'embeds': [
          {
            'title': title,
            'description': description,
            'color': color != null ? int.tryParse(color) ?? 5814783 : 5814783,
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            if (fields != null && fields.isNotEmpty)
              'fields': fields.entries
                  .map((e) => {'name': e.key, 'value': e.value, 'inline': true})
                  .toList(),
          },
        ],
      };
      if (content != null && content.isNotEmpty) json['content'] = content;

      await http.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(json),
      );
    } catch (_) {}
  }

  static Future<void> notifyNewOrder({
    required String storeId,
    required String orderCode,
    required String customerName,
    String? technicianId,
  }) async {
    final config = await _getStoreConfig(storeId);
    if (config == null) return;
    final (url, name) = config;
    final mention = technicianId != null ? await _getDiscordMention(technicianId) : null;

    await send(
      webhookUrl: url,
      title: '\u{1F4CB} Phiếu mới: $name | $orderCode',
      description: mention != null
          ? '$mention vừa tạo phiếu sửa chữa mới.'
          : '**$name** vừa tạo phiếu sửa chữa mới.',
      color: '5814783',
      fields: {
        'Mã phiếu': orderCode,
        if (mention != null) 'KTV phụ trách': mention,
      },
    );
  }

  static Future<void> notifyStatusChange({
    required String storeId,
    required String orderCode,
    required String oldStatus,
    required String newStatus,
    String? customerName,
    String? technicianId,
  }) async {
    final config = await _getStoreConfig(storeId);
    if (config == null) return;
    final (url, name) = config;
    final mention = technicianId != null ? await _getDiscordMention(technicianId) : null;

    const statusLabels = {
      'received': '\u{1F4E5} Tiếp nhận',
      'diagnosing': '\u{1F50D} Đang chẩn đoán',
      'waiting_parts': '\u{23F3} Chờ linh kiện',
      'repairing': '\u{1F527} Đang sửa',
      'repaired': '\u{2705} Đã sửa xong',
      'delivered': '\u{1F4E6} Đã trả máy',
      'cancelled': '\u{274C} Không sửa',
    };

    final fields = <String, String>{
      'Mã phiếu': orderCode,
      'Trạng thái cũ': statusLabels[oldStatus] ?? oldStatus,
      'Trạng thái mới': statusLabels[newStatus] ?? newStatus,
      if (mention != null) 'KTV phụ trách': mention,
    };

    await send(
      webhookUrl: url,
      title: '\u{1F504} Cập nhật: $name | $orderCode',
      description: mention != null
          ? '$mention đổi trạng thái phiếu sửa chữa.'
          : '**$name** — đổi trạng thái phiếu sửa chữa.',
      color: '16766720',
      fields: fields,
    );
  }

  static Future<void> notifyOrderUpdated({
    required String storeId,
    required String orderCode,
    String? customerName,
    String? technicianId,
    String? changes,
  }) async {
    final config = await _getStoreConfig(storeId);
    if (config == null) return;
    final (url, name) = config;
    final mention = technicianId != null ? await _getDiscordMention(technicianId) : null;

    final fields = <String, String>{
      'Mã phiếu': orderCode,
      if (mention != null) 'KTV phụ trách': mention,
      if (changes != null && changes.isNotEmpty) 'Thay đổi': changes,
    };

    await send(
      webhookUrl: url,
      title: '\u{270F} Phiếu đã sửa: $name | $orderCode',
      description: mention != null
          ? '$mention vừa cập nhật phiếu sửa chữa.'
          : '**$name** vừa cập nhật phiếu sửa chữa.',
      color: '3447003',
      fields: fields,
    );
  }

  static Future<void> notifyOrderDeleted({
    required String storeId,
    required String orderCode,
    required String deletedByName,
    String? technicianId,
  }) async {
    final config = await _getStoreConfig(storeId);
    if (config == null) return;
    final (url, name) = config;
    final mention = technicianId != null ? await _getDiscordMention(technicianId) : null;

    await send(
      webhookUrl: url,
      title: '\u{1F5D1} Phiếu đã xóa: $name | $orderCode',
      description: '**$deletedByName** vừa xóa phiếu sửa chữa **$orderCode** (chuyển vào thùng rác, lưu 90 ngày).',
      color: '13434879',
      fields: {
        'Mã phiếu': orderCode,
        if (mention != null) 'KTV phụ trách': mention,
      },
    );
  }

  /// Tra cứu Discord ID của KTV -> trả về mention dạng <@DISCORD_ID>
  static Future<String?> _getDiscordMention(String profileId) async {
    try {
      final row = await SupabaseService.client
          .from('profiles')
          .select('discord_id, full_name')
          .eq('id', profileId)
          .maybeSingle();
      if (row == null) return null;
      final discordId = row['discord_id'] as String?;
      final name = row['full_name'] as String? ?? '';
      if (discordId != null && discordId.isNotEmpty) {
        return '<@$discordId>';
      }
      if (name.isNotEmpty) return name;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<(String, String)?> _getStoreConfig(String storeId) async {
    try {
      final row = await SupabaseService.client
          .from('stores')
          .select('discord_webhook_url, name')
          .eq('id', storeId)
          .maybeSingle();
      if (row == null) return null;
      final url = row['discord_webhook_url'] as String?;
      final name = row['name'] as String? ?? '';
      if (url == null || url.isEmpty) return null;
      return (url, name);
    } catch (_) {
      return null;
    }
  }
}

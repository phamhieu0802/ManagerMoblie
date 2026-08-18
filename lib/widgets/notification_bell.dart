import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/supabase_service.dart';
import '../features/repair_orders/screens/repair_orders_list_screen.dart';

/// Icon chuông thông báo dùng chung cho mọi AppBar trong app.
/// Hiển thị số thông báo chưa đọc; bấm vào mở danh sách dạng menu sổ
/// xuống ngay tại vị trí nút (không phải hộp thoại giữa màn hình).
/// Bấm vào 1 thông báo cụ thể sẽ tự đánh dấu đã đọc và điều hướng thẳng
/// tới đơn sửa chữa liên quan (nếu thông báo đó có gắn với 1 đơn).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  Stream<List<Map<String, dynamic>>>? _stream;
  String? _currentUserId;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _currentUserId = SupabaseService.currentUser?.id;
    _stream = autoReconnectStream(
      () => SupabaseService.client
          .from('notifications')
          .stream(primaryKey: ['id']).order('created_at', ascending: false),
      label: 'notifications',
    );
  }

  @override
  void dispose() {
    _closeDropdown();
    super.dispose();
  }

  List<Map<String, dynamic>> _filterForMe(List<Map<String, dynamic>> rows) {
    return rows.where((r) => r['user_id'] == null || r['user_id'] == _currentUserId).toList();
  }

  /// Cột `data` là jsonb — qua PostgREST thường được giải mã sẵn thành Map,
  /// nhưng qua kênh Realtime đôi khi trả về dạng chuỗi JSON thô. Xử lý cả 2
  /// trường hợp để không bao giờ bị lỗi ép kiểu âm thầm khiến mất điểm trỏ.
  Map<String, dynamic>? _extractData(Map<String, dynamic> n) {
    final raw = n['data'];
    if (raw == null) return null;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  Future<void> _markAllRead(List<Map<String, dynamic>> unread) async {
    if (unread.isEmpty) return;
    final ids = unread.map((r) => r['id']).toList();
    try {
      await SupabaseService.client.from('notifications').update({'is_read': true}).inFilter('id', ids);
    } catch (_) {}
  }

  Future<void> _markOneRead(Map<String, dynamic> row) async {
    if (row['is_read'] == true) return;
    try {
      await SupabaseService.client.from('notifications').update({'is_read': true}).eq('id', row['id']);
    } catch (_) {}
  }

  void _handleTapNotification(Map<String, dynamic> n) {
    _markOneRead(n);
    _closeDropdown();
    setState(() {});
    final data = _extractData(n);
    final orderCode = data?['order_code'] as String?;
    if (orderCode != null && orderCode.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RepairOrdersListScreen(initialSearch: orderCode)),
      );
    }
  }

  void _closeDropdown() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _toggleDropdown() {
    if (_overlayEntry != null) {
      _closeDropdown();
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox;
    final anchorPos = renderBox.localToGlobal(Offset.zero);
    final anchorSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    _overlayEntry = OverlayEntry(
      builder: (overlayCtx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _closeDropdown();
                setState(() {});
              },
            ),
          ),
          Positioned(
            top: anchorPos.dy + anchorSize.height + 4,
            right: screenSize.width - (anchorPos.dx + anchorSize.width),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Container(
                width: 340,
                constraints: BoxConstraints(maxHeight: screenSize.height * 0.6),
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _stream,
                  builder: (context, snapshot) {
                    final notifications = _filterForMe(snapshot.data ?? const []);
                    final unread = notifications.where((n) => n['is_read'] != true).toList();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                          child: Row(
                            children: [
                              const Text('Thông báo', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                              const Spacer(),
                              if (unread.isNotEmpty)
                                TextButton(
                                  onPressed: () => _markAllRead(unread),
                                  child: const Text('Đọc tất cả', style: TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Flexible(
                          child: notifications.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('Chưa có thông báo nào.', style: TextStyle(color: Colors.black45)),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: notifications.length,
                                  itemBuilder: (context, i) {
                                    final n = notifications[i];
                                    final isRead = n['is_read'] == true;
                                    final hasTarget = _extractData(n)?['order_code'] != null;
                                    return ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                        radius: 16,
                                        backgroundColor: isRead ? Colors.grey.shade200 : const Color(0xFFDCEBFF),
                                        child: Icon(
                                          Icons.notifications_rounded,
                                          color: isRead ? Colors.grey : const Color(0xFF2563EB),
                                          size: 16,
                                        ),
                                      ),
                                      title: Text(
                                        n['title'] ?? '',
                                        style: TextStyle(fontWeight: isRead ? FontWeight.w500 : FontWeight.w700, fontSize: 11),
                                      ),
                                      subtitle: n['body'] != null && (n['body'] as String).isNotEmpty
                                          ? Text(n['body'], style: const TextStyle(fontSize: 9))
                                          : null,
                                      trailing: hasTarget
                                          ? const Icon(Icons.chevron_right, size: 18, color: Colors.black38)
                                          : (isRead ? null : const Icon(Icons.circle, size: 8, color: Color(0xFF2563EB))),
                                      onTap: () => _handleTapNotification(n),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        final mine = _filterForMe(snapshot.data ?? const []);
        final unreadCount = mine.where((n) => n['is_read'] != true).length;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined),
              tooltip: 'Thông báo',
              onPressed: _toggleDropdown,
            ),
            if (unreadCount > 0)
              Positioned(
                right: 6,
                top: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      unreadCount > 99 ? '99+' : '$unreadCount',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

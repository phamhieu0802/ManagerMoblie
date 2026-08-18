import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/app_logger.dart';
import '../../../widgets/realtime_stream_view.dart';

final _timeFmt = DateFormat('dd/MM/yyyy HH:mm:ss');

/// Màn Log trong Cài đặt: xem lịch sử hoạt động & lỗi app.
/// Tab "Trên server" đọc bảng app_logs (Supabase), tab "Trên máy" đọc file local.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log hoạt động'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Trên server'),
            Tab(text: 'Trên máy'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _ServerLogTab(),
          _LocalLogTab(),
        ],
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  final String? filter;
  final ValueChanged<String?> onChanged;
  const _FilterChips({required this.filter, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        ChoiceChip(
          label: const Text('Tất cả', style: TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          selected: filter == null,
          onSelected: (_) => onChanged(null),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          avatar: const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
          label: const Text('Hoạt động', style: TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          selected: filter == 'activity',
          onSelected: (_) => onChanged('activity'),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          avatar: const Icon(Icons.error_outline, size: 16, color: Colors.red),
          label: const Text('Lỗi', style: TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          selected: filter == 'error',
          onSelected: (_) => onChanged('error'),
        ),
      ]),
    );
  }
}

class _LogListItem extends StatelessWidget {
  final Map<String, dynamic> entry;
  final VoidCallback onTap;
  const _LogListItem({required this.entry, required this.onTap});

  String get _level => (entry['level'] ?? 'info').toString();

  (IconData, Color) get _visual {
    switch (_level) {
      case 'error':
        return (Icons.error, Colors.red);
      case 'warning':
        return (Icons.warning_amber_rounded, Colors.orange);
      case 'action':
        return (Icons.check_circle, Colors.green);
      default:
        return (Icons.info_outline, Colors.blue);
    }
  }

  String get _label {
    switch (_level) {
      case 'error':
        return 'Lỗi';
      case 'warning':
        return 'Cảnh báo';
      case 'action':
        return 'Hoạt động';
      default:
        return 'Thông tin';
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _visual;
    final ts = DateTime.tryParse(entry['ts'] ?? entry['created_at'] ?? '');
    final time = ts != null ? _timeFmt.format(ts.toLocal()) : '';
    final category = (entry['category'] ?? '').toString();
    final subtitleParts = [
      _label,
      if (time.isNotEmpty) time,
      if (category.isNotEmpty) category,
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: Icon(icon, color: color, size: 20),
        title: Text(
          (entry['message'] ?? '').toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitleParts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        onTap: onTap,
      ),
    );
  }
}

void _showLogDetail(BuildContext context, Map<String, dynamic> entry) {
  final data = entry['data'];
  String detail = '';
  try {
    detail = const JsonEncoder.withIndent('  ').convert(data);
  } catch (_) {
    detail = data.toString();
  }
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Chi tiết log'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((entry['message'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (detail.isNotEmpty) ...[
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(detail, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
      ],
    ),
  );
}

// =====================================================================
// Trên server (bảng app_logs)
// =====================================================================
class _ServerLogTab extends StatefulWidget {
  const _ServerLogTab();

  @override
  State<_ServerLogTab> createState() => _ServerLogTabState();
}

class _ServerLogTabState extends State<_ServerLogTab> {
  final _searchCtrl = TextEditingController();
  String? _filter;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> e) {
    if (_filter == 'activity' && !{'info', 'action'}.contains(e['level'])) return false;
    if (_filter == 'error' && !{'error', 'warning'}.contains(e['level'])) return false;
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return (e['message'] ?? '').toString().toLowerCase().contains(q) ||
        (e['category'] ?? '').toString().toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
            hintText: 'Tìm log...', isDense: true,
            prefixIcon: Icon(Icons.search, size: 20),
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(vertical: 8),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      _FilterChips(filter: _filter, onChanged: (v) => setState(() => _filter = v)),
      Expanded(
        child: RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: autoReconnectStream(() => SupabaseService.client.from('app_logs').stream(primaryKey: ['id']).order('created_at', ascending: false), label: 'app_logs'),
          builder: (context, allRows) {
            final rows = allRows.where(_matches).toList();
            if (rows.isEmpty) {
              return const Center(child: Text('Chưa có log nào.', style: TextStyle(color: Colors.black45)));
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
              itemCount: rows.length,
              itemBuilder: (_, i) => _LogListItem(entry: rows[i], onTap: () => _showLogDetail(context, rows[i])),
            );
          },
        ),
      ),
    ]);
  }
}

// =====================================================================
// Trên máy (file local)
// =====================================================================
class _LocalLogTab extends StatefulWidget {
  const _LocalLogTab();

  @override
  State<_LocalLogTab> createState() => _LocalLogTabState();
}

class _LocalLogTabState extends State<_LocalLogTab> {
  final _searchCtrl = TextEditingController();
  String? _filter;
  List<Map<String, dynamic>>? _entries;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await AppLogger.instance.readLocal();
    if (!mounted) return;
    setState(() { _entries = entries; _loading = false; });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa log trên máy?'),
        content: const Text('Xóa toàn bộ log local đã ghi trên máy này.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa')),
        ],
      ),
    );
    if (confirmed == true) {
      await AppLogger.instance.clearLocal();
      await _load();
    }
  }

  bool _matches(Map<String, dynamic> e) {
    if (_filter == 'activity' && !{'info', 'action'}.contains(e['level'])) return false;
    if (_filter == 'error' && !{'error', 'warning'}.contains(e['level'])) return false;
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return (e['message'] ?? '').toString().toLowerCase().contains(q) ||
        (e['category'] ?? '').toString().toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Tìm log...', isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          IconButton(tooltip: 'Làm mới', onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Xóa log', onPressed: _entries == null || _entries!.isEmpty ? null : _clear, icon: const Icon(Icons.delete_outline)),
        ]),
      ),
      _FilterChips(filter: _filter, onChanged: (v) => setState(() => _filter = v)),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Builder(builder: (context) {
                final rows = (_entries ?? []).where(_matches).toList();
                if (rows.isEmpty) {
                  return const Center(child: Text('Chưa có log nào.', style: TextStyle(color: Colors.black45)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _LogListItem(entry: rows[i], onTap: () => _showLogDetail(context, rows[i])),
                );
              }),
      ),
    ]);
  }
}

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/app_toast.dart';
import '../../../core/supabase_service.dart';
import '../../../widgets/realtime_stream_view.dart';

final _dateFmt = DateFormat('dd/MM/yyyy HH:mm');
final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

enum TrashKind {
  orders('Đơn sửa chữa', 'repair_orders'),
  customers('Khách hàng', 'customers'),
  parts('Linh kiện', 'inventory_parts'),
  transactions('Phiếu thu/chi', 'transactions');

  final String label;
  final String table;
  const TrashKind(this.label, this.table);
}

/// Thùng rác: dữ liệu đã xoá (soft delete) của đơn, khách hàng, linh kiện và
/// phiếu thu/chi. Chỉ admin truy cập được (gate ở nơi gọi + RLS phía DB).
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  TrashKind _kind = TrashKind.orders;

  late final Map<TrashKind, Stream<List<Map<String, dynamic>>>> _streams = {
    for (final k in TrashKind.values)
      k: autoReconnectStream(
        () => SupabaseService.client.from(k.table).stream(primaryKey: ['id']),
        label: 'trash_${k.table}',
      ),
  };

  String _titleFor(Map<String, dynamic> row) {
    switch (_kind) {
      case TrashKind.orders:
        return '${row['code'] ?? ''} · ${row['device_model'] ?? ''}';
      case TrashKind.customers:
        return row['name'] ?? '';
      case TrashKind.parts:
        return '${row['name'] ?? ''} · ${row['sku'] ?? '-'}';
      case TrashKind.transactions:
        final isIncome = row['type'] == 'income';
        return '${isIncome ? 'Thu' : 'Chi'} ${_currency.format(row['amount'] ?? 0)} · ${row['category'] ?? ''}';
    }
  }

  String _subtitleFor(Map<String, dynamic> row) {
    final deletedAt = row['deleted_at'] != null
        ? DateTime.tryParse(row['deleted_at'].toString())
        : null;
    final when = deletedAt != null ? _dateFmt.format(deletedAt) : '-';
    switch (_kind) {
      case TrashKind.orders:
        return 'Khách: ${row['customer_name'] ?? ''} · Đã xoá lúc $when';
      case TrashKind.customers:
        return 'SĐT: ${row['phone'] ?? ''} · Đã xoá lúc $when';
      case TrashKind.parts:
        return 'Tồn: ${row['quantity'] ?? 0} · Đã xoá lúc $when';
      case TrashKind.transactions:
        return '${row['description'] ?? ''} · Đã xoá lúc $when';
    }
  }

  Future<void> _restore(Map<String, dynamic> row, {bool silent = false}) async {
    try {
      await SupabaseService.client.from(_kind.table).update({
        'deleted_at': null,
        'deleted_by': null,
      }).eq('id', row['id']);
      if (mounted && !silent) {
        showToast(context, 'Đã khôi phục.');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: $e');
      }
    }
  }

  Future<void> _permanentDelete(Map<String, dynamic> row, {bool silent = false}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa vĩnh viễn?'),
        content: const Text('Bản ghi này sẽ bị xóa hoàn toàn và không thể khôi phục.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa vĩnh viễn'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      switch (_kind) {
        case TrashKind.orders:
          // Các bảng con tham chiếu đơn bằng FK KHÔNG cascade -> xóa trước
          // để không vướng khóa ngoại khi xóa vĩnh viễn đơn.
          await SupabaseService.client
              .from('inventory_transactions')
              .delete()
              .eq('repair_order_id', row['id']);
          await SupabaseService.client
              .from('transactions')
              .delete()
              .eq('repair_order_id', row['id']);
          break;
        case TrashKind.customers:
          // Đơn vẫn còn được giữ: tách khách khỏi đơn trước khi xóa vĩnh viễn
          // khách (repair_orders.customer_id không cascade).
          await SupabaseService.client
              .from('repair_orders')
              .update({'customer_id': null})
              .eq('customer_id', row['id']);
          break;
        case TrashKind.parts:
        case TrashKind.transactions:
          // Linh kiện: bảng con (inventory_transactions, stock_counts) đã cascade.
          // Phiếu thu/chi: debt_id không cascade nhưng không chặn việc xóa phiếu.
          break;
      }
      await SupabaseService.client.from(_kind.table).delete().eq('id', row['id']);
      if (mounted && !silent) {
        showToast(context, 'Đã xóa vĩnh viễn.');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: $e');
      }
    }
  }

  final Set<String> _selectedIds = {};
  List<Map<String, dynamic>> _latestRows = [];

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() => setState(_selectedIds.clear);

  void _toggleSelectAll(List<Map<String, dynamic>> rows) {
    setState(() {
      if (rows.isNotEmpty && rows.every((r) => _selectedIds.contains(r['id']))) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(rows.map((r) => r['id'] as String));
      }
    });
  }

  Future<void> _restoreSelected() async {
    final selected = _latestRows.where((r) => _selectedIds.contains(r['id'])).toList();
    for (final row in selected) {
      await _restore(row, silent: true);
    }
    if (mounted) {
      _clearSelection();
      showToast(context, 'Đã khôi phục.');
    }
  }

  Future<void> _permanentDeleteSelected() async {
    final selected = _latestRows.where((r) => _selectedIds.contains(r['id'])).toList();
    if (selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa vĩnh viễn?'),
        content: Text('${selected.length} bản ghi sẽ bị xóa hoàn toàn và không thể khôi phục.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa vĩnh viễn'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    for (final row in selected) {
      await _permanentDelete(row, silent: true);
    }
    if (mounted) {
      _clearSelection();
      showToast(context, 'Đã xóa vĩnh viễn.');
    }
  }

  Widget _buildSelectionBar(List<Map<String, dynamic>> rows) {
    final allSelected = rows.isNotEmpty && rows.every((r) => _selectedIds.contains(r['id']));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
          Text('${_selectedIds.length} đã chọn', style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton.icon(
            onPressed: allSelected ? _clearSelection : () => _toggleSelectAll(rows),
            icon: const Icon(Icons.select_all, size: 18),
            label: const Text('Chọn tất cả'),
          ),
          IconButton(
            tooltip: 'Khôi phục',
            icon: const Icon(Icons.restore),
            onPressed: _selectedIds.isEmpty ? null : _restoreSelected,
          ),
          IconButton(
            tooltip: 'Xóa vĩnh viễn',
            color: Colors.red,
            icon: const Icon(Icons.delete_forever),
            onPressed: _selectedIds.isEmpty ? null : _permanentDeleteSelected,
          ),
        ],
      ),
    );
  }

  Widget _buildTrashItem(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final selected = _selectedIds.contains(id);
    if (!Platform.isAndroid) {
      return Card(
        child: ListTile(
          leading: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleSelect(id),
            child: CircleAvatar(
              backgroundColor: selected ? const Color(0xFF2563EB) : const Color(0xFFFEE2E2),
              child: Icon(
                selected ? Icons.check : Icons.delete_outline,
                color: selected ? Colors.white : Colors.red,
              ),
            ),
          ),
          title: Text(_titleFor(row), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_subtitleFor(row), maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () => _restore(row),
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Khôi phục'),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Xóa vĩnh viễn',
                color: Colors.red,
                onPressed: () => _permanentDelete(row),
                icon: const Icon(Icons.delete_forever),
              ),
            ],
          ),
          onTap: () => _toggleSelect(id),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleSelect(id),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: selected ? const Color(0xFF2563EB) : const Color(0xFFFEE2E2),
                child: Icon(
                  selected ? Icons.check : Icons.delete_outline,
                  size: 18,
                  color: selected ? Colors.white : Colors.red,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_titleFor(row), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(_subtitleFor(row), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Khôi phục',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.restore, size: 20),
                  onPressed: () => _restore(row),
                ),
                IconButton(
                  tooltip: 'Xóa vĩnh viễn',
                  visualDensity: VisualDensity.compact,
                  color: Colors.red,
                  icon: const Icon(Icons.delete_forever, size: 20),
                  onPressed: () => _permanentDelete(row),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thùng rác')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<TrashKind>(
                    segments: [
                      for (final k in TrashKind.values)
                        ButtonSegment(value: k, label: Text(k.label)),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (s) => setState(() => _kind = s.first),
                  ),
                ),
              ),
            ),
            Expanded(
              child: RealtimeStreamView<List<Map<String, dynamic>>>(
                stream: _streams[_kind]!,
                builder: (context, allRows) {
                  final rows = allRows.where((r) => r['deleted_at'] != null).toList()
                    ..sort((a, b) =>
                        (b['deleted_at'] as String).compareTo(a['deleted_at'] as String));
                  if (rows.length != _latestRows.length) {
                    final ids = rows.map((r) => r['id'] as String).toSet();
                    _selectedIds.removeWhere((id) => !ids.contains(id));
                  }
                  _latestRows = rows;
                  return Column(
                    children: [
                      if (_selectedIds.isNotEmpty) _buildSelectionBar(rows),
                      Expanded(
                        child: rows.isEmpty
                            ? Center(child: Text('Thùng rác ${_kind.label} trống.'))
                            : ListView.builder(
                                padding: const EdgeInsets.all(12),
                                itemCount: rows.length,
                                itemBuilder: (context, i) => _buildTrashItem(rows[i]),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

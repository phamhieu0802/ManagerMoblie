import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../widgets/debt_dialogs.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

/// Màn Nhà cung cấp — liệt kê nợ nhà cung cấp (debts type = supplier).
class SuppliersScreen extends StatelessWidget {
  final Widget? appBarLeading;
  const SuppliersScreen({super.key, this.appBarLeading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBarLeading,
        title: const Text('Nhà cung cấp'),
        actions: [
          IconButton(
            tooltip: 'Thêm nhà cung cấp',
            onPressed: () => showAddDebtDialog(context, initialType: 'supplier', title: 'Thêm nhà cung cấp'),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: autoReconnectStream(() => SupabaseService.client.from('debts').stream(primaryKey: ['id']).order('contact_name'), label: 'suppliers'),
        builder: (context, rows) {
          final suppliers = rows.where((d) => d['type'] == 'supplier').toList();
          if (suppliers.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Chưa có nhà cung cấp nào.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => showAddDebtDialog(context, initialType: 'supplier', title: 'Thêm nhà cung cấp'),
                  icon: const Icon(Icons.add, size: 18), label: const Text('Thêm nhà cung cấp'),
                ),
              ]),
            );
          }
          num totalSupplier = 0;
          for (final d in suppliers) {
            totalSupplier += (d['total_debt'] as num?) ?? 0;
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: _MiniSummary(label: 'Nợ nhà cung cấp', value: totalSupplier, color: Colors.red)),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: suppliers.length,
                itemBuilder: (_, i) {
                  final d = suppliers[i];
                  final debt = (d['total_debt'] as num?) ?? 0;
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.business_outlined, color: Colors.red, size: 20),
                      title: Text(d['contact_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text('${d['contact_phone'] ?? ''} · ${d['note'] ?? ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_currency.format(debt), style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14, color: Colors.red,
                        )),
                        IconButton(
                          icon: const Icon(Icons.add, size: 18),
                          tooltip: 'Phát sinh',
                          onPressed: () => showAddDebtTxDialog(context, d),
                        ),
                      ]),
                      onTap: () => showDebtDetail(context, d),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _MiniSummary extends StatelessWidget {
  final String label;
  final num value;
  final Color color;
  const _MiniSummary({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 2),
        Text(_currency.format(value), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      ]),
    );
  }
}

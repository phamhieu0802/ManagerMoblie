import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/money_input_field.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);
final _dateFmt = DateFormat('dd/MM/yyyy');

/// Lấy (hoặc tự tạo) tài khoản két tiền để hạch toán thu tiền.
Future<Map<String, dynamic>?> _ensureAccount(String storeId, String type) async {
  try {
    final existing = await SupabaseService.client
        .from('cash_accounts')
        .select('id, balance')
        .eq('store_id', storeId)
        .eq('type', type)
        .maybeSingle();
    if (existing != null) return Map<String, dynamic>.from(existing);
    final name = type == 'bank' ? 'Tài khoản ngân hàng' : 'Tiền mặt két';
    final inserted = await SupabaseService.client.from('cash_accounts').insert({
      'store_id': storeId, 'name': name, 'type': type, 'balance': 0,
    }).select('id, balance').single();
    return Map<String, dynamic>.from(inserted);
  } catch (_) {
    try {
      final retry = await SupabaseService.client
          .from('cash_accounts')
          .select('id, balance')
          .eq('store_id', storeId)
          .eq('type', type)
          .maybeSingle();
      return retry != null ? Map<String, dynamic>.from(retry) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Hộp thoại thêm công nợ (khách nợ / nợ nhà cung cấp).
/// [showTypeSelector] = false thì bỏ 2 nút phân loại (dùng khi đã biết loại,
/// ví dụ màn Khách hàng & NCC gọi để thêm đúng loại nhà cung cấp).
/// [showAmount] = false thì bỏ ô số tiền (thêm NCC chỉ nhập thông tin liên hệ;
/// số tiền được nhập sau qua mục Công nợ / Phát sinh).
Future<void> showAddDebtDialog(
  BuildContext context, {
  String initialType = 'customer',
  String title = 'Thêm công nợ',
  bool showTypeSelector = true,
  bool showAmount = true,
}) async {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final addrCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  String type = initialType;
  DateTime txDate = DateTime.now();
  bool saving = false;
  String? error;

  await showAdaptiveFormDialog(
    context: context,
    title: title,
    contentBuilder: (ctx, setStateDialog) => SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (showTypeSelector) ...[
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'customer', label: Text('Khách nợ'), icon: Icon(Icons.people)),
              ButtonSegment(value: 'supplier', label: Text('Nợ NCC'), icon: Icon(Icons.business)),
            ],
            selected: {type},
            onSelectionChanged: (s) => setStateDialog(() => type = s.first),
          ),
          const SizedBox(height: 8),
        ],
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tên *')),
        const SizedBox(height: 8),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Số điện thoại')),
        const SizedBox(height: 8),
        TextField(controller: addrCtrl, decoration: const InputDecoration(labelText: 'Địa chỉ')),
        const SizedBox(height: 8),
        if (showAmount) ...[
          MoneyInputField(controller: amountCtrl, label: 'Số tiền *'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: txDate,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
                locale: const Locale('vi'),
              );
              if (picked != null) setStateDialog(() => txDate = picked);
            },
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text('Ngày phát sinh: ${_dateFmt.format(txDate)}'),
          ),
          const SizedBox(height: 8),
        ],
        TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: 'Ghi chú'), maxLines: 2),
        if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
      ]),
    ),
    actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
      onCancel: saving ? null : () => Navigator.pop(ctx),
      isDirty: () => nameCtrl.text.trim().isNotEmpty || (showAmount && amountCtrl.text.trim().isNotEmpty),
      primaryButton: ElevatedButton(
        onPressed: saving ? null : () async {
          final amount = showAmount ? num.tryParse(amountCtrl.text.trim()) : null;
          if (nameCtrl.text.trim().isEmpty || (showAmount && (amount == null || amount <= 0))) {
            setStateDialog(() => error = showAmount ? 'Nhập tên và số tiền hợp lệ.' : 'Nhập tên hợp lệ.'); return;
          }
          setStateDialog(() { saving = true; error = null; });
          try {
            final user = SupabaseService.currentUser;
            if (user == null) throw Exception('Chua dang nhap');
            final storeId = (await SupabaseService.client.from('profiles')
                .select('store_id').eq('id', user.id).single())['store_id'];
            final debt = await SupabaseService.client.from('debts').insert({
              'store_id': storeId, 'type': type, 'contact_name': nameCtrl.text.trim(),
              'contact_phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
              'contact_address': addrCtrl.text.trim().isEmpty ? null : addrCtrl.text.trim(),
              'total_debt': showAmount ? amount : 0, 'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
            }).select('id').single();
            if (showAmount) {
              await SupabaseService.client.from('debt_transactions').insert({
                'store_id': storeId, 'debt_id': debt['id'], 'type': 'add',
                'amount': amount, 'description': 'Phát sinh ban đầu', 'created_by': user.id,
                'transaction_date': txDate.toIso8601String(),
              });
            }
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: $e'; }); }
        },
        child: saving
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Lưu'),
      ),
    ),
  );
}

/// Hộp thoại phát sinh công nợ (thanh toán / phát sinh thêm / trừ bớt).
Future<void> showAddDebtTxDialog(BuildContext context, Map<String, dynamic> debt) async {
  final amountCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  String type = 'pay';
  DateTime txDate = DateTime.now();
  bool saving = false;
  String? error;

  await showAdaptiveFormDialog(
    context: context,
    title: 'Phát sinh công nợ',
    contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, children: [
      Text('${debt['contact_name']} — ${_currency.format(debt['total_debt'] ?? 0)}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'pay', label: Text('Thanh toán'), icon: Icon(Icons.payments)),
          ButtonSegment(value: 'add', label: Text('Phát sinh thêm'), icon: Icon(Icons.add_circle)),
          ButtonSegment(value: 'deduct', label: Text('Trừ bớt'), icon: Icon(Icons.remove_circle)),
        ],
        selected: {type},
        onSelectionChanged: (s) => setStateDialog(() => type = s.first),
      ),
      const SizedBox(height: 8),
      MoneyInputField(controller: amountCtrl, label: 'Số tiền *'),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () async {
          final picked = await showDatePicker(
            context: ctx,
            initialDate: txDate,
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
            locale: const Locale('vi'),
          );
          if (picked != null) setStateDialog(() => txDate = picked);
        },
        icon: const Icon(Icons.calendar_today, size: 16),
        label: Text('Ngày phát sinh: ${_dateFmt.format(txDate)}'),
      ),
      const SizedBox(height: 8),
      TextField(controller: descCtrl, decoration: const InputDecoration(labelText: 'Mô tả')),
      if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
    ]),
    actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
      onCancel: saving ? null : () => Navigator.pop(ctx),
      isDirty: () => amountCtrl.text.trim().isNotEmpty,
      primaryButton: ElevatedButton(
        onPressed: saving ? null : () async {
          final amount = num.tryParse(amountCtrl.text.trim());
          if (amount == null || amount <= 0) {
            setStateDialog(() => error = 'Nhập số tiền hợp lệ.'); return;
          }
          // Không cho thanh toán/trừ bớt vượt quá dư nợ hiện tại.
          final outstanding = ((debt['total_debt'] as num?) ?? 0);
          if (type != 'add' && amount > outstanding) {
            setStateDialog(() => error = 'Không thể vượt quá dư nợ hiện tại (${_currency.format(outstanding)}).'); return;
          }
          setStateDialog(() { saving = true; error = null; });
          try {
            final user = SupabaseService.currentUser;
            if (user == null) throw Exception('Chua dang nhap');
            final storeId = (await SupabaseService.client.from('profiles')
                .select('store_id').eq('id', user.id).single())['store_id'];
            final diff = type == 'add' ? amount : -amount;
            final newDebt = outstanding + diff;
            await SupabaseService.client.from('debts').update({'total_debt': newDebt}).eq('id', debt['id']);
            await SupabaseService.client.from('debt_transactions').insert({
              'store_id': storeId, 'debt_id': debt['id'], 'type': type,
              'amount': amount, 'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              'created_by': user.id,
              'transaction_date': txDate.toIso8601String(),
            });
            // Trả nợ: khách trả nợ -> thu tiền vào két (income + tăng két);
            // trả nợ NCC -> tiền ra (expense + giảm két). Không để lệch báo cáo.
            if (type == 'pay') {
              try {
                final isSupplier = debt['type'] == 'supplier';
                final acct = await _ensureAccount(storeId, 'cash');
                await SupabaseService.client.from('transactions').insert({
                  'store_id': storeId,
                  'type': isSupplier ? 'expense' : 'income',
                  'category': isSupplier ? 'Trả nợ NCC' : 'Thu nợ',
                  'amount': amount,
                  'description': '${isSupplier ? 'Trả nợ' : 'Thu nợ'} ${debt['contact_name']}',
                  'created_by': user.id,
                  if (acct != null) 'account_id': acct['id'],
                  'debt_id': debt['id'],
                  'transaction_date': txDate.toIso8601String(),
                });
                if (acct != null) {
                  await SupabaseService.client.from('cash_accounts')
                      .update({'balance': ((acct['balance'] as num?) ?? 0) + (isSupplier ? -amount : amount)})
                      .eq('id', acct['id']);
                }
              } catch (_) {}
            }
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: $e'; }); }
        },
        child: saving
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Lưu'),
      ),
    ),
  );
}

/// Hộp thoại sửa một phiếu phát sinh công nợ (điều chỉnh lại dư nợ + phiếu
/// thu/chi kèm theo nếu là phiếu thanh toán).
Future<void> showEditDebtTxDialog(
  BuildContext context,
  Map<String, dynamic> debt,
  Map<String, dynamic> tx,
) async {
  final amountCtrl = TextEditingController(text: (tx['amount'] as num?)?.toStringAsFixed(0) ?? '');
  final descCtrl = TextEditingController(text: (tx['description'] ?? '').toString());
  String type = ['add', 'pay', 'deduct'].contains(tx['type']) ? tx['type'] as String : 'add';
  DateTime txDate = DateTime.tryParse(tx['transaction_date']?.toString() ?? '') ??
      DateTime.tryParse(tx['created_at']?.toString() ?? '') ??
      DateTime.now();
  bool saving = false;
  String? error;
  final oldType = type;
  final oldAmount = (tx['amount'] as num?) ?? 0;
  final isSupplier = debt['type'] == 'supplier';

  await showAdaptiveFormDialog(
    context: context,
    title: 'Sửa phiếu phát sinh',
    contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, children: [
      Text('${debt['contact_name']} — ${_currency.format(debt['total_debt'] ?? 0)}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'pay', label: Text('Thanh toán'), icon: Icon(Icons.payments)),
          ButtonSegment(value: 'add', label: Text('Phát sinh thêm'), icon: Icon(Icons.add_circle)),
          ButtonSegment(value: 'deduct', label: Text('Trừ bớt'), icon: Icon(Icons.remove_circle)),
        ],
        selected: {type},
        onSelectionChanged: (s) => setStateDialog(() => type = s.first),
      ),
      const SizedBox(height: 8),
      MoneyInputField(controller: amountCtrl, label: 'Số tiền *'),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () async {
          final picked = await showDatePicker(
            context: ctx,
            initialDate: txDate,
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
            locale: const Locale('vi'),
          );
          if (picked != null) setStateDialog(() => txDate = picked);
        },
        icon: const Icon(Icons.calendar_today, size: 16),
        label: Text('Ngày phát sinh: ${_dateFmt.format(txDate)}'),
      ),
      const SizedBox(height: 8),
      TextField(controller: descCtrl, decoration: const InputDecoration(labelText: 'Mô tả')),
      if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
    ]),
    actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
      onCancel: saving ? null : () => Navigator.pop(ctx),
      isDirty: () => amountCtrl.text.trim() != (tx['amount'] as num?)?.toStringAsFixed(0) ||
          descCtrl.text.trim() != (tx['description'] ?? '').toString() ||
          type != oldType,
      primaryButton: ElevatedButton(
        onPressed: saving ? null : () async {
          final amount = num.tryParse(amountCtrl.text.trim());
          if (amount == null || amount <= 0) {
            setStateDialog(() => error = 'Nhập số tiền hợp lệ.'); return;
          }
          final currentDebt = (debt['total_debt'] as num?) ?? 0;
          final oldDelta = oldType == 'add' ? oldAmount : -oldAmount;
          final newDelta = type == 'add' ? amount : -amount;
          final newDebt = currentDebt - oldDelta + newDelta;
          if (newDebt < 0) {
            setStateDialog(() => error = 'Không thể vượt quá dư nợ hiện tại (${_currency.format(currentDebt)}).'); return;
          }
          setStateDialog(() { saving = true; error = null; });
          try {
            final user = SupabaseService.currentUser;
            if (user == null) throw Exception('Chua dang nhap');
            final storeId = (await SupabaseService.client.from('profiles')
                .select('store_id').eq('id', user.id).single())['store_id'] as String;
            await SupabaseService.client.from('debt_transactions').update({
              'type': type,
              'amount': amount,
              'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              'transaction_date': txDate.toIso8601String(),
            }).eq('id', tx['id']);
            await SupabaseService.client.from('debts').update({'total_debt': newDebt}).eq('id', debt['id']);

            // Đồng bộ phiếu thu/chi + số dư két khi thay đổi phiếu thanh toán.
            if (oldType == 'pay' || type == 'pay') {
              final acct = await _ensureAccount(storeId, 'cash');
              // Tìm phiếu thu/chi kèm theo (theo debt_id, fallback theo mô tả + số tiền).
              final linkedTx = await SupabaseService.client.from('transactions')
                  .select()
                  .eq('debt_id', debt['id'])
                  .eq('amount', oldAmount)
                  .order('created_at', ascending: false)
                  .limit(1)
                  .maybeSingle();
              // Đảo lại ảnh hưởng phiếu thanh toán cũ.
              if (oldType == 'pay' && linkedTx != null) {
                final oldAccountId = linkedTx['account_id'] as String?;
                if (oldAccountId != null) {
                  final a = await SupabaseService.client.from('cash_accounts')
                      .select('balance').eq('id', oldAccountId).single();
                  var bal = (a['balance'] as num?) ?? 0;
                  bal = (linkedTx['type'] == 'income') ? bal - oldAmount : bal + oldAmount;
                  await SupabaseService.client.from('cash_accounts')
                      .update({'balance': bal}).eq('id', oldAccountId);
                }
                await SupabaseService.client.from('transactions').update({
                  'deleted_at': DateTime.now().toIso8601String(),
                  'deleted_by': user.id,
                }).eq('id', linkedTx['id']);
              }
              // Tạo lại phiếu thu/chi nếu phiếu mới là thanh toán.
              if (type == 'pay') {
                if (acct != null) {
                  await SupabaseService.client.from('transactions').insert({
                    'store_id': storeId,
                    'type': isSupplier ? 'expense' : 'income',
                    'category': isSupplier ? 'Trả nợ NCC' : 'Thu nợ',
                    'amount': amount,
                    'description': '${isSupplier ? 'Trả nợ' : 'Thu nợ'} ${debt['contact_name']}',
                    'created_by': user.id,
                    'account_id': acct['id'],
                    'debt_id': debt['id'],
                    'transaction_date': txDate.toIso8601String(),
                  });
                  await SupabaseService.client.from('cash_accounts')
                      .update({'balance': ((acct['balance'] as num?) ?? 0) + (isSupplier ? -amount : amount)})
                      .eq('id', acct['id']);
                }
              }
            }
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: $e'; }); }
        },
        child: saving
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Lưu'),
      ),
    ),
  );
}

/// Mở màn chi tiết công nợ.
void showDebtDetail(BuildContext context, Map<String, dynamic> debt) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => DebtDetailScreen(debt: debt)));
}

class DebtDetailScreen extends StatelessWidget {
  final Map<String, dynamic> debt;
  const DebtDetailScreen({super.key, required this.debt});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(debt['contact_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: autoReconnectStream(
            () => SupabaseService.client
                .from('debt_transactions')
                .stream(primaryKey: ['id'])
                .eq('debt_id', debt['id'])
                .order('created_at', ascending: false),
            label: 'debt_transactions',
          ),
          builder: (context, rows) {
          rows = rows.where((r) => r['deleted_at'] == null).toList();
          if (rows.isEmpty) return const Center(child: Text('Chưa có phát sinh.'));
          return Column(children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.grey.shade100,
              child: Column(children: [
                Text('Dư nợ hiện tại', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                const SizedBox(height: 4),
                Text(_currency.format(debt['total_debt'] ?? 0),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final t = rows[i];
                  final txType = t['type'] as String?;
                  final amt = (t['amount'] as num?) ?? 0;
                  final isAdd = txType == 'add';
                  final rawDate = t['transaction_date'] ?? t['created_at'];
                  final txDate = rawDate != null
                      ? DateTime.tryParse(rawDate.toString())
                      : null;
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      dense: true,
                      onTap: () => showEditDebtTxDialog(context, debt, t),
                      trailing: const Icon(Icons.edit, size: 16),
                      leading: Icon(
                        isAdd ? Icons.add_circle_outline : Icons.remove_circle_outline,
                        color: isAdd ? Colors.red : Colors.green, size: 20,
                      ),
                      title: Text('${txType == 'add' ? 'Phát sinh' : txType == 'pay' ? 'Thanh toán' : 'Trừ bớt'} · ${_currency.format(amt)}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text('${t['description'] ?? ''} · ${txDate != null ? _dateFmt.format(txDate) : ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11)),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
        ),
      ),
    );
  }
}

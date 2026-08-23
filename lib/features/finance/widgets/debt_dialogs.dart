import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/app_toast.dart';
import '../../../core/photo_upload.dart';
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

/// Hộp thoại thêm / sửa công nợ (khách nợ / nợ nhà cung cấp).
/// [existing] != null → chế độ sửa (prefill + update thay vì insert).
/// [showTypeSelector] = false thì bỏ 2 nút phân loại.
/// [showAmount] = false thì bỏ ô số tiền.
Future<void> showAddDebtDialog(
  BuildContext context, {
  String initialType = 'customer',
  String title = 'Thêm công nợ',
  bool showTypeSelector = true,
  bool showAmount = true,
  Map<String, dynamic>? existing,
}) async {
  final isEdit = existing != null;
  final nameCtrl = TextEditingController(text: existing?['contact_name'] ?? '');
  final phoneCtrl = TextEditingController(text: existing?['contact_phone'] ?? '');
  final addrCtrl = TextEditingController(text: existing?['contact_address'] ?? '');
  final noteCtrl = TextEditingController(text: existing?['note'] ?? '');
  final amountCtrl = TextEditingController();
  String type = initialType;
  DateTime txDate = DateTime.now();
  bool saving = false;
  String? error;
  Uint8List? qrBytes;
  bool qrLoading = false;
  // Nếu NCC đã có QR → hiện hint
  final existingQrPath = existing?['contact_image'] as String?;
  bool hasExistingQr = existingQrPath != null && existingQrPath.isNotEmpty;

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
        if (type == 'supplier') ...[
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: qrLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.qr_code_2, size: 18),
                  label: Text(qrBytes != null
                      ? 'Đã chọn ảnh QR mới'
                      : hasExistingQr
                          ? 'Đã có ảnh QR (bấm để thay)'
                          : 'QR ngân hàng (tuỳ chọn)'),
                  onPressed: qrLoading ? null : () async {
                    setStateDialog(() => qrLoading = true);
                    try {
                      final bytes = await captureAndResizePhoto();
                      if (bytes != null) setStateDialog(() { qrBytes = bytes; hasExistingQr = false; });
                    } on PhotoPermissionException catch (e) {
                      if (ctx.mounted) showToast(ctx, e.message, error: true);
                    } finally {
                      setStateDialog(() => qrLoading = false);
                    }
                  },
                ),
              ),
              if (qrBytes != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Xóa ảnh QR',
                  icon: const Icon(Icons.close, size: 18, color: Colors.red),
                  onPressed: () => setStateDialog(() => qrBytes = null),
                ),
              ] else if (hasExistingQr) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Xóa ảnh QR hiện tại',
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  onPressed: () => setStateDialog(() => hasExistingQr = false),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
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

            final payload = <String, dynamic>{
              'contact_name': nameCtrl.text.trim(),
              'contact_phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
              'contact_address': addrCtrl.text.trim().isEmpty ? null : addrCtrl.text.trim(),
              'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
            };

            String debtId;
            if (isEdit) {
              // Chế độ sửa: cập nhật thông tin liên hệ
              await SupabaseService.client.from('debts')
                  .update(payload).eq('id', existing!['id']);
              debtId = existing['id'] as String;
            } else {
              // Chế độ thêm mới
              payload['store_id'] = storeId;
              payload['type'] = type;
              if (showAmount) payload['total_debt'] = amount;
              final debt = await SupabaseService.client.from('debts')
                  .insert(payload).select('id').single();
              debtId = debt['id'] as String;
            }

            // Upload / xóa ảnh QR (chỉ NCC)
            if (type == 'supplier') {
              try {
                if (qrBytes != null) {
                  final qrPath = await uploadStoreFile(
                    storeId: storeId,
                    fileName: 'supplier-qr-$debtId.png',
                    bytes: qrBytes!,
                  );
                  await SupabaseService.client.from('debts')
                      .update({'contact_image': qrPath}).eq('id', debtId);
                } else if (!hasExistingQr && !isEdit) {
                  // Thêm mới mà không chọn QR → không làm gì
                } else if (!hasExistingQr && isEdit) {
                  // Sửa mà xóa QR → xóa path
                  await SupabaseService.client.from('debts')
                      .update({'contact_image': null}).eq('id', debtId);
                }
              } catch (_) {}
            }

            // Tạo phát sinh ban đầu (chỉ khi thêm mới + có số tiền)
            if (showAmount && !isEdit) {
              await SupabaseService.client.from('debt_transactions').insert({
                'store_id': storeId, 'debt_id': debtId, 'type': 'add',
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

/// Dialog danh sách hóa đơn liên kết với công nợ. Cho phép chọn 1 hoặc nhiều
/// hóa đơn → thanh toán (Tiền mặt / C.Khoán).
Future<void> showDebtOrdersPaymentDialog({
  required BuildContext context,
  required String contactName,
  required num totalDebt,
  required Color color,
  required bool isCustomer,
  required List<Map<String, dynamic>> orderItems,
  required List<Map<String, dynamic>> debts,
}) async {
  final selected = <int>{};
  bool selecting = false;
  // Lấy contact_image từ debts (NCC có upload QR)
  final contactImage = debts
      .map((d) => (d['contact_image'] ?? '').toString())
      .where((s) => s.isNotEmpty)
      .firstOrNull;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final selectedTotal = selected.fold<num>(0, (s, i) => s + (orderItems[i]['cost'] as num? ?? 0));
        final unpaidItems = orderItems.where((o) => !(o['paid'] as bool)).toList();
        final allSelected = unpaidItems.isNotEmpty && selected.length == unpaidItems.length;

        return AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(contactName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('Tổng nợ: ${_currency.format(totalDebt)}', style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Nút chọn tất cả
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${selected.length}/${unpaidItems.length} đơn chưa thanh toán',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: unpaidItems.isEmpty ? null : () {
                        setDialogState(() {
                          if (allSelected) {
                            selected.clear();
                          } else {
                            for (var i = 0; i < orderItems.length; i++) {
                              if (!(orderItems[i]['paid'] as bool)) selected.add(i);
                            }
                          }
                        });
                      },
                      icon: Icon(allSelected ? Icons.deselect : Icons.select_all, size: 16),
                      label: Text(allSelected ? 'Bỏ chọn' : 'Chọn tất cả', style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const Divider(height: 1),
                // Danh sách đơn
                Flexible(
                  child: orderItems.isEmpty
                      ? const Center(child: Text('Không có hóa đơn liên kết.', style: TextStyle(fontSize: 12, color: Colors.black45)))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: orderItems.length,
                          itemBuilder: (_, i) {
                            final item = orderItems[i];
                            final isPaid = item['paid'] as bool;
                            final isSel = selected.contains(i);
                            return CheckboxListTile(
                              value: isSel,
                              onChanged: isPaid ? null : (v) {
                                setDialogState(() {
                                  if (v == true) {
                                    selected.add(i);
                                  } else {
                                    selected.remove(i);
                                  }
                                });
                              },
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '${item['code']}  ${item['device_model'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  decoration: isPaid ? TextDecoration.lineThrough : null,
                                  color: isPaid ? Colors.black38 : null,
                                ),
                              ),
                              subtitle: Text(
                                _currency.format(item['cost']),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isPaid ? Colors.black38 : color,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              secondary: isPaid
                                  ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
                                  : null,
                            );
                          },
                        ),
                ),
                // Tổng tiền chọn
                if (selected.isNotEmpty) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Thanh toán:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        Text(_currency.format(selectedTotal), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            if (!isCustomer && contactImage != null)
              OutlinedButton.icon(
                onPressed: () => _showSupplierQrDialog(context, contactName, contactImage),
                icon: const Icon(Icons.qr_code_2, size: 16),
                label: const Text('Xem QR'),
              ),
            if (selected.isNotEmpty)
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  // Chọn hình thức thanh toán
                  final method = await _askPaymentMethod(context);
                  if (method != null) {
                    await _paySelectedOrders(
                      context: context,
                      debts: debts,
                      orderItems: orderItems,
                      selectedIndices: selected,
                      paymentMethod: method,
                      isCustomer: isCustomer,
                      contactName: contactName,
                    );
                  }
                },
                icon: const Icon(Icons.payments, size: 16),
                label: const Text('Thanh toán'),
              ),
          ],
        );
      },
    ),
  );
}

/// Hỏi hình thức thanh toán.
Future<String?> _askPaymentMethod(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hình thức thanh toán'),
      content: const Text('Thanh toán bằng?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'cash'), child: const Text('Tiền mặt')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'transfer'), child: const Text('Chuyển khoản')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
      ],
    ),
  );
}

/// Hiển thị ảnh QR thanh toán của nhà cung cấp (fullscreen dialog).
void _showSupplierQrDialog(BuildContext context, String contactName, String qrPath) {
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.qr_code_2, color: Colors.blue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('QR - $contactName',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FutureBuilder<String?>(
                future: getRepairPhotoUrl(qrPath),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 250,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final url = snapshot.data;
                  if (url == null || url.isEmpty) {
                    return const SizedBox(
                      height: 250,
                      child: Center(child: Text('Không tải được ảnh QR', style: TextStyle(color: Colors.black45))),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      height: 300,
                      errorBuilder: (_, __, ___) => const SizedBox(
                        height: 250,
                        child: Center(child: Text('Lỗi hiển thị ảnh QR', style: TextStyle(color: Colors.black45))),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Đóng'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Xử lý thanh toán các đơn đã chọn.
Future<void> _paySelectedOrders({
  required BuildContext context,
  required List<Map<String, dynamic>> debts,
  required List<Map<String, dynamic>> orderItems,
  required Set<int> selectedIndices,
  required String paymentMethod,
  required bool isCustomer,
  required String contactName,
}) async {
  try {
    final user = SupabaseService.currentUser;
    if (user == null) return;

    final storeId = (await SupabaseService.client
        .from('profiles')
        .select('store_id')
        .eq('id', user.id)
        .single())['store_id'] as String;

    final now = DateTime.now().toIso8601String();
    num totalPaid = 0;
    final paidOrderCodes = <String>[];

    for (final idx in selectedIndices) {
      final item = orderItems[idx];
      if (item['paid'] as bool) continue;

      final orderId = item['repair_order_id'] as String;
      final cost = item['cost'] as num;
      final code = item['code'] as String;
      final debtTxId = item['debt_tx_id'] as String?;

      // 1. Cập nhật đơn hàng: payment_method + paid_at
      await SupabaseService.client.from('repair_orders').update({
        'payment_method': paymentMethod,
        'paid_at': now,
      }).eq('id', orderId);

      // 2. Tạo phiếu thu/chi (transactions)
      final acctType = paymentMethod == 'transfer' ? 'bank' : 'cash';
      final acct = await _ensureAccount(storeId, acctType);
      await SupabaseService.client.from('transactions').insert({
        'store_id': storeId,
        'type': isCustomer ? 'income' : 'expense',
        'category': isCustomer ? 'Sửa chữa' : 'Linh kiện',
        'amount': cost,
        'description': '$code - $contactName',
        'created_by': user.id,
        if (acct != null) 'account_id': acct['id'],
        'transaction_date': now,
      });
      if (acct != null) {
        await SupabaseService.client.from('cash_accounts').update({
          'balance': ((acct['balance'] as num?) ?? 0) + (isCustomer ? cost : -cost),
        }).eq('id', acct['id']);
      }

      // 3. Cập nhật hoặc tạo debt_transactions + 4. Cập nhật debts.total_debt
      final debtEntry = debts.isNotEmpty ? debts.first : null;
      if (debtEntry != null) {
        if (debtTxId != null) {
          await SupabaseService.client.from('debt_transactions').update({
            'type': 'pay',
            'description': 'Thanh toán $code (${paymentMethod == 'cash' ? 'Tiền mặt' : 'C.Khoản'})',
          }).eq('id', debtTxId);
        } else {
          await SupabaseService.client.from('debt_transactions').insert({
            'store_id': storeId,
            'debt_id': debtEntry['id'],
            'type': 'pay',
            'amount': cost,
            'description': 'Thanh toán $code (${paymentMethod == 'cash' ? 'Tiền mặt' : 'C.Khoản'})',
            'repair_order_id': orderId,
            'created_by': user.id,
            'transaction_date': now,
          });
        }
        final currentDebtTotal = (debtEntry['total_debt'] as num?) ?? 0;
        final newTotal = currentDebtTotal - cost;
        await SupabaseService.client.from('debts').update({
          'total_debt': newTotal < 0 ? 0 : newTotal,
        }).eq('id', debtEntry['id']);
      }

      totalPaid += cost;
      paidOrderCodes.add(code);
    }

    if (context.mounted) {
      showToast(context, 'Đã thanh toán ${paidOrderCodes.length} đơn: ${_currency.format(totalPaid)}');
    }
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Lỗi thanh toán: $e', error: true);
    }
  }
}

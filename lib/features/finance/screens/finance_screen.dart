import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/supabase_service.dart';
import '../../../core/notify_helper.dart';
import '../../../core/app_logger.dart';
import '../../../core/error_utils.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/money_input_field.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../widgets/debt_dialogs.dart';
import '../widgets/category_picker_field.dart';
import '../../repair_orders/screens/complete_orders_list_screen.dart';
import '../../repair_orders/screens/repair_orders_list_screen.dart';
import '../../../models/repair_order.dart' as ro;
import '../../home/widgets/app_shell.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);
final _dateFmt = DateFormat('dd/MM/yyyy');

class FinanceScreen extends ConsumerStatefulWidget {
  final Widget? appBarLeading;
  const FinanceScreen({super.key, this.appBarLeading});

  @override
  ConsumerState<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends ConsumerState<FinanceScreen> with SingleTickerProviderStateMixin {
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
        leading: widget.appBarLeading,
        title: const Text('Thu chi'),
        actions: const [NotificationBell(), SizedBox(width: 4)],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Giao dịch'),
            Tab(text: 'Công nợ'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _TransactionsTab(),
          _DebtsTab(),
        ],
      ),
    );
  }
}

// =====================================================================
// GIAO DỊCH (tổng quan số dư + danh sách phiếu thu/chi)
// =====================================================================
class _OverviewSection extends StatelessWidget {
  final num cashBalance;
  final num bankBalance;
  final bool hasAccounts;
  final VoidCallback onAddAccount;
  final String periodLabel;
  final VoidCallback onPickMonth;
  final VoidCallback onPickRange;
  final VoidCallback onClearRange;

  const _OverviewSection({
    required this.cashBalance,
    required this.bankBalance,
    required this.hasAccounts,
    required this.onAddAccount,
    required this.periodLabel,
    required this.onPickMonth,
    required this.onPickRange,
    required this.onClearRange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Số dư tài khoản', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _AccCard(
            icon: Icons.money, label: 'Tiền mặt két',
            value: _currency.format(cashBalance), color: Colors.green,
          )),
          const SizedBox(width: 8),
          Expanded(child: _AccCard(
            icon: Icons.account_balance, label: 'Ngân hàng',
            value: _currency.format(bankBalance), color: Colors.blue,
          )),
        ]),
        if (hasAccounts) ...[
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: onPickMonth,
              icon: const Icon(Icons.calendar_month, size: 15),
              label: Text(periodLabel, style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onPickRange,
              icon: const Icon(Icons.date_range, size: 15),
              label: const Text('Khoảng ngày', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
            if (periodLabel != 'Tất cả') ...[
              const SizedBox(width: 4),
              IconButton(
                onPressed: onClearRange,
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                tooltip: 'Xóa bộ lọc',
              ),
            ],
          ]),
        ] else ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onAddAccount,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Thêm tài khoản'),
          ),
        ],
      ],
    );
  }
}

class _AccCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool active;
  final VoidCallback? onTap;
  const _AccCard({required this.icon, required this.label, required this.value, required this.color, this.active = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: active ? Border.all(color: color, width: 1.5) : null,
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
            Text(label, style: TextStyle(color: color, fontSize: 10), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

Future<void> _showAddAccountDialog(BuildContext context) async {
  final nameCtrl = TextEditingController();
  final acctNumCtrl = TextEditingController();
  final bankCtrl = TextEditingController();
  String type = 'cash';
  bool saving = false;
  String? error;

  await showAdaptiveFormDialog(
    context: context,
    title: 'Thêm tài khoản',
    contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'cash', label: Text('Tiền mặt'), icon: Icon(Icons.money)),
          ButtonSegment(value: 'bank', label: Text('Ngân hàng'), icon: Icon(Icons.account_balance)),
        ],
        selected: {type},
        onSelectionChanged: (s) => setStateDialog(() => type = s.first),
      ),
      const SizedBox(height: 8),
      TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tên tài khoản *')),
      if (type == 'bank') ...[
        const SizedBox(height: 8),
        TextField(controller: acctNumCtrl, decoration: const InputDecoration(labelText: 'Số tài khoản')),
        const SizedBox(height: 8),
        TextField(controller: bankCtrl, decoration: const InputDecoration(labelText: 'Ngân hàng')),
      ],
      if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
    ]),
    actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
      onCancel: saving ? null : () => Navigator.pop(ctx),
      isDirty: () => nameCtrl.text.trim().isNotEmpty,
      primaryButton: ElevatedButton(
        onPressed: saving ? null : () async {
          if (nameCtrl.text.trim().isEmpty) { setStateDialog(() => error = 'Nhập tên tài khoản'); return; }
          setStateDialog(() { saving = true; error = null; });
          try {
            final storeId = (await SupabaseService.client.from('profiles')
                .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
            await SupabaseService.client.from('cash_accounts').insert({
              'store_id': storeId, 'name': nameCtrl.text.trim(), 'type': type,
              'account_number': acctNumCtrl.text.trim().isEmpty ? null : acctNumCtrl.text.trim(),
              'bank_name': bankCtrl.text.trim().isEmpty ? null : bankCtrl.text.trim(),
            });
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
        },
        child: saving
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Lưu'),
      ),
    ),
  );
}

// =====================================================================
// GIAO DỊCH
// =====================================================================
class _TransactionsTab extends StatefulWidget {
  @override
  State<_TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<_TransactionsTab> {
  final _searchCtrl = TextEditingController();
  late final Stream<List<Map<String, dynamic>>> _stream;
  String? _filter; // null | 'income' | 'expense'
  int? _selectedMonth; // null = tất cả, 1-12
  late int _selectedYear;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  @override
  void initState() {
    super.initState();
    _selectedYear = DateTime.now().year;
    _stream = autoReconnectStream(
      () => SupabaseService.client
          .from('transactions')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false),
      label: 'transactions',
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleFilter(String type) {
    setState(() => _filter = _filter == type ? null : type);
  }

  DateTime? _txDate(Map<String, dynamic> r) {
    return DateTime.tryParse(r['transaction_date']?.toString() ?? '') ??
        DateTime.tryParse(r['created_at']?.toString() ?? '');
  }

  bool _inTimeRange(Map<String, dynamic> r) {
    final d = _txDate(r);
    if (d == null) return false;
    if (_rangeStart != null && _rangeEnd != null) {
      final start = DateTime(_rangeStart!.year, _rangeStart!.month, _rangeStart!.day);
      final end = DateTime(_rangeEnd!.year, _rangeEnd!.month, _rangeEnd!.day, 23, 59, 59);
      return !d.isBefore(start) && !d.isAfter(end);
    }
    if (_selectedMonth != null) {
      return d.year == _selectedYear && d.month == _selectedMonth;
    }
    return d.year == _selectedYear;
  }

  String get _periodLabel {
    if (_rangeStart != null && _rangeEnd != null) {
      return '${_dateFmt.format(_rangeStart!)} - ${_dateFmt.format(_rangeEnd!)}';
    }
    if (_selectedMonth != null) return 'Tháng $_selectedMonth/$_selectedYear';
    return 'Năm $_selectedYear';
  }

  void _clearTimeFilter() {
    setState(() {
      _selectedMonth = null;
      _selectedYear = DateTime.now().year;
      _rangeStart = null;
      _rangeEnd = null;
    });
  }

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) {
        int? selected = _selectedMonth;
        return StatefulBuilder(
          builder: (ctx, setDlg) => SimpleDialog(
            title: const Text('Chọn tháng', style: TextStyle(fontSize: 16)),
            children: [
              Wrap(
                spacing: 6, runSpacing: 6,
                children: [
                  _monthChip(ctx, setDlg, 'Tất cả', 0, selected == null),
                  for (int m = 1; m <= 12; m++)
                    _monthChip(ctx, setDlg, 'T$m', m, selected == m),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _rangeStart = null;
        _rangeEnd = null;
        _selectedMonth = picked == 0 ? null : picked;
        _selectedYear = now.year;
      });
    }
  }

  Widget _monthChip(BuildContext ctx, void Function(VoidCallback) setDlg, String label, int value, bool selected) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) { Navigator.pop(ctx, value); },
      selectedColor: const Color(0xFF3B82F6),
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87, fontSize: 12),
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    DateTime start = _rangeStart ?? DateTime(now.year, now.month, 1);
    DateTime end = _rangeEnd ?? now;

    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (ctx) {
        DateTime s = start, e = end;
        return StatefulBuilder(
          builder: (ctx, setDlgState) => AlertDialog(
            title: const Text('Chọn khoảng ngày', style: TextStyle(fontSize: 16)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.calendar_today, size: 18),
                title: Text('Từ: ${_dateFmt.format(s)}', style: const TextStyle(fontSize: 13)),
                onTap: () async {
                  final d = await showDatePicker(context: ctx, initialDate: s, firstDate: DateTime(2020), lastDate: e, locale: const Locale('vi'));
                  if (d != null) setDlgState(() => s = d);
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.calendar_today, size: 18),
                title: Text('Đến: ${_dateFmt.format(e)}', style: const TextStyle(fontSize: 13)),
                onTap: () async {
                  final d = await showDatePicker(context: ctx, initialDate: e, firstDate: s, lastDate: DateTime(now.year + 1, 12, 31), locale: const Locale('vi'));
                  if (d != null) setDlgState(() => e = d);
                },
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
              TextButton(onPressed: () => Navigator.pop(ctx, DateTimeRange(start: s, end: e)), child: const Text('OK')),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _rangeStart = picked.start;
        _rangeEnd = picked.end;
        _selectedMonth = null;
      });
    }
  }

  /// Tìm hoặc tự tạo tài khoản thu chi theo loại ('cash'/'bank') — dùng khi
  /// phiếu thu/chi chọn hình thức thanh toán Tiền mặt / Chuyển khoản.
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

  /// Lấy store_id của người dùng hiện tại (fallback về '' nếu lỗi).
  Future<String> _currentStoreId() async {
    try {
      final user = SupabaseService.currentUser;
      if (user == null) return '';
      final row = await SupabaseService.client.from('profiles')
          .select('store_id').eq('id', user.id).single();
      return (row['store_id'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  /// Bấm vào 1 giao dịch trong danh sách.
  /// - Giao dịch từ ĐƠN SỬA CHỮA (có `repair_order_id`): chỉ xem, mở dialog
  ///   đơn hoàn tất ở chế độ read-only (không đổi trạng thái), có nút "Xem
  ///   đơn" để chuyển sang tab Đơn sửa chữa và trỏ tới đơn đó.
  /// - Giao dịch thu/chi thủ công: mở dialog sửa như cũ.
  Future<void> _onTransactionTap(Map<String, dynamic> t) async {
    final orderId = t['repair_order_id'] as String?;
    if (orderId == null || orderId.isEmpty) {
      _showEditTransactionDialog(context, t);
      return;
    }
    try {
      final row = await SupabaseService.client
          .from('repair_orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();
      if (row == null || !mounted) return;
      final order = ro.RepairOrder.fromMap(row);

      String customerName = '';
      String customerPhone = '';
      try {
        final cust = order.customerId != null
            ? await SupabaseService.client
                .from('customers')
                .select('name, phone')
                .eq('id', order.customerId!)
                .maybeSingle()
            : null;
        customerName = (cust?['name'] ?? '').toString();
        customerPhone = (cust?['phone'] ?? '').toString();
      } catch (_) {}

      await showCompleteOrderDialog(
        context: context,
        order: order,
        customerName: customerName,
        customerPhone: customerPhone,
        allowedStatuses: const [],
        onChangeStatus: (_, __) async {},
        onGoToOrder: () {
          globalRepairOrderFocus.value = RepairOrderFocusRequest(
            orderId: order.id,
            orderCode: order.code,
          );
        },
      );
    } catch (_) {
      // Nếu không tải được đơn, rơi về dialog thường.
      _showEditTransactionDialog(context, t);
    }
  }

  Future<void> _showAddTransactionDialog() async {
    final storeId = await _currentStoreId();
    final amountCtrl = TextEditingController();
    final categoryCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String type = 'income';
    String? payMethod;
    String? accountId;
    DateTime txDate = DateTime.now();
    bool saving = false;
    String? error;
    if (!mounted) return;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Phiếu thu / chi',
      contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'income', label: Text('Phiếu thu'), icon: Icon(Icons.arrow_downward_rounded)),
            ButtonSegment(value: 'expense', label: Text('Phiếu chi'), icon: Icon(Icons.arrow_upward_rounded)),
          ],
          selected: {type},
          onSelectionChanged: (s) => setStateDialog(() => type = s.first),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'cash', label: Text('Tiền mặt'), icon: Icon(Icons.money)),
            ButtonSegment(value: 'transfer', label: Text('Chuyển khoản'), icon: Icon(Icons.account_balance)),
          ],
          selected: payMethod == null ? const <String>{} : {payMethod!},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) async {
            final pm = s.isEmpty ? null : s.first;
            setStateDialog(() => payMethod = pm);
            if (pm == null) { setStateDialog(() => accountId = null); return; }
            try {
              final storeId = (await SupabaseService.client.from('profiles')
                  .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
              final acct = await _ensureAccount(storeId, pm == 'cash' ? 'cash' : 'bank');
              if (ctx.mounted && payMethod == pm) {
                setStateDialog(() => accountId = acct?['id'] as String?);
              }
            } catch (_) {}
          },
        ),
        const SizedBox(height: 12),
        CategoryPickerField(storeId: storeId, controller: categoryCtrl),
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
          label: Text('Ngày ${type == 'income' ? 'thu' : 'chi'}: ${_dateFmt.format(txDate)}'),
        ),
        const SizedBox(height: 8),
        TextField(controller: descCtrl, decoration: const InputDecoration(labelText: 'Ghi chú'), maxLines: 2),
        if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
      ]),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => amountCtrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            final amount = num.tryParse(amountCtrl.text.trim().replaceAll('.', ''));
            if (amount == null || amount <= 0) { setStateDialog(() => error = 'Nhập số tiền hợp lệ.'); return; }
            setStateDialog(() { saving = true; error = null; });
            try {
              final user = SupabaseService.currentUser;
              if (user == null) throw Exception('Chua dang nhap');
              final storeId = (await SupabaseService.client.from('profiles')
                  .select('store_id').eq('id', user.id).single())['store_id'];
              await SupabaseService.client.from('transactions').insert({
                'store_id': storeId, 'type': type, 'category': categoryCtrl.text.trim().isEmpty ? null : categoryCtrl.text.trim(),
                'amount': amount, 'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                'account_id': accountId, 'created_by': user.id,
                'transaction_date': txDate.toIso8601String(),
              });
              final aid = accountId;
              if (aid != null) {
                final acct = await SupabaseService.client.from('cash_accounts')
                    .select('balance').eq('id', aid).single();
                final curBal = (acct['balance'] as num?) ?? 0;
                final newBal = type == 'income' ? curBal + amount : curBal - amount;
                await SupabaseService.client.from('cash_accounts').update({'balance': newBal}).eq('id', aid);
              }
              final categoryText = categoryCtrl.text.trim().isEmpty ? 'Khác' : categoryCtrl.text.trim();
              final descText = descCtrl.text.trim();
              await notifyWholeStore(
                storeId: storeId,
                title: '${type == 'income' ? 'Thu' : 'Chi'} ${_currency.format(amount)} · $categoryText',
                body: descText.isEmpty ? null : descText,
                data: {'finance': true, 'type': type, 'category': categoryText},
              );
              await AppLogger.instance.action(
                '${type == 'income' ? 'Phiếu thu' : 'Phiếu chi'} ${_currency.format(amount)} · $categoryText',
                category: 'tai_chinh',
                data: {'type': type, 'category': categoryText, 'amount': amount, 'account_id': accountId},
              );
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Lưu'),
        ),
      ),
    );
  }

  Future<void> _showEditTransactionDialog(BuildContext context, Map<String, dynamic> t) async {
    final storeId = await _currentStoreId();
    final amountCtrl = TextEditingController(text: MoneyInputField.formatNum((t['amount'] as num?) ?? 0));
    final categoryCtrl = TextEditingController(text: (t['category'] ?? '').toString());
    final descCtrl = TextEditingController(text: (t['description'] ?? '').toString());
    String type = (t['type'] ?? 'income') == 'expense' ? 'expense' : 'income';
    String? payMethod;
    String? accountId = t['account_id'] as String?;
    DateTime txDate = DateTime.tryParse(t['transaction_date']?.toString() ?? '') ??
        DateTime.tryParse(t['created_at']?.toString() ?? '') ??
        DateTime.now();
    bool saving = false;
    String? error;
    final oldAccountId = accountId;
    final oldType = type;
    final oldAmount = (t['amount'] as num?) ?? 0;

    // Xác định hình thức thanh toán từ tài khoản đã chọn trước đó.
    if (oldAccountId != null) {
      try {
        final acct = await SupabaseService.client.from('cash_accounts')
            .select('type').eq('id', oldAccountId).maybeSingle();
        payMethod = acct?['type'] == 'bank' ? 'transfer' : 'cash';
      } catch (_) {}
    }

    if (!context.mounted) return;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Sửa phiếu ${type == 'income' ? 'thu' : 'chi'}',
      contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'income', label: Text('Phiếu thu'), icon: Icon(Icons.arrow_downward_rounded)),
            ButtonSegment(value: 'expense', label: Text('Phiếu chi'), icon: Icon(Icons.arrow_upward_rounded)),
          ],
          selected: {type},
          onSelectionChanged: (s) => setStateDialog(() => type = s.first),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'cash', label: Text('Tiền mặt'), icon: Icon(Icons.money)),
            ButtonSegment(value: 'transfer', label: Text('Chuyển khoản'), icon: Icon(Icons.account_balance)),
          ],
          selected: payMethod == null ? const <String>{} : {payMethod!},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) async {
            final pm = s.isEmpty ? null : s.first;
            setStateDialog(() => payMethod = pm);
            if (pm == null) { setStateDialog(() => accountId = null); return; }
            try {
              final storeId = (await SupabaseService.client.from('profiles')
                  .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
              final acct = await _ensureAccount(storeId, pm == 'cash' ? 'cash' : 'bank');
              if (ctx.mounted && payMethod == pm) {
                setStateDialog(() => accountId = acct?['id'] as String?);
              }
            } catch (_) {}
          },
        ),
        const SizedBox(height: 12),
        CategoryPickerField(storeId: storeId, controller: categoryCtrl),
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
          label: Text('Ngày ${type == 'income' ? 'thu' : 'chi'}: ${_dateFmt.format(txDate)}'),
        ),
        const SizedBox(height: 8),
        TextField(controller: descCtrl, decoration: const InputDecoration(labelText: 'Ghi chú'), maxLines: 2),
        if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
      ]),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => amountCtrl.text.trim() != (t['amount'] as num?)?.toStringAsFixed(0) ||
            categoryCtrl.text.trim() != (t['category'] ?? '').toString() ||
            descCtrl.text.trim() != (t['description'] ?? '').toString() ||
            type != oldType ||
            accountId != oldAccountId ||
            !txDate.isAtSameMomentAs(DateTime.tryParse(t['transaction_date']?.toString() ?? '') ?? txDate),
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            final amount = num.tryParse(amountCtrl.text.trim().replaceAll('.', ''));
            if (amount == null || amount <= 0) { setStateDialog(() => error = 'Nhập số tiền hợp lệ.'); return; }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SupabaseService.client.from('transactions').update({
                'type': type,
                'category': categoryCtrl.text.trim().isEmpty ? null : categoryCtrl.text.trim(),
                'amount': amount,
                'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                'account_id': accountId,
                'transaction_date': txDate.toIso8601String(),
              }).eq('id', t['id']);
              // Đảo ảnh hưởng cũ trên tài khoản cũ.
              if (oldAccountId != null) {
                final acct = await SupabaseService.client.from('cash_accounts')
                    .select('balance').eq('id', oldAccountId).single();
                var bal = (acct['balance'] as num?) ?? 0;
                bal = oldType == 'income' ? bal - oldAmount : bal + oldAmount;
                await SupabaseService.client.from('cash_accounts')
                    .update({'balance': bal}).eq('id', oldAccountId);
              }
              // Áp ảnh hưởng mới lên tài khoản mới.
              final newAccountId = accountId;
              if (newAccountId != null) {
                final acct = await SupabaseService.client.from('cash_accounts')
                    .select('balance').eq('id', newAccountId).single();
                var bal = (acct['balance'] as num?) ?? 0;
                bal = type == 'income' ? bal + amount : bal - amount;
                await SupabaseService.client.from('cash_accounts')
                    .update({'balance': bal}).eq('id', newAccountId);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Lưu'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, allRows) {
          var rows = allRows.where((r) => r['deleted_at'] == null).toList();
          final q = _searchCtrl.text.trim().toLowerCase();
          if (q.isNotEmpty) {
            rows = rows.where((t) =>
                (t['category'] ?? '').toString().toLowerCase().contains(q) ||
                (t['description'] ?? '').toString().toLowerCase().contains(q)).toList();
          }
          // Lọc theo thời gian
          rows = rows.where(_inTimeRange).toList();
          if (_filter != null) {
            rows = rows.where((t) => t['type'] == _filter).toList();
          }

          num filteredIncome = 0, filteredExpense = 0;
          for (final r in rows) {
            final amt = (r['amount'] as num?) ?? 0;
            if (r['type'] == 'income') filteredIncome += amt; else filteredExpense += amt;
          }

          return RealtimeStreamView<List<Map<String, dynamic>>>(
            stream: autoReconnectStream(() => SupabaseService.client.from('cash_accounts').stream(primaryKey: ['id']), label: 'cash_accounts'),
            builder: (context, acctRows) {
              final activeAccts = acctRows.where((a) => a['is_active'] == true).toList();
              num cashBalance = 0, bankBalance = 0;
              for (final a in activeAccts) {
                final bal = (a['balance'] as num?) ?? 0;
                if (a['type'] == 'cash') cashBalance += bal;
                else bankBalance += bal;
              }

              return Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: const InputDecoration(
                          hintText: 'Tìm giao dịch...', isDense: true,
                          prefixIcon: Icon(Icons.search, size: 20),
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    if (_searchCtrl.text.isNotEmpty)
                      IconButton(icon: const Icon(Icons.clear), onPressed: () { _searchCtrl.clear(); setState(() {}); }),
                  ]),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _OverviewSection(
                              cashBalance: cashBalance,
                              bankBalance: bankBalance,
                              hasAccounts: activeAccts.isNotEmpty,
                              onAddAccount: () => _showAddAccountDialog(context),
                              periodLabel: _periodLabel,
                              onPickMonth: _pickMonth,
                              onPickRange: _pickRange,
                              onClearRange: _clearTimeFilter,
                            ),
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 16),
                            if (_filter != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _FilterChip(filter: _filter!, onClear: () => _toggleFilter(_filter!)),
                              ),
                            const Center(child: Text('Chưa có giao dịch nào.', style: TextStyle(color: Colors.black45))),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _OverviewSection(
                              cashBalance: cashBalance,
                              bankBalance: bankBalance,
                              hasAccounts: activeAccts.isNotEmpty,
                              onAddAccount: () => _showAddAccountDialog(context),
                              periodLabel: _periodLabel,
                              onPickMonth: _pickMonth,
                              onPickRange: _pickRange,
                              onClearRange: _clearTimeFilter,
                            ),
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(child: _MiniSummary(label: 'Thu', value: filteredIncome, color: Colors.green, active: _filter == 'income', onTap: () => _toggleFilter('income'))),
                              const SizedBox(width: 8),
                              Expanded(child: _MiniSummary(label: 'Chi', value: filteredExpense, color: Colors.red, active: _filter == 'expense', onTap: () => _toggleFilter('expense'))),
                            ]),
                            if (_filter != null) ...[
                              const SizedBox(height: 8),
                              _FilterChip(filter: _filter!, onClear: () => _toggleFilter(_filter!)),
                            ],
                            const SizedBox(height: 8),
                            for (final t in rows) ...[
                              Builder(builder: (context) {
                                final isIncome = t['type'] == 'income';
                                final createdAt = DateTime.tryParse(t['transaction_date']?.toString() ?? '') ??
                                    DateTime.tryParse(t['created_at'] ?? '');
                                final desc = (t['description'] ?? '').toString();
                                final date = createdAt != null ? _dateFmt.format(createdAt) : '';
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 3),
                                  child: ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                    leading: Icon(
                                      isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                                      color: isIncome ? Colors.green : Colors.red, size: 20,
                                    ),
                                    title: Text(t['category'] ?? (isIncome ? 'Thu' : 'Chi'),
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                    subtitle: Text(
                                      [if (desc.isNotEmpty) desc, if (date.isNotEmpty) date].join(' · '),
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11),
                                    ),
                                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(
                                        (t['repair_order_id'] as String?)?.isNotEmpty == true
                                            ? Icons.chevron_right
                                            : Icons.edit_outlined,
                                        size: 14,
                                        color: Colors.grey,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _currency.format(t['amount'] ?? 0),
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isIncome ? Colors.green : Colors.red),
                                      ),
                                    ]),
                                    onTap: () => _onTransactionTap(t),
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                ),
              ]);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'tx_fab',
        onPressed: _showAddTransactionDialog,
        icon: const Icon(Icons.add),
        label: const Text('Phiếu thu/chi'),
      ),
    );
  }
}

class _MiniSummary extends StatelessWidget {
  final String label; final num value; final Color color; final bool active; final VoidCallback? onTap;
  const _MiniSummary({required this.label, required this.value, required this.color, this.active = false, this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: active ? Border.all(color: color, width: 1.5) : null,
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 14)),
          Text(_currency.format(value), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String filter;
  final VoidCallback onClear;
  const _FilterChip({required this.filter, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final isIncome = filter == 'income';
    final color = isIncome ? Colors.green : Colors.red;
    return Row(children: [
      Icon(isIncome ? Icons.filter_alt : Icons.filter_alt, size: 14, color: color),
      const SizedBox(width: 4),
      Text('Đang lọc: ${isIncome ? 'Thu' : 'Chi'}', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      const SizedBox(width: 4),
      InkWell(onTap: onClear, child: const Padding(
        padding: EdgeInsets.all(2),
        child: Icon(Icons.close, size: 14, color: Colors.grey),
      )),
    ]);
  }
}

// =====================================================================
// CÔNG NỢ
// =====================================================================
class _DebtsTab extends StatefulWidget {
  @override
  State<_DebtsTab> createState() => _DebtsTabState();
}

class _DebtsTabState extends State<_DebtsTab> {
  String _debtType = 'customer'; // 'customer' | 'supplier'

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: autoReconnectStream(() => SupabaseService.client.from('debts').stream(primaryKey: ['id']).order('contact_name'), label: 'debts'),
        builder: (context, rows) {
          final filtered = rows.where((r) => r['type'] == _debtType && r['deleted_at'] == null).toList();
          final allRows = rows.where((r) => r['deleted_at'] == null).toList();
          num totalCustomer = 0, totalSupplier = 0;
          for (final d in allRows) {
            final debt = (d['total_debt'] as num?) ?? 0;
            if (d['type'] == 'customer') totalCustomer += debt; else totalSupplier += debt;
          }

          // Gộp theo contact_name
          final grouped = <String, List<Map<String, dynamic>>>{};
          for (final d in filtered) {
            final name = (d['contact_name'] ?? '').toString();
            grouped.putIfAbsent(name, () => []).add(d);
          }
          final entries = grouped.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

          final color = _debtType == 'customer' ? Colors.orange : Colors.red;
          final icon = _debtType == 'customer' ? Icons.people_outline : Icons.business_outlined;

          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: _MiniSummary(label: 'Khách nợ', value: totalCustomer, color: Colors.orange, active: _debtType == 'customer', onTap: () => setState(() => _debtType = 'customer'))),
                const SizedBox(width: 8),
                Expanded(child: _MiniSummary(label: 'Nợ NCC', value: totalSupplier, color: Colors.red, active: _debtType == 'supplier', onTap: () => setState(() => _debtType = 'supplier'))),
              ]),
            ),
            if (entries.isEmpty)
              Expanded(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Chưa có công nợ nào.', style: TextStyle(color: Colors.black45)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => showAddDebtDialog(context, initialType: _debtType),
                      icon: const Icon(Icons.add, size: 18), label: const Text('Thêm công nợ'),
                    ),
                  ]),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final name = entries[i].key;
                    final debts = entries[i].value;
                    final totalDebt = debts.fold<num>(0, (s, d) => s + ((d['total_debt'] as num?) ?? 0));
                    final count = debts.length;
                    final phone = debts.first['contact_phone'] ?? '';
                    final address = debts.first['contact_address'] ?? '';
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        leading: Icon(icon, color: color, size: 22),
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(
                          [
                            if (phone.isNotEmpty) phone,
                            if (address.isNotEmpty) address,
                          ].join(' · '),
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_currency.format(totalDebt), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: color)),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                        ]),
                        onTap: () => _showDebtOrdersDialog(context, debts, name),
                      ),
                    );
                  },
                ),
              ),
          ]);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'debt_fab',
        onPressed: () => showAddDebtDialog(context, initialType: _debtType),
        icon: const Icon(Icons.add),
        label: const Text('Thêm công nợ'),
      ),
    );
  }

  /// Hiển thị dialog danh sách hóa đơn liên kết khi bấm vào thẻ nợ.
  Future<void> _showDebtOrdersDialog(
    BuildContext context,
    List<Map<String, dynamic>> debts,
    String contactName,
  ) async {
    final totalDebt = debts.fold<num>(0, (s, d) => s + ((d['total_debt'] as num?) ?? 0));
    final isCustomer = (debts.first['type'] ?? '') == 'customer';
    final color = isCustomer ? Colors.orange : Colors.red;

    // Lấy tất cả debt_id + contact_phone
    final debtIds = debts.map((d) => d['id'] as String).toList();
    final contactPhones = debts
        .map((d) => (d['contact_phone'] ?? '').toString().trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();

    List<Map<String, dynamic>> orderItems = [];

    if (isCustomer) {
      // Khách nợ: tìm đơn theo SĐT khách hàng
      // 1) Tìm customer_ids theo SĐT
      Set<String> customerIds = {};
      if (contactPhones.isNotEmpty) {
        try {
          final custRows = await SupabaseService.client
              .from('customers')
              .select('id')
              .inFilter('phone', contactPhones);
          for (final c in custRows as List) {
            customerIds.add(c['id'] as String);
          }
        } catch (_) {}
      }

      // 2) Tìm repair_orders theo customer_id + chưa thanh toán (debt/null payment)
      if (customerIds.isNotEmpty) {
        try {
          final orderRows = await SupabaseService.client
              .from('repair_orders')
              .select('id, code, status, final_cost, estimated_cost, payment_method, paid_at, device_model, customer_id')
              .inFilter('customer_id', customerIds.toList())
              .not('status', 'eq', 'cancelled');
          for (final o in orderRows as List) {
            final paid = o['paid_at'] != null;
            final isDebt = o['payment_method'] == 'debt';
            final cost = ((o['final_cost'] as num?) ?? 0) > 0
                ? (o['final_cost'] as num)
                : ((o['estimated_cost'] as num?) ?? 0);
            orderItems.add({
              'repair_order_id': o['id'] as String,
              'code': o['code'] ?? 'N/A',
              'status': o['status'] ?? 'unknown',
              'cost': cost,
              'paid': paid && !isDebt,
              'device_model': o['device_model'] ?? '',
              'debt_tx_id': null,
            });
          }
        } catch (_) {}
      }

      // 3) Fallback: nếu không tìm thấy customer, parse từ debt_transactions description
      if (orderItems.isEmpty) {
        try {
          final dtRows = await SupabaseService.client
              .from('debt_transactions')
              .select('id, amount, description, type')
              .inFilter('debt_id', debtIds)
              .eq('type', 'add')
              .isFilter('deleted_at', null)
              .order('created_at', ascending: false);
          for (final dt in dtRows as List) {
            final desc = (dt['description'] ?? '').toString();
            // Description format: "Đơn SCxxxxx"
            final match = RegExp(r'Đơn\s+(SC[\w-]+)').firstMatch(desc);
            if (match != null) {
              final code = match.group(1)!;
              try {
                final orows = await SupabaseService.client
                    .from('repair_orders')
                    .select('id, code, status, final_cost, estimated_cost, payment_method, paid_at, device_model')
                    .eq('code', code)
                    .limit(1);
                if ((orows as List).isNotEmpty) {
                  final o = orows.first;
                  final paid = o['paid_at'] != null;
                  final isDebt = o['payment_method'] == 'debt';
                  final cost = ((o['final_cost'] as num?) ?? 0) > 0
                      ? (o['final_cost'] as num)
                      : ((o['estimated_cost'] as num?) ?? 0);
                  orderItems.add({
                    'repair_order_id': o['id'] as String,
                    'code': o['code'] ?? code,
                    'status': o['status'] ?? 'unknown',
                    'cost': cost,
                    'paid': paid && !isDebt,
                    'device_model': o['device_model'] ?? '',
                    'debt_tx_id': dt['id'] as String,
                  });
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    } else {
      // Nợ NCC: tìm theo debt_transactions.repair_order_id
      List<Map<String, dynamic>> dtRows = [];
      try {
        final rows = await SupabaseService.client
            .from('debt_transactions')
            .select('id, amount, description, repair_order_id, type, created_at')
            .inFilter('debt_id', debtIds)
            .eq('type', 'add')
            .isFilter('deleted_at', null)
            .order('created_at', ascending: false);
        dtRows = (rows as List).where((r) => r['repair_order_id'] != null).cast<Map<String, dynamic>>().toList();
      } catch (_) {}

      if (dtRows.isNotEmpty) {
        final orderIds = dtRows.map((r) => r['repair_order_id'] as String).toSet().toList();
        Map<String, Map<String, dynamic>> orderMap = {};
        try {
          final orderRows = await SupabaseService.client
              .from('repair_orders')
              .select('id, code, status, final_cost, estimated_cost, payment_method, paid_at, device_model')
              .inFilter('id', orderIds);
          for (final r in orderRows as List) {
            orderMap[r['id'] as String] = Map<String, dynamic>.from(r);
          }
        } catch (_) {}

        for (final dt in dtRows) {
          final orderId = dt['repair_order_id'] as String;
          final order = orderMap[orderId];
          final cost = order != null
              ? ((order['final_cost'] as num?) ?? 0) > 0
                  ? (order['final_cost'] as num)
                  : ((order['estimated_cost'] as num?) ?? 0)
              : (dt['amount'] as num?) ?? 0;
          orderItems.add({
            'debt_tx_id': dt['id'],
            'repair_order_id': orderId,
            'code': order?['code'] ?? 'N/A',
            'status': order?['status'] ?? 'unknown',
            'cost': cost,
            'paid': order?['payment_method'] != null && order?['payment_method'] != 'debt',
            'device_model': order?['device_model'] ?? '',
          });
        }
      }
    }

    if (!context.mounted) return;

    // Hiển thị dialog chọn đơn + thanh toán
    await showDebtOrdersPaymentDialog(
      context: context,
      contactName: contactName,
      totalDebt: totalDebt,
      color: color,
      isCustomer: isCustomer,
      orderItems: orderItems,
      debts: debts,
    );
  }
}

class DebtGroupDetailScreen extends StatelessWidget {
  final List<Map<String, dynamic>> debts;
  final String groupName;
  const DebtGroupDetailScreen({super.key, required this.debts, required this.groupName});

  @override
  Widget build(BuildContext context) {
    final totalDebt = debts.fold<num>(0, (s, d) => s + ((d['total_debt'] as num?) ?? 0));
    final isCustomer = (debts.first['type'] ?? '') == 'customer';
    final color = isCustomer ? Colors.orange : Colors.red;

    final phone = (debts.first['contact_phone'] ?? '').toString();
    final addr = (debts.first['contact_address'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: Text(groupName, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: Column(children: [
          // Tổng nợ + SĐT + Địa chỉ
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: color.withValues(alpha: 0.08),
            child: Column(children: [
              Text('Tổng nợ', style: TextStyle(color: color, fontSize: 12)),
              const SizedBox(height: 4),
              Text(_currency.format(totalDebt), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: color)),
              if (phone.isNotEmpty || addr.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  [if (phone.isNotEmpty) phone, if (addr.isNotEmpty) addr].join(' · '),
                  style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 12),
                ),
              ],
            ]),
          ),
          // Danh sách khoản nợ (read-only)
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: debts.length,
              itemBuilder: (_, i) {
                final d = debts[i];
                final debt = (d['total_debt'] as num?) ?? 0;
                final phone = d['contact_phone'] ?? '';
                final note = d['note'] ?? '';
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  child: ListTile(
                    leading: Icon(
                      isCustomer ? Icons.people_outline : Icons.business_outlined,
                      color: color, size: 20,
                    ),
                    title: Text('${_currency.format(debt)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
                    subtitle: Builder(builder: (ctx) {
                      final info = [if (phone.isNotEmpty) phone, if (note.isNotEmpty) note].join(' · ');
                      return Text(info.isEmpty ? 'Không có ghi chú' : info,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11));
                    }),
                    trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                    onTap: () => showDebtDetail(context, d),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'debt_group_fab',
        onPressed: () => showAddDebtDialog(context, initialType: isCustomer ? 'customer' : 'supplier', showTypeSelector: false),
        icon: const Icon(Icons.add),
        label: const Text('Thêm khoản nợ'),
      ),
    );
  }
}

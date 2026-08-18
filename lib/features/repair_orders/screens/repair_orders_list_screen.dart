import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/notify_helper.dart';
import '../../../core/app_logger.dart';
import '../../../core/app_toast.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/photo_upload.dart';
import '../../../core/printer_service.dart';
import '../../../models/repair_order.dart';
import '../../../models/store.dart';
import '../../../widgets/status_chip.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/money_input_field.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/anchor_dropdown.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../core/discord_webhook.dart';
import '../../../core/error_utils.dart';
import 'complete_orders_list_screen.dart';

final _dateFmt = DateFormat('dd/MM/yyyy');
final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

const _commonDeviceModels = [
  'iPhone 11', 'iPhone 12', 'iPhone 13', 'iPhone 13 Pro Max', 'iPhone 14',
  'iPhone 14 Pro Max', 'iPhone 15', 'iPhone 15 Pro Max', 'iPhone 16', 'iPhone 16 Pro Max',
  'Samsung Galaxy S23', 'Samsung Galaxy S24', 'Samsung Galaxy A54', 'Samsung Galaxy A15',
  'Samsung Galaxy Note 20', 'Xiaomi Redmi Note 12', 'Xiaomi Redmi Note 13',
  'Oppo Reno 8', 'Oppo A78', 'Vivo Y36',
];

/// Danh sách đơn sửa chữa, tự cập nhật realtime nhờ Supabase Realtime.
/// [technicianId]: nếu khác null -> chỉ hiển thị đơn được giao cho kỹ thuật viên đó.
class RepairOrdersListScreen extends StatefulWidget {
  final String? technicianId;
  final String? initialSearch;
  final Widget? appBarLeading;
  const RepairOrdersListScreen({super.key, this.technicianId, this.initialSearch, this.appBarLeading});

  @override
  State<RepairOrdersListScreen> createState() => _RepairOrdersListScreenState();
}

class _RepairOrdersListScreenState extends State<RepairOrdersListScreen> {
  late final StreamController<List<Map<String, dynamic>>> _ordersController;
  StreamSubscription<List<Map<String, dynamic>>>? _ordersSub;
  StreamController<List<Map<String, dynamic>>>? _customersController;
  StreamSubscription<List<Map<String, dynamic>>>? _customersSub;
  final Set<String> _selectedIds = {};
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  final Set<String> _statusFilter = {};
  int? _filterMonth; // 1..12 — null = tất cả
  int? _filterYear;  // null = tất cả
  final _filterBtnKey = GlobalKey();
  String? _cachedStoreId;
  final Set<String> _agingAlertsInFlight = {};
  bool _sortByPaidDate = false;
  List<Map<String, dynamic>> _latestRows = [];

  @override
  void initState() {
    super.initState();
    // Dùng StreamController trung gian: vừa nhận dữ liệu realtime, vừa cho
    // phép refetch thủ công (sau khi tạo/sửa đơn, kéo để làm mới). Nếu realtime
    // bị đứng (socket rớt / JWT hết hạn) mà không phát sự kiện, dữ liệu vẫn
    // được cập nhật nhờ _reloadOrders(). Trước đây màn này phụ thuộc hoàn toàn
    // vào realtime nên có lúc tạo đơn thành công nhưng danh sách không hiện,
    // phải khởi động lại app mới thấy.
    _ordersController = StreamController<List<Map<String, dynamic>>>.broadcast();
    // Bọc autoReconnectStream: khi socket rớt làm stream lỗi (timedOut),
    // stream tự kết nối lại thay vì chết vĩnh viễn cho tới khi mở lại màn hình.
    _ordersSub = autoReconnectStream(
      () => SupabaseService.client
          .from('repair_orders')
          .stream(primaryKey: ['id'])
          .order('received_at', ascending: false),
      label: 'repair_orders',
    ).listen(_ordersController.add, onError: (Object e) {
      if (!_ordersController.isClosed) _ordersController.addError(e);
    });
    _customersController = StreamController<List<Map<String, dynamic>>>.broadcast();
    _customersSub = autoReconnectStream(
      () => SupabaseService.client
          .from('customers')
          .stream(primaryKey: ['id']),
      label: 'customers',
    ).listen(_customersController!.add, onError: (Object e) {
      if (_customersController != null && !_customersController!.isClosed) {
        _customersController!.addError(e);
      }
    });
    _currentStoreId().then((id) {
      if (mounted) setState(() => _cachedStoreId = id);
    });
    if (widget.initialSearch != null && widget.initialSearch!.isNotEmpty) {
      _showSearch = true;
      _searchCtrl.text = widget.initialSearch!;
    }
    _reloadOrders();
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    _ordersController.close();
    _customersSub?.cancel();
    _customersController?.close();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Tải lại danh sách đơn từ server, đẩy vào [_ordersController] để màn hình
  /// cập nhật ngay cả khi realtime không phát sự kiện.
  Future<void> _reloadOrders() async {
    try {
      final rows = await SupabaseService.client
          .from('repair_orders')
          .select()
          .order('received_at', ascending: false);
      if (!_ordersController.isClosed) _ordersController.add(rows);
    } catch (_) {
      // Bỏ qua: realtime (nếu còn sống) sẽ tự cập nhật, hoặc lần kéo-tải lại sau sẽ thử tiếp.
    }
  }

  // ---------------- Cảnh báo đơn "ì" lâu chưa đổi trạng thái ----------------

  /// Số ngày kể từ lần cuối đổi trạng thái, ứng với mốc cảnh báo đạt được:
  /// - received/repairing: 2 ngày (cam nhạt) / 5 ngày (đỏ nhạt)
  /// - repaired: 7 ngày (xanh dương) — sửa xong lâu mà chưa trả máy
  int _agingLevelFor(RepairOrder order) {
    final days = DateTime.now().difference(order.statusChangedAt).inDays;
    if (order.status == 'received' || order.status == 'repairing') {
      if (days >= 5) return 5;
      if (days >= 2) return 2;
      return 0;
    }
    if (order.status == 'repaired' && days >= 7) return 7;
    return 0;
  }

  Color? _agingCodeColor(RepairOrder order) {
    switch (_agingLevelFor(order)) {
      case 5:
        return const Color(0xFFEF4444); // đỏ nhạt
      case 2:
        return const Color(0xFFF59E0B); // cam nhạt
      case 7:
        return order.status == 'repaired' ? const Color(0xFF3B82F6) : null; // xanh dương
      default:
        return null;
    }
  }

  /// Quét danh sách đơn mỗi khi có dữ liệu mới, tự thông báo cho người liên
  /// quan (KTV/người được giao + toàn bộ admin) khi 1 đơn vừa đạt mốc cảnh
  /// báo mới. `aging_alert_level` lưu trong DB đảm bảo mỗi mốc chỉ báo 1
  /// lần, không bị spam mỗi lần app tải lại dữ liệu.
  /// Lưu ý: đây là kiểm tra phía client — chỉ chạy khi có người đang mở màn
  /// hình này. Muốn cảnh báo đúng giờ kể cả khi không ai mở app, cần thêm
  /// Supabase Edge Function chạy theo lịch (pg_cron) ở phía server.
  void _checkAgingAlerts(List<Map<String, dynamic>> rawRows) {
    final storeId = _cachedStoreId;
    if (storeId == null) return;
    for (final r in rawRows) {
      if (r['deleted_at'] != null) continue;
      final order = RepairOrder.fromMap(r);
      final level = _agingLevelFor(order);
      if (level == 0 || level <= order.agingAlertLevel) continue;
      final key = '${order.id}_$level';
      if (_agingAlertsInFlight.contains(key)) continue;
      _agingAlertsInFlight.add(key);
      _sendAgingAlert(order, level, storeId);
    }
  }

  Future<void> _sendAgingAlert(RepairOrder order, int level, String storeId) async {
    try {
      await SupabaseService.client
          .from('repair_orders')
          .update({'aging_alert_level': level}).eq('id', order.id);

      final title = order.status == 'repaired'
          ? 'Đơn ${order.code} đã sửa xong $level ngày chưa trả máy'
          : 'Đơn ${order.code} chưa cập nhật trạng thái $level ngày';

      final recipients = <String>{};
      if (order.technicianId != null) recipients.add(order.technicianId!);
      try {
        final admins = await SupabaseService.client
            .from('profiles')
            .select('id')
            .eq('store_id', storeId)
            .eq('role', 'admin');
        for (final a in admins as List) {
          recipients.add(a['id'] as String);
        }
      } catch (_) {}

      for (final uid in recipients) {
        await SupabaseService.client.from('notifications').insert({
          'store_id': storeId,
          'user_id': uid,
          'title': title,
          'body': 'Vui lòng kiểm tra và cập nhật đơn sửa chữa.',
          'data': {'order_id': order.id, 'order_code': order.code},
        });
      }
    } catch (_) {}
  }

  Future<void> _showStatusFilterMenu() async {
    final anchor = _filterBtnKey.currentContext;
    if (anchor == null) return;
    final temp = Set<String>.from(_statusFilter);
    var tempMonth = _filterMonth;
    var tempYear = _filterYear;
    final years = List.generate(6, (i) => DateTime.now().year - i);
    final result = await showAnchorDropdownPanel<(Set<String>, int?, int?)>(
      anchorContext: anchor,
      width: 280,
      builder: (ctx, close) {
        return StatefulBuilder(
          builder: (ctx, setStateInner) => ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(
                    children: [
                      const Text('Lọc đơn', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setStateInner(() {
                          temp.clear();
                          tempMonth = null;
                          tempYear = null;
                        }),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('Bỏ lọc', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final s in repairStatusOptions)
                          CheckboxListTile(
                            dense: true,
                            value: temp.contains(s),
                            title: Text(StatusColors.label[s] ?? s, style: const TextStyle(fontSize: 13)),
                            secondary: Icon(Icons.circle, size: 10, color: StatusColors.map[s]),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (checked) => setStateInner(() {
                              if (checked == true) {
                                temp.add(s);
                              } else {
                                temp.remove(s);
                              }
                            }),
                          ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                    const Text('Tháng', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Builder(
                      builder: (fieldCtx) => InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          // Nested dropdown: dùng cùng cơ chế Overlay nên hiển
                          // thị ĐÈ LÊN panel bộ lọc (DropdownButton bị xếp
                          // dưới panel nên ẩn sau).
                          final v = await showAnchorDropdownPanel<int>(
                            anchorContext: fieldCtx,
                            width: 140,
                            estimatedHeight: 420,
                            builder: (ctx, close) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  dense: true,
                                  title: const Text('Tất cả', style: TextStyle(fontSize: 13)),
                                  trailing: tempMonth == null ? const Icon(Icons.check, size: 16) : null,
                                  onTap: () => close(0),
                                ),
                                for (var m = 1; m <= 12; m++)
                                  ListTile(
                                    dense: true,
                                    title: Text('Tháng $m', style: const TextStyle(fontSize: 13)),
                                    trailing: tempMonth == m ? const Icon(Icons.check, size: 16) : null,
                                    onTap: () => close(m),
                                  ),
                              ],
                            ),
                          );
                          if (v != null) setStateInner(() => tempMonth = v == 0 ? null : v);
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Theme.of(ctx).colorScheme.outline),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tempMonth == null ? 'Tất cả' : 'Tháng $tempMonth',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('Năm', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Builder(
                      builder: (fieldCtx) => InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          final v = await showAnchorDropdownPanel<int>(
                            anchorContext: fieldCtx,
                            width: 140,
                            estimatedHeight: 260,
                            builder: (ctx, close) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  dense: true,
                                  title: const Text('Tất cả', style: TextStyle(fontSize: 13)),
                                  trailing: tempYear == null ? const Icon(Icons.check, size: 16) : null,
                                  onTap: () => close(0),
                                ),
                                for (final y in years)
                                  ListTile(
                                    dense: true,
                                    title: Text('$y', style: const TextStyle(fontSize: 13)),
                                    trailing: tempYear == y ? const Icon(Icons.check, size: 16) : null,
                                    onTap: () => close(y),
                                  ),
                              ],
                            ),
                          );
                          if (v != null) setStateInner(() => tempYear = v == 0 ? null : v);
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Theme.of(ctx).colorScheme.outline),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tempYear == null ? 'Tất cả' : '$tempYear',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            ),
          ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => close((temp, tempMonth, tempYear)),
                    child: const Text('Áp dụng'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
    );
    if (result != null) {
      setState(() {
        _statusFilter
          ..clear()
          ..addAll(result.$1);
        _filterMonth = result.$2;
        _filterYear = result.$3;
      });
    }
  }

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

  Future<String> _currentStoreId() async {
    final row = await SupabaseService.client
        .from('profiles')
        .select('store_id')
        .eq('id', SupabaseService.currentUser?.id ?? '')
        .single();
    return row['store_id'] as String;
  }

  /// Tìm tài khoản theo loại, nếu không có thì tự tạo mới.
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
      // Retry SELECT once (another concurrent call may have created it)
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

  /// Ghi nhận doanh thu (tiền mặt/chuyển khoản) hoặc công nợ khi đơn chuyển
  /// sang "đã trả máy". Dùng chung cho mọi luồng: tạo đơn, sửa 1 đơn, quick
  /// menu và xử lý hàng loạt (bulk) để không bị lệch doanh thu.
  /// Ghi nhận doanh thu (tiền mặt/chuyển khoản) hoặc công nợ khi đơn "đã trả máy".
  /// Idempotent: nếu đơn đã có hạch toán (income theo repair_order_id / phát sinh nợ
  /// theo mã đơn) thì chỉ điều chỉnh theo chênh lệch giá, tránh ghi trùng khi đơn
  /// chuyển delivered nhiều lần hoặc sửa lại giá/phương thức thanh toán.
  Future<void> _recordDeliveredRevenue({
    required String orderId,
    required String orderCode,
    required String? customerId,
    required String storeId,
    required String uid,
    String? paymentMethod,
    required num amount,
    DateTime? transactionDate,
  }) async {
    if (amount <= 0) return;
    final pm = paymentMethod ?? 'cash';

    if (pm == 'debt') {
      try {
        String? contactPhone;
        String? contactName;
        try {
          final c = customerId != null
              ? await SupabaseService.client
                  .from('customers')
                  .select('name, phone')
                  .eq('id', customerId)
                  .maybeSingle()
              : null;
          contactName = c?['name'] as String?;
          contactPhone = c?['phone'] as String?;
        } catch (_) {}

        // Đã có phát sinh nợ cho đơn này -> chỉ chỉnh lại số tiền (chênh lệch).
        final debtTx = await SupabaseService.client
            .from('debt_transactions')
            .select('id, debt_id, amount')
            .eq('store_id', storeId)
            .eq('type', 'add')
            .eq('description', 'Đơn $orderCode')
            .maybeSingle();
        if (debtTx != null) {
          final diff = amount - ((debtTx['amount'] as num?) ?? amount);
          if (diff != 0) {
            await SupabaseService.client.from('debt_transactions')
                .update({'amount': amount}).eq('id', debtTx['id']);
            final debtId = debtTx['debt_id'] as String?;
            if (debtId != null) {
              final debt = await SupabaseService.client
                  .from('debts').select('total_debt').eq('id', debtId).maybeSingle();
              if (debt != null) {
                final newDebt = ((debt['total_debt'] as num?) ?? 0) + diff;
                await SupabaseService.client.from('debts')
                    .update({'total_debt': newDebt > 0 ? newDebt : 0}).eq('id', debtId);
              }
            }
          }
          return;
        }

        String? debtId;
        final existing = contactPhone != null && contactPhone.isNotEmpty
            ? await SupabaseService.client
                .from('debts')
                .select('id, total_debt')
                .eq('store_id', storeId)
                .eq('type', 'customer')
                .eq('contact_phone', contactPhone)
                .maybeSingle()
            : null;
        if (existing != null) {
          await SupabaseService.client.from('debts')
              .update({'total_debt': ((existing['total_debt'] as num?) ?? 0) + amount}).eq('id', existing['id']);
          debtId = existing['id'] as String?;
        } else {
          final inserted = await SupabaseService.client.from('debts').insert({
            'store_id': storeId, 'type': 'customer',
            'contact_name': contactName ?? '', 'contact_phone': contactPhone,
            'total_debt': amount, 'note': 'Đơn sửa chữa $orderCode',
          }).select('id').single();
          debtId = inserted['id'] as String?;
        }
        if (debtId != null) {
          await SupabaseService.client.from('debt_transactions').insert({
            'store_id': storeId, 'debt_id': debtId, 'type': 'add',
            'amount': amount, 'description': 'Đơn $orderCode', 'created_by': uid,
          });
        }
      } catch (_) {}
      return;
    }

    try {
      final acctType = pm == 'cash' ? 'cash' : 'bank';
      final acct = await _ensureAccount(storeId, acctType);

      // Đã có thu nhập cho đơn này -> chỉ chỉnh lại số tiền (chênh lệch).
      // Bỏ qua phiếu đã xoá mềm (deleted_at) để không "tưởng" là đã ghi rồi
      // khi đơn bị đảo (trả máy -> đang sửa) rồi trả máy lại -> ghi lại đầy đủ.
      final incomeTx = await SupabaseService.client
          .from('transactions')
          .select('id, amount, account_id, transaction_date')
          .eq('repair_order_id', orderId)
          .eq('type', 'income')
          .isFilter('deleted_at', null)
          .maybeSingle();
      if (incomeTx != null) {
        final diff = amount - ((incomeTx['amount'] as num?) ?? amount);
        if (diff != 0) {
          await SupabaseService.client.from('transactions')
              .update({'amount': amount}).eq('id', incomeTx['id']);
          final acctId = (incomeTx['account_id'] as String?) ?? (acct?['id'] as String?);
          if (acctId != null) {
            final a = await SupabaseService.client
                .from('cash_accounts').select('balance').eq('id', acctId).maybeSingle();
            if (a != null) {
              await SupabaseService.client.from('cash_accounts')
                  .update({'balance': ((a['balance'] as num?) ?? 0) + diff}).eq('id', acctId);
            }
          }
        }
        final existingDate = DateTime.tryParse(incomeTx['transaction_date']?.toString() ?? '');
        if (transactionDate != null &&
            (existingDate == null || !existingDate.isAtSameMomentAs(transactionDate))) {
          await SupabaseService.client.from('transactions')
              .update({'transaction_date': transactionDate.toIso8601String()}).eq('id', incomeTx['id']);
        }
        return;
      }

      await SupabaseService.client.from('transactions').insert({
        'store_id': storeId, 'type': 'income', 'category': 'Sửa chữa',
        'amount': amount, 'description': 'Đơn $orderCode',
        'created_by': uid, if (acct != null) 'account_id': acct['id'],
        'repair_order_id': orderId,
        'transaction_date': (transactionDate ?? DateTime.now()).toIso8601String(),
      });
      if (acct != null) {
        await SupabaseService.client.from('cash_accounts')
            .update({'balance': ((acct['balance'] as num?) ?? 0) + amount})
            .eq('id', acct['id']);
      }
      await notifyWholeStore(
        storeId: storeId,
        title: 'Thu ${_currency.format(amount)} · Đơn $orderCode',
        body: 'Thanh toán đơn sửa chữa · ${pm == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'}',
        data: {'finance': true, 'type': 'income', 'category': 'Sửa chữa', 'order_code': orderCode},
      );
    } catch (_) {}
  }

  /// Đảo ngược hạch toán khi xóa đơn đã trả máy (cash/bank -> hoàn két + xóa
  /// income; debt -> giảm công nợ + xóa phát sinh) để sổ sách không lệch.
  /// Đảo TẤT CẢ giao dịch khớp (phòng trường hợp ghi trùng trước đây).
  Future<void> _reverseOrderRevenue(RepairOrder o, String storeId) async {
    if (o.status != 'delivered') return;
    final amount = o.finalCost > 0 ? o.finalCost : o.estimatedCost;
    if (amount <= 0) return;

    if (o.paymentMethod == 'debt') {
      try {
        final rows = await SupabaseService.client
            .from('debt_transactions')
            .select('id, debt_id')
            .eq('store_id', storeId)
            .eq('type', 'add')
            .eq('description', 'Đơn ${o.code}');
        if (rows == null || (rows as List).isEmpty) return;
        final ids = (rows as List).map((r) => r['id'] as String).toList();
        final debtId = rows.first['debt_id'] as String?;
        await SupabaseService.client.from('debt_transactions').update({
          'deleted_at': DateTime.now().toIso8601String(),
          'deleted_by': SupabaseService.currentUser?.id ?? '',
        }).inFilter('id', ids);
        if (debtId != null) {
          final debt = await SupabaseService.client
              .from('debts')
              .select('total_debt')
              .eq('id', debtId)
              .maybeSingle();
          if (debt != null) {
            final remaining = ((debt['total_debt'] as num?) ?? 0) - (amount * ids.length);
            await SupabaseService.client.from('debts')
                .update({'total_debt': remaining > 0 ? remaining : 0})
                .eq('id', debtId);
          }
        }
      } catch (_) {}
      return;
    }

    try {
      final rows = await SupabaseService.client
          .from('transactions')
          .select('id, amount, account_id')
          .eq('repair_order_id', o.id)
          .eq('type', 'income')
          .isFilter('deleted_at', null);
      if (rows == null || (rows as List).isEmpty) return;
      var refundTotal = 0;
      final acctId = (rows as List).first['account_id'] as String?;
      for (final r in rows) {
        refundTotal += (r['amount'] as num?)?.toInt() ?? 0;
      }
      if (acctId != null && refundTotal > 0) {
        final acct = await SupabaseService.client
            .from('cash_accounts')
            .select('balance')
            .eq('id', acctId)
            .maybeSingle();
        if (acct != null) {
          final newBalance = ((acct['balance'] as num?) ?? 0) - refundTotal;
          await SupabaseService.client.from('cash_accounts')
              .update({'balance': newBalance > 0 ? newBalance : 0})
              .eq('id', acctId);
        }
      }
      final txIds = (rows as List).map((r) => r['id'] as String).toList();
      await SupabaseService.client.from('transactions').update({
        'deleted_at': DateTime.now().toIso8601String(),
        'deleted_by': SupabaseService.currentUser?.id ?? '',
      }).inFilter('id', txIds);
    } catch (_) {}
  }

  /// Đảo khoản nợ NCC / phiếu chi linh kiện ngoài mua cho đơn (được ghi lúc lưu
  /// đơn với mô tả gắn mã đơn). Dùng khi hủy đơn để không còn sót công nợ.
  Future<void> _reverseOrderExternalPayments(RepairOrder o, String storeId) async {
    // 1) Nợ NCC từ linh kiện ngoài của đơn: xoá phát sinh 'add' + trừ dư nợ NCC.
    final matched = <Map<String, dynamic>>[];
    try {
      final res = await SupabaseService.client
          .from('debt_transactions')
          .select('id, amount, debt_id, description')
          .eq('store_id', storeId)
          .eq('repair_order_id', o.id);
      matched.addAll((res as List).cast<Map<String, dynamic>>());
    } catch (_) {
      // Cột mới chưa có (chưa chạy migration) -> dò theo mô tả.
    }
    if (matched.isEmpty) {
      try {
        final fetched = await SupabaseService.client
            .from('debt_transactions')
            .select('id, amount, debt_id, description')
            .eq('store_id', storeId)
            .eq('type', 'add')
            .like('description', '%Nhập kho%');
        matched.addAll((fetched as List)
            .where((r) => _norm((r['description'] ?? '').toString()).contains(_norm('Đơn ${o.code}')))
            .cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    if (matched.isNotEmpty) {
      var total = 0;
      final debtIds = <String>{};
      for (final r in matched) {
        total += (r['amount'] as num?)?.toInt() ?? 0;
        final d = r['debt_id'] as String?;
        if (d != null) debtIds.add(d);
      }
      final txIds = matched.map((r) => r['id'] as String).toList();
      try {
        await SupabaseService.client.from('debt_transactions')
            .delete().inFilter('id', txIds);
      } catch (_) {
        try {
          await SupabaseService.client.from('debt_transactions').update({
            'deleted_at': DateTime.now().toIso8601String(),
            'deleted_by': SupabaseService.currentUser?.id ?? '',
          }).inFilter('id', txIds);
        } catch (_) {}
      }
      for (final debtId in debtIds) {
        try {
          final debt = await SupabaseService.client
              .from('debts').select('total_debt').eq('id', debtId).maybeSingle();
          if (debt != null) {
            final remaining = ((debt['total_debt'] as num?) ?? 0) - total;
            await SupabaseService.client.from('debts')
                .update({'total_debt': remaining > 0 ? remaining : 0}).eq('id', debtId);
          }
        } catch (_) {}
      }
    }

    // 2) Phiếu chi linh kiện ngoài của đơn: xoá phiếu chi + hoàn lại két.
    try {
      final rows = await SupabaseService.client
          .from('transactions')
          .select('id, amount, account_id')
          .eq('repair_order_id', o.id)
          .eq('type', 'expense')
          .eq('category', 'Linh kiện');
      if ((rows as List).isNotEmpty) {
        var refund = 0;
        final acctId = (rows as List).first['account_id'] as String?;
        for (final r in rows as List) {
          refund += (r['amount'] as num?)?.toInt() ?? 0;
        }
        if (acctId != null && refund > 0) {
          try {
            final acct = await SupabaseService.client
                .from('cash_accounts').select('balance').eq('id', acctId).maybeSingle();
            if (acct != null) {
              await SupabaseService.client.from('cash_accounts')
                  .update({'balance': ((acct['balance'] as num?) ?? 0) + refund}).eq('id', acctId);
            }
          } catch (_) {}
        }
        final ids = (rows as List).map((r) => r['id'] as String).toList();
        await SupabaseService.client.from('transactions').update({
          'deleted_at': DateTime.now().toIso8601String(),
          'deleted_by': SupabaseService.currentUser?.id ?? '',
        }).inFilter('id', ids);
      }
    } catch (_) {}

    // 3) Linh kiện ngoài của đơn (mua riêng cho đơn): xóa khỏi kho — đơn không
    // dùng nữa (hủy/xóa) thì không để lại linh kiện "ảo" trong kho.
    try {
      final rows = await SupabaseService.client
          .from('inventory_transactions')
          .select('part_id, inventory_parts(is_external)')
          .eq('repair_order_id', o.id)
          .eq('type', 'out');
      final externalPartIds = <String>{};
      for (final r in rows as List) {
        final pi = r['inventory_parts'] as Map<String, dynamic>?;
        if (pi?['is_external'] == true) externalPartIds.add(r['part_id'] as String);
      }
      if (externalPartIds.isNotEmpty) {
        final now = DateTime.now().toIso8601String();
        for (final pid in externalPartIds) {
          await SupabaseService.client.from('inventory_transactions').delete().eq('part_id', pid);
          // Xoá hẳn linh kiện ngoài khỏi kho (không để lại bản ghi). Nếu chưa
          // chạy migration (policy xoá / cascade chưa có) thì fallback soft-delete.
          try {
            await SupabaseService.client.from('inventory_parts').delete().eq('id', pid);
          } catch (_) {
            await SupabaseService.client.from('inventory_parts').update({
              'deleted_at': now,
            }).eq('id', pid);
          }
        }
      }
    } catch (_) {}

    // 4) Thu hồi thông báo Nợ NCC / Chi linh kiện của đơn.
    await _revokeOrderNotifications(o.id, o.code, storeId);
  }

  /// Đảo phiếu chi / nợ NCC của một linh kiện ngoài khi bỏ linh kiện này ra
  /// khỏi đơn đang sửa (dùng kèm xóa bản ghi linh kiện khỏi kho).
  Future<void> _reverseExternalPart({
    required String orderCode,
    required String orderId,
    required String storeId,
    required String partId,
    required String partName,
  }) async {
    // 1) Nợ NCC từ linh kiện ngoài. Ưu tiên dò theo repair_order_id +
    // inventory_part_id (chính xác 100%). Nếu chưa chạy migration hoặc dữ
    // liệu cũ chưa có liên kết -> dò theo mô tả 'Đơn <code>' + tên linh kiện
    // (chuẩn hoá hoa/thường + khoảng trắng để dễ khớp hơn).
    final matched = <Map<String, dynamic>>[];
    try {
      final res = await SupabaseService.client
          .from('debt_transactions')
          .select('id, amount, debt_id, description')
          .eq('store_id', storeId)
          .eq('repair_order_id', orderId)
          .eq('inventory_part_id', partId);
      matched.addAll((res as List).cast<Map<String, dynamic>>());
    } catch (_) {
      // Cột mới chưa có (chưa chạy migration) -> rơi xuống dò theo mô tả.
    }
    if (matched.isEmpty) {
      try {
        final fetched = await SupabaseService.client
            .from('debt_transactions')
            .select('id, amount, debt_id, description')
            .eq('store_id', storeId)
            .eq('type', 'add')
            .like('description', '%Nhập kho%');
        matched.addAll((fetched as List).where((r) {
          final desc = _norm((r['description'] ?? '').toString());
          if (!desc.contains(_norm('Đơn $orderCode'))) return false;
          final name = _norm(partName);
          if (name.isEmpty) return true;
          return desc.contains(name);
        }).cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    if (matched.isNotEmpty) {
      var total = 0;
      final debtIds = <String>{};
      for (final r in matched) {
        total += (r['amount'] as num?)?.toInt() ?? 0;
        final d = r['debt_id'] as String?;
        if (d != null) debtIds.add(d);
      }
      final txIds = matched.map((r) => r['id'] as String).toList();
      // Xoá hẳn phiếu nợ (không để lại trong thùng rác). Nếu chưa chạy migration
      // (thiếu policy delete) thì fallback đánh dấu deleted_at.
      try {
        await SupabaseService.client.from('debt_transactions')
            .delete().inFilter('id', txIds);
      } catch (_) {
        try {
          await SupabaseService.client.from('debt_transactions').update({
            'deleted_at': DateTime.now().toIso8601String(),
            'deleted_by': SupabaseService.currentUser?.id ?? '',
          }).inFilter('id', txIds);
        } catch (_) {}
      }
      for (final debtId in debtIds) {
        try {
          final debt = await SupabaseService.client
              .from('debts').select('total_debt').eq('id', debtId).maybeSingle();
          if (debt != null) {
            final remaining = ((debt['total_debt'] as num?) ?? 0) - total;
            await SupabaseService.client.from('debts')
                .update({'total_debt': remaining > 0 ? remaining : 0}).eq('id', debtId);
          }
        } catch (_) {}
      }
    }

    // 2) Phiếu chi linh kiện ngoài (transactions expense 'Linh kiện' của đơn).
    try {
      final fetched = await SupabaseService.client
          .from('transactions')
          .select('id, amount, account_id, description')
          .eq('repair_order_id', orderId)
          .eq('type', 'expense')
          .eq('category', 'Linh kiện');
      var rows = (fetched as List).where((r) {
        if (partName.trim().isEmpty) return true;
        return _norm((r['description'] ?? '').toString()).contains(_norm(partName));
      }).toList();
      // Đơn chỉ có đúng 1 phiếu chi linh kiện ngoài mà tên đã đổi -> vẫn đảo
      // được phiếu chi đó cho đúng.
      if (rows.isEmpty && (fetched as List).length == 1) {
        rows = fetched as List;
      }
      if (rows.isNotEmpty) {
        var refund = 0;
        final acctId = rows.first['account_id'] as String?;
        for (final r in rows) {
          refund += (r['amount'] as num?)?.toInt() ?? 0;
        }
        if (acctId != null && refund > 0) {
          try {
            final acct = await SupabaseService.client
                .from('cash_accounts').select('balance').eq('id', acctId).maybeSingle();
            if (acct != null) {
              await SupabaseService.client.from('cash_accounts')
                  .update({'balance': ((acct['balance'] as num?) ?? 0) + refund}).eq('id', acctId);
            }
          } catch (_) {}
        }
        final ids = rows.map((r) => r['id'] as String).toList();
        await SupabaseService.client.from('transactions').update({
          'deleted_at': DateTime.now().toIso8601String(),
          'deleted_by': SupabaseService.currentUser?.id ?? '',
        }).inFilter('id', ids);
      }
    } catch (_) {}

    // 3) Thu hồi thông báo Nợ NCC / Chi linh kiện của đơn.
    await _revokeOrderNotifications(orderId, orderCode, storeId);
  }

  /// Chuẩn hoá chuỗi để so khớp không nhạy cảm hoa/thường và khoảng trắng.
  static String _norm(String s) => s.trim().toLowerCase();

  /// Thu hồi thông báo liên quan đến linh kiện ngoài của đơn (Nợ NCC / Chi linh
  /// kiện). Khớp theo data.order_id (thông báo mới) hoặc body chứa '(đơn <code>)'
  /// (thông báo cũ chưa có order_id trong data).
  Future<void> _revokeOrderNotifications(String orderId, String orderCode, String storeId) async {
    try {
      final res = await SupabaseService.client
          .from('notifications')
          .select('id, body, data')
          .eq('store_id', storeId)
          .limit(1000);
      final ids = <String>[];
      final codeNorm = _norm(orderCode);
      for (final r in res as List) {
        final data = r['data'] as Map<String, dynamic>?;
        final linked = data?['order_id'] == orderId;
        final byBody = _norm((r['body'] ?? '').toString()).contains('(đơn $codeNorm)');
        if (linked || byBody) ids.add(r['id'] as String);
      }
      if (ids.isNotEmpty) {
        await SupabaseService.client.from('notifications').delete().inFilter('id', ids);
      }
    } catch (_) {}
  }

  /// Hủy dialog sửa/tạo đơn: dọn các linh kiện ngoài mới thêm nhưng đơn không
  /// được lưu (linh kiện đã tạo trong kho khi bấm Lưu bảng thêm lk ngoài).
  Future<void> _cancelOrderDialog(
    BuildContext ctx,
    List<Map<String, dynamic>> currentPartsUsed,
    List<Map<String, dynamic>> originalPartsUsed,
  ) async {
    final newExternal = currentPartsUsed
        .where((c) =>
            c['is_external'] == true &&
            !originalPartsUsed.any((o) => o['part_id'] == c['part_id']))
        .toList();
    if (newExternal.isNotEmpty) {
      try {
        final now = DateTime.now().toIso8601String();
        for (final c in newExternal) {
          final partId = c['part_id'] as String;
          await SupabaseService.client
              .from('inventory_transactions').delete().eq('part_id', partId);
          try {
            await SupabaseService.client.from('inventory_parts').delete().eq('id', partId);
          } catch (_) {
            await SupabaseService.client.from('inventory_parts').update({
              'deleted_at': now,
            }).eq('id', partId);
          }
        }
      } catch (_) {}
    }
    if (ctx.mounted) Navigator.pop(ctx);
  }

  /// Trừ kho atomic qua RPC (chỉ trừ khi còn đủ hàng), trả false nếu không đủ.
  Future<bool> _decStock(String partId, int n) async {
    if (n <= 0) return true;
    try {
      final res = await SupabaseService.client.rpc('decrement_stock', params: {
        'p_part_id': partId,
        'p_qty': n,
      });
      return res != null;
    } catch (_) {
      return false;
    }
  }

  // ---------------- Chọn linh kiện từ kho ----------------

  /// Thêm linh kiện ngoài (không có sẵn trong kho) — dùng khi mua linh kiện
  /// riêng để sửa 1 đơn cụ thể. Sau khi nhập, linh kiện tự động được thêm
  /// vào kho (với đúng số lượng đã dùng) rồi gắn luôn vào đơn đang sửa, để
  /// tồn kho vẫn phản ánh đúng — không bị "biến mất" khỏi hệ thống theo dõi.
  Future<void> _showAddExternalPartDialog(
    BuildContext parentCtx,
    String storeId,
    List<Map<String, dynamic>> currentParts,
    void Function(void Function()) setStateDialog,
  ) async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final costCtrl = TextEditingController(text: '0');
    final nccCtrl = TextEditingController();
    Map<String, dynamic>? selectedSupplier;
    String? categoryId;
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: parentCtx,
      title: 'Thêm linh kiện ngoài',
      desktopWidth: 480,
      allowNested: true,
      contentBuilder: (ctx, setStateInner) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dùng cho linh kiện mua ngoài, không có sẵn trong kho. Sau khi lưu, '
            'linh kiện sẽ được thêm vào kho và gắn vào đơn này.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tên linh kiện *')),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: autoReconnectStream(() => SupabaseService.client.from('part_categories').stream(primaryKey: ['id']).order('name'), label: 'part_categories_dlg'),
                builder: (context, snap) {
                  final categories = snap.data ?? [];
                  final validIds = categories.map((c) => c['id'] as String).toSet();
                  final safeValue = (categoryId != null && validIds.contains(categoryId)) ? categoryId : null;
                  return DropdownButtonFormField<String>(
                    key: ValueKey('ext_category_dropdown_${categories.length}_$categoryId'),
                    initialValue: safeValue,
                    decoration: InputDecoration(
                      labelText: 'Danh mục',
                      suffixIcon: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () async {
                          final newId = await _showAddCategoryDialog(ctx, storeId);
                          if (newId != null) setStateInner(() => categoryId = newId);
                        },
                        child: const Icon(Icons.add, size: 18),
                      ),
                      suffixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('-- Chưa phân loại --')),
                      for (final c in categories)
                        DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] ?? '')),
                    ],
                    onChanged: (v) => setStateInner(() => categoryId = v),
                  );
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Số lượng dùng'),
          ),
          const SizedBox(height: 8),
          MoneyInputField(controller: costCtrl, label: 'Giá nhập'),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: nccCtrl,
                decoration: InputDecoration(
                  labelText: 'Nhập từ NCC (tùy chọn)',
                  hintText: 'Tên nhà cung cấp',
                  prefixIcon: const Icon(Icons.business_outlined),
                  suffixIcon: selectedSupplier != null
                      ? IconButton(
                          tooltip: 'Hủy chọn NCC (chọn lại)',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setStateInner(() {
                            selectedSupplier = null;
                            nccCtrl.clear();
                          }),
                        )
                      : null,
                ),
                onChanged: (_) => setStateInner(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Chọn từ danh sách NCC',
                onPressed: () async {
                  final s = await _showSupplierPicker(ctx);
                  if (s != null) {
                    setStateInner(() {
                      selectedSupplier = s;
                      nccCtrl.text = (s['contact_name'] ?? '').toString();
                    });
                  }
                },
                icon: const Icon(Icons.list_alt),
              ),
            ),
          ]),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
      actionsBuilder: (ctx, setStateInner) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => nameCtrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving
              ? null
              : () async {
                  final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                  if (nameCtrl.text.trim().isEmpty || qty <= 0) {
                    setStateInner(() => error = 'Vui lòng nhập tên và số lượng hợp lệ.');
                    return;
                  }
                  setStateInner(() {
                    saving = true;
                    error = null;
                  });
                  try {
                    final uid = SupabaseService.currentUser?.id ?? '';
                    final qtyUsed = qty;
                    final costTotal = (num.tryParse(costCtrl.text.trim()) ?? 0) * qtyUsed;
                    final supplierName = nccCtrl.text.trim();

                    // Hỏi hình thức thanh toán TRƯỚC khi tạo linh kiện trong
                    // kho. Nếu người dùng bấm Hủy thì coi như chưa nhập bảng
                    // thêm linh kiện ngoài (quay lại, không commit gì).
                    String? extPay;
                    if (costTotal > 0 && ctx.mounted) {
                      extPay = await _askExternalPartPayment(
                        ctx: ctx,
                        name: nameCtrl.text.trim(),
                        qty: qtyUsed,
                        costTotal: costTotal,
                        supplierName: supplierName,
                        hasSelectedSupplier: selectedSupplier != null,
                      );
                      if (extPay == null) {
                        setStateInner(() {
                          saving = false;
                          error = null;
                        });
                        return;
                      }
                    }

                    final sku = await _generatePartSku(storeId);
                    // Tồn kho khởi tạo = đúng số lượng sắp dùng, để sau khi trừ
                    // kho theo đơn này thì về lại 0 (không âm), vẫn có lịch sử
                    // nhập/xuất đầy đủ trong hệ thống.
                    final part = await SupabaseService.client
                        .from('inventory_parts')
                        .insert({
                          'store_id': storeId,
                          'name': nameCtrl.text.trim(),
                          'sku': sku,
                          'category_id': categoryId,
                          'quantity': qty,
                          'unit_cost': num.tryParse(costCtrl.text.trim()) ?? 0,
                          'is_external': true,
                        })
                        .select()
                        .single();

                    // Tự nhập kho: tạo phiếu nhập kho 'in' để lịch sử nhập/xuất
                    // phản ánh đúng nguồn gốc linh kiện.
                    await SupabaseService.client.from('inventory_transactions').insert({
                      'store_id': storeId,
                      'part_id': part['id'],
                      'type': 'in',
                      'quantity': qtyUsed,
                      'created_by': uid,
                    });

                    // KHÔNG ghi phiếu chi/nợ ở đây: ghi cùng lúc LƯU ĐƠN (khi đã
                    // có mã đơn) để nếu hủy đơn sau đó thì đảo được khoản này.
                    setStateDialog(() {
                      currentParts.add({
                        'part_id': part['id'],
                        'name': part['name'],
                        'unit_price': part['unit_price'] ?? 0,
                        'quantity': qtyUsed,
                        'is_external': true,
                        'external_pay': extPay,
                        'external_cost': costTotal,
                        'external_supplier_id': selectedSupplier?['id'],
                        'external_supplier_name': supplierName.isEmpty ? null : supplierName,
                      });
                    });

                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    setStateInner(() {
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

  /// Hỏi hình thức thanh toán cho linh kiện ngoài. Trả về 'cash' / 'transfer'
  /// / 'debt'; trả về null nếu người dùng Hủy (quay lại bảng thêm linh kiện).
  Future<String?> _askExternalPartPayment({
    required BuildContext ctx,
    required String name,
    required int qty,
    required num costTotal,
    required String supplierName,
    required bool hasSelectedSupplier,
  }) async {
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Thanh toán linh kiện'),
        content: Text(
          'Nhập kho "$name" x$qty = ${_currency.format(costTotal)}.\n'
          '${supplierName.isNotEmpty ? 'Nhà cung cấp: $supplierName\n' : ''}'
          'Thanh toán bằng?',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, 'cash'), child: const Text('Tiền mặt')),
          TextButton(onPressed: () => Navigator.pop(dctx, 'transfer'), child: const Text('Chuyển khoản')),
          if (hasSelectedSupplier)
            TextButton(onPressed: () => Navigator.pop(dctx, 'debt'), child: const Text('Nợ NCC'))
          else
            TextButton(onPressed: () => Navigator.pop(dctx, 'debt'), child: const Text('Ghi nợ')),
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Hủy')),
        ],
      ),
    );
  }

  Future<String> _generatePartSku(String storeId) async {
    final existing = await SupabaseService.client.from('inventory_parts').select('id').eq('store_id', storeId);
    var seq = (existing as List).length + 1;
    for (var attempt = 0; attempt < 5; attempt++) {
      final sku = 'LK-${seq.toString().padLeft(6, '0')}';
      final exists = await SupabaseService.client
          .from('inventory_parts')
          .select('id')
          .eq('store_id', storeId)
          .eq('sku', sku)
          .maybeSingle();
      if (exists == null) return sku;
      seq++;
    }
    return 'LK-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<String?> _showAddCategoryDialog(BuildContext parentCtx, String storeId) async {
    final nameCtrl = TextEditingController();
    bool submitting = false;
    return showDialog<String>(
      context: parentCtx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text('Thêm danh mục mới'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Tên danh mục'),
          ),
          actions: [
            DialogActionRow(
              onCancel: submitting ? null : () => Navigator.pop(ctx),
              isDirty: () => nameCtrl.text.trim().isNotEmpty,
              primaryButton: ElevatedButton(
                onPressed: submitting
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        setStateDialog(() => submitting = true);
                        try {
                          final existing = await SupabaseService.client
                              .from('part_categories')
                              .select('id')
                              .eq('store_id', storeId)
                              .ilike('name', name)
                              .maybeSingle();
                          if (existing != null) {
                            if (ctx.mounted) Navigator.pop(ctx, existing['id'] as String);
                            return;
                          }
                          final row = await SupabaseService.client
                              .from('part_categories')
                              .insert({'store_id': storeId, 'name': name})
                              .select('id')
                              .single();
                          if (ctx.mounted) Navigator.pop(ctx, row['id'] as String);
                        } catch (e) {
                          setStateDialog(() => submitting = false);
                          if (ctx.mounted) {
                            showToast(ctx, 'Lỗi: ${friendlyError(e)}', error: true);
                          }
                        }
                      },
                child: submitting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
                    : const Text('Thêm'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPartsPicker(
    BuildContext parentCtx,
    List<Map<String, dynamic>> currentParts,
    void Function(void Function()) setStateDialog,
  ) async {
    final searchCtrl = TextEditingController();
    await showModalBottomSheet(
      context: parentCtx,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.92,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setStateSheet) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Tìm linh kiện trong kho',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setStateSheet(() {}),
                  ),
                ),
                Expanded(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: autoReconnectStream(() => SupabaseService.client.from('inventory_parts').stream(primaryKey: ['id']).order('name'), label: 'inventory_parts_dlg'),
                    builder: (context, snap) {
                      final all = (snap.data ?? []).where((p) => p['deleted_at'] == null).toList();
                      final q = searchCtrl.text.trim().toLowerCase();
                      final filtered = q.isEmpty
                          ? all
                          : all.where((p) => (p['name'] ?? '').toString().toLowerCase().contains(q)).toList();
                      if (filtered.isEmpty) {
                        return const Center(child: Text('Không tìm thấy linh kiện.'));
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final p = filtered[i];
                          final idx = currentParts.indexWhere((e) => e['part_id'] == p['id']);
                          final qty = idx >= 0 ? currentParts[idx]['quantity'] as int : 0;
                          return ListTile(
                            leading: GestureDetector(
                              onTap: () async {
                                final ctrl = TextEditingController(text: qty > 0 ? qty.toString() : '1');
                                final result = await showDialog<int>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(p['name'] ?? ''),
                                    content: TextField(
                                      controller: ctrl,
                                      keyboardType: TextInputType.number,
                                      autofocus: true,
                                      decoration: const InputDecoration(labelText: 'Số lượng'),
                                    ),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
                                      ElevatedButton(
                                        onPressed: () {
                                          final v = int.tryParse(ctrl.text.trim());
                                          if (v != null && v > 0) Navigator.pop(ctx, v);
                                        },
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  ),
                                );
                                if (result != null && result > 0) {
                                  setStateSheet(() => setStateDialog(() {
                                    if (idx >= 0) {
                                      currentParts[idx]['quantity'] = result;
                                    } else {
                                      currentParts.add({
                                        'part_id': p['id'],
                                        'name': p['name'],
                                        'unit_price': p['unit_price'] ?? 0,
                                        'quantity': result,
                                      });
                                    }
                                  }));
                                }
                              },
                              child: CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.blueGrey,
                                child: Text(
                                  (p['name'] as String?)?.isNotEmpty == true
                                      ? (p['name'] as String).substring(0, 1).toUpperCase()
                                      : '#',
                                  style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            title: Text(p['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('Tồn kho: ${p['quantity']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: qty > 0
                                      ? () => setStateSheet(() => setStateDialog(() {
                                            if (qty <= 1) {
                                              currentParts.removeAt(idx);
                                            } else {
                                              currentParts[idx]['quantity'] = qty - 1;
                                            }
                                          }))
                                      : null,
                                ),
                                Text('$qty', style: const TextStyle(fontWeight: FontWeight.w600)),
                                IconButton(
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => setStateSheet(() => setStateDialog(() {
                                        if (idx >= 0) {
                                          currentParts[idx]['quantity'] = qty + 1;
                                        } else {
                                          currentParts.add({
                                            'part_id': p['id'],
                                            'name': p['name'],
                                            'unit_price': p['unit_price'] ?? 0,
                                            'quantity': 1,
                                          });
                                        }
                                      })),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Xong')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- Tạo / sửa đơn ----------------

  Future<void> _showReceiveOrEditDialog({RepairOrder? editing}) async {
    final isEditing = editing != null;
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final modelCtrl = TextEditingController(text: editing?.deviceModel ?? '');
    final imeiCtrl = TextEditingController(text: editing?.imei ?? '');
    final issueCtrl = TextEditingController(text: editing?.issueDescription ?? '');
    final priceCtrl = TextEditingController(
      text: editing != null
          ? (editing.finalCost != 0 ? editing.finalCost : editing.estimatedCost).toStringAsFixed(0)
          : '',
    );
    final warrantyCtrl = TextEditingController(
      text: editing != null ? editing.warrantyDays.toString() : '90',
    );
    final noteCtrl = TextEditingController(text: editing?.note ?? '');
    final modelFocusNode = FocusNode();
    final nameFocusNode = FocusNode();
    final phoneFocusNode = FocusNode();
    String? pickedCustomerId = editing?.customerId;
    // Tạo đơn mới -> mặc định giao cho chính người đang tạo (đỡ phải chọn lại).
    // Sửa đơn có sẵn -> giữ nguyên người đang được giao.
    String? assignedToId = isEditing ? editing.technicianId : SupabaseService.currentUser?.id;
    String status = editing?.status ?? 'received';
    // Tạo đơn mới chưa trả máy nên chưa chọn hình thức thanh toán; khi trả máy
    // mới bắt buộc chọn. Sửa đơn -> giữ nguyên hình thức đã lưu.
    String? paymentMethod = editing?.paymentMethod;
    // Ngày thanh toán (cho phép sửa khi đơn đã trả máy, phòng khi quên nhập).
    DateTime? paidAt = editing?.paidAt;
    final initialPaidAt = paidAt;
    final originalAssignedToId = assignedToId;
    bool saving = false;
    String? error;
    // Các ô đang mở chế độ sửa trong bảng sửa đơn (đơn chưa trả máy): ô đã có
    // dữ liệu hiển thị dạng list + nút "Sửa" cuối dòng, bấm vào mới mở nhập.
    final editingFields = <String>{};
    String originalName = '';
    String originalPhone = '';
    Uint8List? frontBytes;
    Uint8List? backBytes;
    String? frontExistingUrl;
    String? backExistingUrl;

    final storeId = await _currentStoreId();

    // Toàn bộ nhân viên trong cửa hàng (admin/lễ tân/KTV) để chọn "phân công cho".
    var staffList = <Map<String, dynamic>>[];
    try {
      final rows = await SupabaseService.client
          .from('profiles')
          .select('id, full_name, role')
          .eq('store_id', storeId);
      staffList = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
    String? roleOf(String? staffId) =>
        staffList.firstWhere((s) => s['id'] == staffId, orElse: () => const {})['role'] as String?;

    // Chỉ khi TẠO mới: nếu trạng thái mặc định không hợp lệ với vai trò của
    // người được gán mặc định (VD: mặc định giao cho KTV nhưng trạng thái
    // "Mới tiếp nhận" chỉ dành cho lễ tân/admin), tự chuyển sang trạng thái hợp
    // lệ đầu tiên. Khi SỬA đơn phải giữ nguyên đúng thông tin đang có, không tự
    // đổi bất kỳ thứ gì.
    if (!isEditing) {
      final allowedForDefault = statusOptionsForRole(roleOf(assignedToId));
      if (!allowedForDefault.contains(status)) status = allowedForDefault.first;
    }

    if (isEditing && editing.customerId != null) {
      try {
        final c = await SupabaseService.client
            .from('customers')
            .select('name, phone')
            .eq('id', editing.customerId!)
            .maybeSingle();
        nameCtrl.text = c?['name'] ?? '';
        phoneCtrl.text = c?['phone'] ?? '';
        originalName = nameCtrl.text;
        originalPhone = phoneCtrl.text;
      } catch (_) {}
    }

    if (isEditing) {
      if (editing.photoFrontPath != null) frontExistingUrl = await getRepairPhotoUrl(editing.photoFrontPath!);
      if (editing.photoBackPath != null) backExistingUrl = await getRepairPhotoUrl(editing.photoBackPath!);
    }

    // Gợi ý Model: gộp danh sách model đã từng nhập ở cửa hàng này + danh sách phổ biến.
    var modelSuggestions = _commonDeviceModels.toList();
    try {
      final rows = await SupabaseService.client
          .from('repair_orders')
          .select('device_model')
          .eq('store_id', storeId);
      final existingModels = (rows as List)
          .map((r) => r['device_model'] as String?)
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toSet();
      modelSuggestions = {...existingModels, ..._commonDeviceModels}.toList();
    } catch (_) {}

    // Gợi ý khách hàng có sẵn trong danh bạ (dùng chung cho cả ô Tên và SĐT).
    // Nhãn dạng "Tên (SĐT)" để phân biệt các khách trùng tên.
    final customerByLabel = <String, Map<String, dynamic>>{};
    try {
      final rows = await SupabaseService.client
          .from('customers')
          .select('id, name, phone, customer_type, deleted_at')
          .eq('store_id', storeId);
      for (final c in (rows as List).where((c) => c['deleted_at'] == null)) {
        final phone = (c['phone'] ?? '').toString();
        final label = phone.isNotEmpty ? '${c['name']} ($phone)' : c['name'] as String;
        customerByLabel[label] = c as Map<String, dynamic>;
      }
    } catch (_) {}
    void applyPickedCustomerLabel(String label) {
      final c = customerByLabel[label];
      if (c == null) return;
      nameCtrl.text = c['name'] ?? '';
      phoneCtrl.text = c['phone'] ?? '';
      pickedCustomerId = c['id'] as String?;
    }

    // Linh kiện đã dùng (nếu đang sửa đơn đã có sẵn) — tải lịch sử xuất kho gắn với đơn này.
    final originalPartsUsed = <Map<String, dynamic>>[];
    if (isEditing) {
      try {
        final rows = await SupabaseService.client
            .from('inventory_transactions')
            .select('id, part_id, quantity, inventory_parts(name, unit_price, is_external)')
            .eq('repair_order_id', editing.id)
            .eq('type', 'out');
        for (final r in rows as List) {
          final partInfo = r['inventory_parts'] as Map<String, dynamic>?;
          originalPartsUsed.add({
            'tx_id': r['id'],
            'part_id': r['part_id'],
            'name': partInfo?['name'] ?? '',
            'unit_price': partInfo?['unit_price'] ?? 0,
            'quantity': r['quantity'],
            'is_external': partInfo?['is_external'] == true,
          });
        }
      } catch (_) {}
    }
    final currentPartsUsed = originalPartsUsed.map((e) => Map<String, dynamic>.from(e)).toList();

    // Snapshot dữ liệu từng ô khi mở chế độ sửa để nút Hủy (X) trả lại dữ liệu cũ.
    final fieldSnapshots = <String, dynamic>{};
    dynamic captureField(String key) {
      switch (key) {
        case 'customer_name':
          return nameCtrl.text;
        case 'customer_phone':
          return phoneCtrl.text;
        case 'device_model':
          return modelCtrl.text;
        case 'imei':
          return imeiCtrl.text;
        case 'issue':
          return issueCtrl.text;
        case 'parts':
          return currentPartsUsed.map((e) => Map<String, dynamic>.from(e)).toList();
        case 'photos':
          return {
            'frontBytes': frontBytes,
            'backBytes': backBytes,
            'frontExistingUrl': frontExistingUrl,
            'backExistingUrl': backExistingUrl,
          };
        case 'assignee':
          return assignedToId;
        case 'price':
          return priceCtrl.text;
        case 'warranty':
          return warrantyCtrl.text;
        case 'payment':
          return paymentMethod;
        case 'paid_at':
          return paidAt;
        case 'note':
          return noteCtrl.text;
      }
      return null;
    }

    void restoreField(String key) {
      final snap = fieldSnapshots[key];
      switch (key) {
        case 'customer_name':
          nameCtrl.text = snap as String? ?? '';
          break;
        case 'customer_phone':
          phoneCtrl.text = snap as String? ?? '';
          break;
        case 'device_model':
          modelCtrl.text = snap as String? ?? '';
          break;
        case 'imei':
          imeiCtrl.text = snap as String? ?? '';
          break;
        case 'issue':
          issueCtrl.text = snap as String? ?? '';
          break;
        case 'parts':
          currentPartsUsed
            ..clear()
            ..addAll((snap as List?)?.cast<Map<String, dynamic>>() ?? const []);
          break;
        case 'photos':
          final m = snap as Map<String, dynamic>?;
          frontBytes = m?['frontBytes'] as Uint8List?;
          backBytes = m?['backBytes'] as Uint8List?;
          frontExistingUrl = m?['frontExistingUrl'] as String?;
          backExistingUrl = m?['backExistingUrl'] as String?;
          break;
        case 'assignee':
          assignedToId = snap as String?;
          break;
        case 'price':
          priceCtrl.text = snap as String? ?? '';
          break;
        case 'warranty':
          warrantyCtrl.text = snap as String? ?? '';
          break;
        case 'payment':
          paymentMethod = snap as String?;
          break;
        case 'paid_at':
          paidAt = snap as DateTime?;
          break;
        case 'note':
          noteCtrl.text = snap as String? ?? '';
          break;
      }
    }

    // Các ô đang trống trong bảng sửa đơn hiện thẳng ô nhập ngay khi mở (không
    // chuyển sang chế độ xem dù sau đó có nhập liệu).
    if (isEditing) {
      void markEmpty(String key, bool isEmpty) {
        if (isEmpty) editingFields.add(key);
      }

      markEmpty('customer_name', nameCtrl.text.trim().isEmpty);
      markEmpty('customer_phone', phoneCtrl.text.trim().isEmpty);
      markEmpty('device_model', modelCtrl.text.trim().isEmpty);
      markEmpty('imei', imeiCtrl.text.trim().isEmpty);
      markEmpty('issue', issueCtrl.text.trim().isEmpty);
      markEmpty('parts', currentPartsUsed.isEmpty);
      markEmpty('photos', frontExistingUrl == null && backExistingUrl == null);
      markEmpty('assignee', assignedToId == null);
      markEmpty('price', priceCtrl.text.trim().isEmpty);
      markEmpty('payment', paymentMethod == null);
      markEmpty('note', noteCtrl.text.trim().isEmpty);
    }

    // Kiểm tra đang có dữ liệu thay đổi so với ban đầu — dùng chung cho nút Hủy
    // và phím ESC (mở hộp xác nhận trước khi thoát, tránh mất dữ liệu nhập dở).
    bool orderFormDirty() {
      final partsChanged = currentPartsUsed.length != originalPartsUsed.length ||
          currentPartsUsed.any((c) => !originalPartsUsed.any(
              (o) => o['part_id'] == c['part_id'] && o['quantity'] == c['quantity']));
      if (frontBytes != null || backBytes != null || partsChanged) return true;
      if (isEditing) {
        return nameCtrl.text.trim() != originalName.trim() ||
            phoneCtrl.text.trim() != originalPhone.trim() ||
            modelCtrl.text.trim() != (editing.deviceModel ?? '') ||
            imeiCtrl.text.trim() != (editing.imei ?? '') ||
            issueCtrl.text.trim() != (editing.issueDescription ?? '') ||
            noteCtrl.text.trim() != (editing.note ?? '') ||
            assignedToId != editing.technicianId ||
            status != editing.status ||
            paidAt != initialPaidAt ||
            warrantyCtrl.text.trim() != editing.warrantyDays.toString() ||
            priceCtrl.text.trim() !=
                (editing.estimatedCost == 0 ? '' : editing.estimatedCost.toStringAsFixed(0));
      }
      return nameCtrl.text.trim().isNotEmpty ||
          phoneCtrl.text.trim().isNotEmpty ||
          modelCtrl.text.trim().isNotEmpty ||
          imeiCtrl.text.trim().isNotEmpty ||
          issueCtrl.text.trim().isNotEmpty ||
          noteCtrl.text.trim().isNotEmpty ||
          assignedToId != null ||
          status != 'received' ||
          warrantyCtrl.text.trim().isNotEmpty ||
          priceCtrl.text.trim().isNotEmpty;
    }

    if (!mounted) return;
    try {
      await showAdaptiveFormDialog(
        context: context,
        title: isEditing ? 'Sửa đơn ${editing.code}' : 'Tiếp nhận đơn sửa chữa',
        titleTrailing: 'Ngày tạo: ${_dateFmt.format(editing?.receivedAt ?? DateTime.now())}',
        desktopWidth: 560,
        barrierDismissible: false,
        // Phím ESC = hủy đơn giống nút Hủy (có xác nhận nếu đang nhập dở).
        onEscCancel: (dlgCtx) async {
          if (saving) return;
          await _cancelOrderDialog(dlgCtx, currentPartsUsed, originalPartsUsed);
        },
        escIsDirty: orderFormDirty,
        contentBuilder: (ctx, setStateDialog) {
          // Trong chế độ SỬA đơn:
          // - Đơn đã trả máy (delivered): KHÓA CỨNG toàn bộ, chỉ đổi trạng thái.
          // Cách hiển thị từng ô dữ liệu:
          // - Tạo đơn mới: luôn hiện ô nhập.
          // - Đơn đã trả máy: các ô khóa cứng, chỉ hiển thị (trừ ngày thanh toán).
          // - Đơn chưa trả máy: ô đã có dữ liệu hiển thị dạng list + nút Sửa cuối
          //   dòng; bấm Sửa mới hiện ô nhập kèm nút Xong. Ô trống hiện thẳng ô nhập.
          final bool dlgAndroid = Platform.isAndroid;
          Widget viewOrEdit({
            required String key,
            required String label,
            required bool hasValue,
            required Widget viewChild,
            required Widget editChild,
            bool alwaysEditable = false,
            bool forceEdit = false,
          }) {
            if (!isEditing) return editChild;
            if (forceEdit) return editChild;
            final isDelivered = status == 'delivered';
            if (isDelivered && !alwaysEditable) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (key != 'photos') ...[
                      Text('$label:', style: const TextStyle(fontSize: 14, color: Colors.black54)),
                      const SizedBox(width: 8),
                    ],
                    Expanded(child: viewChild),
                  ],
                ),
              );
            }
            final editing = editingFields.contains(key);
            if (editing) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  editChild,
                  if (hasValue)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Color(0xFFEF4444)),
                            tooltip: 'Hủy',
                            onPressed: () => setStateDialog(() {
                              restoreField(key);
                              fieldSnapshots.remove(key);
                              editingFields.remove(key);
                            }),
                          ),
                          IconButton(
                            icon: const Icon(Icons.check, size: 18, color: Color(0xFF3B82F6)),
                            tooltip: 'Lưu',
                            onPressed: () => setStateDialog(() {
                              fieldSnapshots.remove(key);
                              editingFields.remove(key);
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            }
            if (hasValue) {
              return Container(
                margin: const EdgeInsets.only(top: 5, bottom: 6),
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 9),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$label:', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black87)),
                    const SizedBox(width: 8),
                    Expanded(child: viewChild),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 22),
                      tooltip: 'Sửa',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => setStateDialog(() {
                        fieldSnapshots[key] = captureField(key);
                        editingFields.add(key);
                      }),
                    ),
                  ],
                ),
              );
            }
            return editChild;
          }
          Widget nameField() => viewOrEdit(
                key: 'customer_name',
                label: 'Họ tên khách',
                hasValue: nameCtrl.text.trim().isNotEmpty,
                viewChild: Text(nameCtrl.text.trim(), style: const TextStyle(fontSize: 14)),
                editChild: Autocomplete<String>(
                  textEditingController: nameCtrl,
                  focusNode: nameFocusNode,
                  optionsBuilder: (v) {
                    if (v.text.trim().isEmpty) return const Iterable<String>.empty();
                    return customerByLabel.keys.where((l) => l.toLowerCase().contains(v.text.toLowerCase()));
                  },
                  onSelected: (label) => setStateDialog(() => applyPickedCustomerLabel(label)),
                  displayStringForOption: (label) => customerByLabel[label]?['name'] as String? ?? label,
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 250),
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: options.length,
                            shrinkWrap: true,
                            itemBuilder: (ctx, i) {
                              final label = options.elementAt(i);
                              final c = customerByLabel[label];
                              final isWholesale = c?['customer_type'] == 'wholesale';
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: isWholesale ? const Color(0xFF1B3A6B) : null,
                                  child: Icon(
                                    isWholesale ? Icons.groups : Icons.person,
                                    color: isWholesale ? Colors.white : null,
                                    size: 14,
                                  ),
                                ),
                                title: Text(c?['name'] ?? label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                subtitle: Text(c?['phone'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                onTap: () => onSelected(label),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                  fieldViewBuilder: (context, ctrl, focusNode, onSubmit) {
                    return TextField(
                      controller: ctrl,
                      focusNode: focusNode,
                      onChanged: (_) => pickedCustomerId = null,
                      decoration: InputDecoration(
                        labelText: 'Họ tên khách *',
                        suffixIcon: IconButton(
                          tooltip: 'Chọn khách hàng từ danh bạ',
                          icon: const Icon(Icons.people_alt_outlined),
                          onPressed: () async {
                            final picked = await _showCustomerPicker(ctx);
                            if (picked != null) {
                              setStateDialog(() {
                                nameCtrl.text = picked['name'] ?? '';
                                phoneCtrl.text = picked['phone'] ?? '';
                                pickedCustomerId = picked['id'] as String?;
                              });
                            }
                          },
                        ),
                      ),
                    );
                  },
                ),
              );
          Widget phoneField() => viewOrEdit(
                key: 'customer_phone',
                label: 'Số điện thoại',
                hasValue: phoneCtrl.text.trim().isNotEmpty,
                viewChild: Text(phoneCtrl.text.trim(), style: const TextStyle(fontSize: 14)),
                editChild: Autocomplete<String>(
                  textEditingController: phoneCtrl,
                  focusNode: phoneFocusNode,
                  optionsBuilder: (v) {
                    if (v.text.trim().isEmpty) return const Iterable<String>.empty();
                    return customerByLabel.keys.where((l) => l.toLowerCase().contains(v.text.toLowerCase()));
                  },
                  onSelected: (label) => setStateDialog(() => applyPickedCustomerLabel(label)),
                  displayStringForOption: (label) => (customerByLabel[label]?['phone'] as String?) ?? label,
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 250),
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: options.length,
                            shrinkWrap: true,
                            itemBuilder: (ctx, i) {
                              final label = options.elementAt(i);
                              final c = customerByLabel[label];
                              final isWholesale = c?['customer_type'] == 'wholesale';
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: isWholesale ? const Color(0xFF1B3A6B) : null,
                                  child: Icon(
                                    isWholesale ? Icons.groups : Icons.person,
                                    color: isWholesale ? Colors.white : null,
                                    size: 14,
                                  ),
                                ),
                                title: Text(c?['phone'] ?? label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                subtitle: Text(c?['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                onTap: () => onSelected(label),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                  fieldViewBuilder: (context, ctrl, focusNode, onSubmit) {
                    return TextField(
                      controller: ctrl,
                      focusNode: focusNode,
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => pickedCustomerId = null,
                      decoration: const InputDecoration(
                        labelText: 'Số điện thoại',
                        helperText: 'Trùng SĐT khách đã có sẽ dùng lại, không tạo khách mới',
                      ),
                    );
                  },
                ),
              );
          Widget deviceModelField() => viewOrEdit(
                key: 'device_model',
                label: 'Model máy',
                hasValue: modelCtrl.text.trim().isNotEmpty,
                viewChild: Text(modelCtrl.text.trim(), style: const TextStyle(fontSize: 14)),
                editChild: Autocomplete<String>(
                  textEditingController: modelCtrl,
                  focusNode: modelFocusNode,
                  optionsBuilder: (v) {
                    if (v.text.isEmpty) return modelSuggestions;
                    return modelSuggestions.where((m) => m.toLowerCase().contains(v.text.toLowerCase()));
                  },
                  onSelected: (v) => modelCtrl.text = v,
                  fieldViewBuilder: (context, ctrl, focusNode, onSubmit) {
                    return TextField(
                      controller: ctrl,
                      focusNode: focusNode,
                      decoration: const InputDecoration(labelText: 'Model máy'),
                    );
                  },
                ),
              );
          Widget imeiField() => viewOrEdit(
                key: 'imei',
                label: 'IMEI / Serial',
                hasValue: imeiCtrl.text.trim().isNotEmpty,
                viewChild: Text(imeiCtrl.text.trim(), style: const TextStyle(fontSize: 14)),
                editChild: TextField(
                  controller: imeiCtrl,
                  decoration: const InputDecoration(labelText: 'IMEI / Serial'),
                ),
              );
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(dlgAndroid ? 0.88 : 1.0),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                const Text('Khách hàng', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                    if (dlgAndroid) ...[
                      nameField(),
                      const SizedBox(height: 8),
                      phoneField(),
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: nameField()),
                          const SizedBox(width: 8),
                          Expanded(child: phoneField()),
                        ],
                      ),
                    ],
                    const Divider(height: 24),
                    const Text('Thiết bị', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: deviceModelField()),
                        const SizedBox(width: 8),
                        Expanded(child: imeiField()),
                      ],
                    ),
                    const SizedBox(height: 8),
                    viewOrEdit(
                      key: 'issue',
                      label: 'Mô tả lỗi / yêu cầu:',
                      hasValue: issueCtrl.text.trim().isNotEmpty,
                      viewChild: Text(issueCtrl.text.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                      editChild: TextField(
                        controller: issueCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(labelText: 'Mô tả lỗi / yêu cầu:'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: viewOrEdit(
                      key: 'parts',
                      label: 'Linh kiện đã dùng',
                      hasValue: currentPartsUsed.isNotEmpty,
                      viewChild: currentPartsUsed.isEmpty
                          ? const Text('Chưa có', style: TextStyle(fontSize: 14))
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final part in currentPartsUsed)
                                  Chip(
                                    label: Text('${part['name']} x${part['quantity']}', style: const TextStyle(fontSize: 11)),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                      editChild: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Linh kiện', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _showPartsPicker(ctx, currentPartsUsed, setStateDialog),
                                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                                label: const Text('Chọn từ kho'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _showAddExternalPartDialog(ctx, storeId, currentPartsUsed, setStateDialog),
                                icon: const Icon(Icons.add_box_outlined, size: 16),
                                label: const Text('Thêm L.Kiện'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                              ),
                            ],
                          ),
                          if (currentPartsUsed.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final part in currentPartsUsed)
                                  Chip(
                                    label: Text('${part['name']} x${part['quantity']}', style: const TextStyle(fontSize: 11)),
                                    visualDensity: VisualDensity.compact,
                                    onDeleted: () => setStateDialog(() => currentPartsUsed.remove(part)),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: viewOrEdit(
                      key: 'photos',
                      label: 'Ảnh thiết bị',
                      hasValue: frontExistingUrl != null || backExistingUrl != null || frontBytes != null || backBytes != null,
                      viewChild: dlgAndroid
                          ? Row(
                              children: [
                                SizedBox(
                                  width: 62,
                                  child: _PhotoSlot(
                                    label: 'Trước',
                                    bytes: frontBytes,
                                    existingUrl: frontExistingUrl,
                                    height: 62,
                                    onTap: () {},
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 62,
                                  child: _PhotoSlot(
                                    label: 'Sau',
                                    bytes: backBytes,
                                    existingUrl: backExistingUrl,
                                    height: 62,
                                    onTap: () {},
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: _PhotoSlot(
                                    label: 'Trước',
                                    bytes: frontBytes,
                                    existingUrl: frontExistingUrl,
                                    height: 72,
                                    onTap: () {},
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: _PhotoSlot(
                                    label: 'Sau',
                                    bytes: backBytes,
                                    existingUrl: backExistingUrl,
                                    height: 72,
                                    onTap: () {},
                                  ),
                                ),
                              ],
                            ),
                      editChild: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Ảnh thiết bị', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              SizedBox(
                                width: dlgAndroid ? 62 : 128,
                                child: _PhotoSlot(
                                  label: 'Trước',
                                  bytes: frontBytes,
                                  existingUrl: frontExistingUrl,
                                  height: dlgAndroid ? 62 : 72,
                                  onTap: () async {
                                    try {
                                      final bytes = await captureAndResizePhoto();
                                      if (bytes != null) setStateDialog(() => frontBytes = bytes);
                                    } on PhotoPermissionException catch (e) {
                                      showToast(ctx, e.message, error: true);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: dlgAndroid ? 62 : 128,
                                child: _PhotoSlot(
                                  label: 'Sau',
                                  bytes: backBytes,
                                  existingUrl: backExistingUrl,
                                  height: dlgAndroid ? 62 : 72,
                                  onTap: () async {
                                    try {
                                      final bytes = await captureAndResizePhoto();
                                      if (bytes != null) setStateDialog(() => backBytes = bytes);
                                    } on PhotoPermissionException catch (e) {
                                      showToast(ctx, e.message, error: true);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (dlgAndroid) ...[
                      viewOrEdit(
                        key: 'assignee',
                        label: 'Giao cho',
                        hasValue: assignedToId != null,
                        viewChild: Text(
                          staffList.firstWhere((s) => s['id'] == assignedToId, orElse: () => const {'full_name': '—'})['full_name'] ?? '—',
                          style: const TextStyle(fontSize: 14),
                        ),
                        editChild: Builder(builder: (context) {
                          final validIds = staffList.map((s) => s['id'] as String).toSet();
                          final safeAssignee = (assignedToId != null && validIds.contains(assignedToId)) ? assignedToId : null;
                          return DropdownButtonFormField<String>(
                            key: ValueKey('assignee_${staffList.length}_$assignedToId'),
                            initialValue: safeAssignee,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Giao cho',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                            ),
                            items: [
                              DropdownMenuItem(value: null, child: Text('-- Chưa giao --', overflow: TextOverflow.ellipsis)),
                              for (final s in staffList)
                                DropdownMenuItem(value: s['id'] as String, child: Text(s['full_name'] ?? '', overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setStateDialog(() {
                              assignedToId = v;
                              // Chỉ tự đồng bộ trạng thái khi TẠO mới; sửa đơn
                              // giữ nguyên trạng thái đang có của đơn.
                              if (!isEditing) {
                                final allowed = statusOptionsForRole(roleOf(v));
                                if (!allowed.contains(status)) status = allowed.first;
                              }
                            }),
                          );
                        }),
                      ),
                      const SizedBox(height: 8),
                      Builder(builder: (context) {
                        // Trạng thái luôn cho sửa (kể cả đơn đã trả máy) —
                        // để đổi ngược trạng thái hoặc chọn nhầm đơn.
                        final allowed = isEditing
                            ? repairStatusOptions
                            : statusOptionsForRole(roleOf(assignedToId));
                        final safeStatus = allowed.contains(status) ? status : allowed.first;
                        return DropdownButtonFormField<String>(
                          key: ValueKey('order_status_${assignedToId}_$safeStatus'),
                          initialValue: safeStatus,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Trạng thái',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          ),
                          items: [
                            for (final s in allowed)
                              DropdownMenuItem(value: s, child: Text(StatusColors.label[s] ?? s, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setStateDialog(() => status = v ?? status),
                        );
                      }),
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: viewOrEdit(
                              key: 'assignee',
                              label: 'Giao cho',
                              hasValue: assignedToId != null,
                              viewChild: Text(
                                staffList.firstWhere((s) => s['id'] == assignedToId, orElse: () => const {'full_name': '—'})['full_name'] ?? '—',
                                style: const TextStyle(fontSize: 14),
                              ),
                              editChild: Builder(builder: (context) {
                                final validIds = staffList.map((s) => s['id'] as String).toSet();
                                final safeAssignee = (assignedToId != null && validIds.contains(assignedToId)) ? assignedToId : null;
                                return DropdownButtonFormField<String>(
                                  key: ValueKey('assignee_${staffList.length}_$assignedToId'),
                                  initialValue: safeAssignee,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Giao cho',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                  ),
                                  items: [
                                    DropdownMenuItem(value: null, child: Text('-- Chưa giao --', overflow: TextOverflow.ellipsis)),
                                    for (final s in staffList)
                                      DropdownMenuItem(value: s['id'] as String, child: Text(s['full_name'] ?? '', overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: (v) => setStateDialog(() {
                                    assignedToId = v;
                                    // Chỉ tự đồng bộ trạng thái khi TẠO mới; sửa đơn
                                    // giữ nguyên trạng thái đang có của đơn.
                                    if (!isEditing) {
                                      final allowed = statusOptionsForRole(roleOf(v));
                                      if (!allowed.contains(status)) status = allowed.first;
                                    }
                                  }),
                                );
                              }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: Builder(builder: (context) {
                              // Trạng thái luôn cho sửa (kể cả đơn đã trả máy) —
                              // để đổi ngược trạng thái hoặc chọn nhầm đơn.
                              final allowed = isEditing
                                  ? repairStatusOptions
                                  : statusOptionsForRole(roleOf(assignedToId));
                              final safeStatus = allowed.contains(status) ? status : allowed.first;
                              return DropdownButtonFormField<String>(
                                key: ValueKey('order_status_${assignedToId}_$safeStatus'),
                                initialValue: safeStatus,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Trạng thái',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                ),
                                items: [
                                  for (final s in allowed)
                                    DropdownMenuItem(value: s, child: Text(StatusColors.label[s] ?? s, overflow: TextOverflow.ellipsis)),
                                ],
                                onChanged: (v) => setStateDialog(() => status = v ?? status),
                              );
                            }),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (dlgAndroid) ...[
                      viewOrEdit(
                        key: 'price',
                        label: 'Giá tiền',
                        hasValue: priceCtrl.text.trim().isNotEmpty,
                        viewChild: Text(_currency.format(num.tryParse(priceCtrl.text.trim()) ?? 0), style: const TextStyle(fontSize: 14)),
                        editChild: MoneyInputField(controller: priceCtrl, label: 'Giá tiền'),
                      ),
                      const SizedBox(height: 8),
                      viewOrEdit(
                        key: 'payment',
                        label: 'Hình thức thanh toán',
                        hasValue: paymentMethod != null,
                        forceEdit: true,
                        viewChild: Text(
                          paymentMethod == 'debt'
                              ? 'Ghi nợ'
                              : paymentMethod == 'cash'
                                  ? 'Tiền mặt'
                                  : paymentMethod == 'transfer'
                                      ? 'Chuyển khoản'
                                      : '—',
                          style: const TextStyle(fontSize: 14),
                        ),
                        editChild: DropdownButtonFormField<String>(
                          key: ValueKey('payment_${paymentMethod ?? 'none'}'),
                          initialValue: paymentMethod,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Hình thức thanh toán',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          ),
                          items: [
                            if (paymentMethod == null)
                              const DropdownMenuItem<String>(value: null, child: Text('-- Chọn --')),
                            const DropdownMenuItem(value: 'debt', child: Text('Ghi nợ')),
                            const DropdownMenuItem(value: 'cash', child: Text('T.Mặt')),
                            const DropdownMenuItem(value: 'transfer', child: Text('C.Khoản')),
                          ],
                          onChanged: (v) => setStateDialog(() => paymentMethod = v),
                        ),
                      ),
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: viewOrEdit(
                              key: 'price',
                              label: 'Giá tiền',
                              hasValue: priceCtrl.text.trim().isNotEmpty,
                              viewChild: Text(_currency.format(num.tryParse(priceCtrl.text.trim()) ?? 0), style: const TextStyle(fontSize: 14)),
                              editChild: MoneyInputField(controller: priceCtrl, label: 'Giá tiền'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: viewOrEdit(
                              key: 'payment',
                              label: 'Hình thức thanh toán',
                              hasValue: paymentMethod != null,
                              forceEdit: true,
                              viewChild: Text(
                                paymentMethod == 'debt'
                                    ? 'Ghi nợ'
                                    : paymentMethod == 'cash'
                                        ? 'Tiền mặt'
                                        : paymentMethod == 'transfer'
                                            ? 'Chuyển khoản'
                                            : '—',
                                style: const TextStyle(fontSize: 14),
                              ),
                              editChild: DropdownButtonFormField<String>(
                                key: ValueKey('payment_${paymentMethod ?? 'none'}'),
                                initialValue: paymentMethod,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Hình thức thanh toán',
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                ),
                                items: [
                                  if (paymentMethod == null)
                                    const DropdownMenuItem<String>(value: null, child: Text('-- Chọn --')),
                                  const DropdownMenuItem(value: 'debt', child: Text('Ghi nợ')),
                                  const DropdownMenuItem(value: 'cash', child: Text('T.Mặt')),
                                  const DropdownMenuItem(value: 'transfer', child: Text('C.Khoản')),
                                ],
                                onChanged: (v) => setStateDialog(() => paymentMethod = v),
                              ),
                            ),
                          ),
                          if (status == 'delivered' && !dlgAndroid) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 3,
                              child: viewOrEdit(
                                key: 'paid_at',
                                label: 'Ngày thanh toán',
                                hasValue: paidAt != null,
                                alwaysEditable: true,
                                viewChild: Text(paidAt == null ? '—' : _dateFmt.format(paidAt!), style: const TextStyle(fontSize: 14)),
                                editChild: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      final picked = await showDatePicker(
                                        context: ctx,
                                        initialDate: paidAt ?? DateTime.now(),
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime(2100),
                                        locale: const Locale('vi'),
                                      );
                                      if (picked != null) setStateDialog(() => paidAt = picked);
                                    },
                                    icon: const Icon(Icons.calendar_today, size: 14),
                                    label: Text(paidAt == null ? 'Chọn ngày T.Toán' : 'Ngày thanh toán: ${_dateFmt.format(paidAt!)}'),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                    if (status == 'delivered' && dlgAndroid) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Flexible(
                            child: viewOrEdit(
                              key: 'paid_at',
                              label: 'Ngày thanh toán',
                              hasValue: paidAt != null,
                              alwaysEditable: true,
                              viewChild: Text(paidAt == null ? '—' : _dateFmt.format(paidAt!), style: const TextStyle(fontSize: 16)),
                              editChild: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final picked = await showDatePicker(
                                      context: ctx,
                                      initialDate: paidAt ?? DateTime.now(),
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime(2100),
                                      locale: const Locale('vi'),
                                    );
                                    if (picked != null) setStateDialog(() => paidAt = picked);
                                  },
                                  icon: const Icon(Icons.calendar_today, size: 14),
                                  label: Text(paidAt == null ? 'Chọn ngày T.Toán' : 'Ngày thanh toán: ${_dateFmt.format(paidAt!)}'),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 170,
                          child: viewOrEdit(
                            key: 'warranty',
                            label: 'Bảo hành (ngày)',
                            hasValue: warrantyCtrl.text.trim().isNotEmpty && warrantyCtrl.text.trim() != '0',
                            viewChild: Text(warrantyCtrl.text.trim(), style: const TextStyle(fontSize: 14)),
                            editChild: TextField(
                              controller: warrantyCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Bảo hành (ngày)',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: viewOrEdit(
                            key: 'note',
                            label: 'Ghi chú',
                            hasValue: noteCtrl.text.trim().isNotEmpty,
                            viewChild: Text(noteCtrl.text.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                            editChild: TextField(
                              controller: noteCtrl,
                              maxLines: 1,
                              decoration: const InputDecoration(labelText: 'Ghi chú'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!, style: const TextStyle(color: Colors.red)),
                    ],
                  ],
                ),
              );
        },
        actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
                onCancel: saving ? null : () => _cancelOrderDialog(ctx, currentPartsUsed, originalPartsUsed),
                isDirty: orderFormDirty,
                primaryButton: ElevatedButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (nameCtrl.text.trim().isEmpty) {
                            setStateDialog(() => error = 'Vui lòng nhập tên khách hàng.');
                            return;
                          }
                          if (status == 'delivered' && paymentMethod == null) {
                            setStateDialog(() => error = 'Đã trả máy thì phải chọn hình thức thanh toán (Tiền mặt/Chuyển khoản/Ghi nợ).');
                            return;
                          }
                          setStateDialog(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            final uid = SupabaseService.currentUser?.id ?? '';

                            var customerId = pickedCustomerId;
                            final phone = phoneCtrl.text.trim();
                            if (customerId == null) {
                              if (phone.isNotEmpty) {
                                final existing = await SupabaseService.client
                                    .from('customers')
                                    .select('id')
                                    .eq('store_id', storeId)
                                    .eq('phone', phone)
                                    .maybeSingle();
                                customerId = existing?['id'] as String?;
                              }
                              customerId ??= (await SupabaseService.client
                                  .from('customers')
                                  .insert({
                                    'store_id': storeId,
                                    'name': nameCtrl.text.trim(),
                                    'phone': phone.isEmpty ? null : phone,
                                  })
                                  .select('id')
                                  .single())['id'] as String;
                            }

                            final statusActuallyChanged = !isEditing || status != editing.status;
                            // Rời khỏi trạng thái "đã trả máy" -> đảo hạch toán và
                            // xoá các trường trả máy để không còn tính doanh thu.
                            final leavingDelivered =
                                isEditing && editing.status == 'delivered' && status != 'delivered';
                            final paidDate = paidAt;
                            final payload = {
                              'customer_id': customerId,
                              'device_model': modelCtrl.text.trim().isEmpty ? null : modelCtrl.text.trim(),
                              'imei': imeiCtrl.text.trim().isEmpty ? null : imeiCtrl.text.trim(),
                              'issue_description': issueCtrl.text.trim().isEmpty ? null : issueCtrl.text.trim(),
                              'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                              'estimated_cost': num.tryParse(priceCtrl.text.trim()) ?? 0,
                              'warranty_days': int.tryParse(warrantyCtrl.text.trim()) ?? 0,
                              'technician_id': assignedToId,
                              'status': status,
                              'payment_method': leavingDelivered ? null : paymentMethod,
                              if (statusActuallyChanged) 'status_changed_at': DateTime.now().toIso8601String(),
                              if (statusActuallyChanged) 'aging_alert_level': 0,
                              if (status == 'repaired') 'completed_at': DateTime.now().toIso8601String(),
                              if (status == 'repaired') 'repaired_by': assignedToId,
                              if (status == 'delivered') ...{
                                // Ngày trả máy = ngày thanh toán đã chọn (nếu có),
                                // nếu không chọn thì lấy thời điểm hiện tại.
                                if (statusActuallyChanged || paidAt != null)
                                  'delivered_at': (paidAt ?? DateTime.now()).toIso8601String(),
                                'final_cost': num.tryParse(priceCtrl.text.trim()) ?? 0,
                                // Thanh toán lúc trả máy: không chọn ngày thì mặc định hôm nay.
                                'paid_at': (paidAt ?? DateTime.now()).toIso8601String(),
                              },
                              if (leavingDelivered) ...{
                                'delivered_at': null,
                                'paid_at': null,
                              },
                              // Sửa lại ngày trả máy -> ngày tạo đơn tự sửa trùng với
                              // ngày trả máy cho khớp.
                              if (status == 'delivered' && paidDate != null &&
                                  (statusActuallyChanged ||
                                      (initialPaidAt != null &&
                                          !paidDate.isAtSameMomentAs(initialPaidAt))))
                                'received_at': paidDate.toIso8601String(),
                            };

                            if (leavingDelivered) {
                              await _reverseOrderRevenue(editing, storeId);
                            }

                            String orderId;
                            String orderCode;
                            if (isEditing) {
                              orderId = editing.id;
                              orderCode = editing.code;
                              await SupabaseService.client.from('repair_orders').update(payload).eq('id', orderId);
                            } else {
                              orderCode = await _generateUniqueOrderCode(storeId);
                              final inserted = await SupabaseService.client
                                  .from('repair_orders')
                                  .insert({
                                    ...payload,
                                    'store_id': storeId,
                                    'code': orderCode,
                                    'received_by': uid,
                                  })
                                  .select('id')
                                  .single();
                              orderId = inserted['id'] as String;
                              try {
                                DiscordWebhook.notifyNewOrder(
                                  storeId: storeId,
                                  orderCode: orderCode,
                                  customerName: nameCtrl.text.trim(),
                                  technicianId: assignedToId,
                                );
                              } catch (_) {}
                            }

                            // Tạo mã QR bảo hành
                            if (!isEditing) {
                              try {
                                final warrantyDays = int.tryParse(warrantyCtrl.text.trim()) ?? 0;
                                final expiresAt = warrantyDays > 0
                                    ? DateTime.now().add(Duration(days: warrantyDays))
                                    : null;
                                await SupabaseService.client.from('qr_codes').insert({
                                  'store_id': storeId,
                                  'order_id': orderId,
                                  'code': orderCode,
                                  'warranty_expires_at': expiresAt?.toIso8601String(),
                                });
                              } catch (_) {}
                            }

                            // Phân công cho ai thì gửi notification riêng cho người đó.
                            if (assignedToId != null && assignedToId != originalAssignedToId) {
                              try {
                                await SupabaseService.client.from('notifications').insert({
                                  'store_id': storeId,
                                  'user_id': assignedToId,
                                  'title': 'Bạn được giao đơn $orderCode',
                                  'body': 'Model: ${modelCtrl.text.trim()} · Trạng thái: ${StatusColors.label[status] ?? status}',
                                  'data': {'order_id': orderId, 'order_code': orderCode},
                                });
                              } catch (_) {}
                            }

                            // Upload ảnh (nếu có chụp/chọn mới)
                            final photoUpdates = <String, dynamic>{};
                            if (frontBytes != null) {
                              photoUpdates['photo_front_path'] = await uploadRepairPhoto(
                                  storeId: storeId, orderId: orderId, fileName: 'front.jpg', bytes: frontBytes!);
                            }
                            if (backBytes != null) {
                              photoUpdates['photo_back_path'] = await uploadRepairPhoto(
                                  storeId: storeId, orderId: orderId, fileName: 'back.jpg', bytes: backBytes!);
                            }
                            if (photoUpdates.isNotEmpty) {
                              await SupabaseService.client.from('repair_orders').update(photoUpdates).eq('id', orderId);
                            }

                            // Đồng bộ linh kiện đã dùng: xoá bớt (hoàn kho), thêm mới (trừ kho), đổi số lượng.
                            for (final orig in originalPartsUsed) {
                              final match = currentPartsUsed.where((c) => c['part_id'] == orig['part_id']);
                              if (match.isEmpty) {
                                await SupabaseService.client.from('inventory_transactions').delete().eq('id', orig['tx_id']);
                                if (orig['is_external'] == true) {
                                  // Linh kiện ngoài (mua riêng cho đơn): đảo phiếu
                                  // chi/nợ đã ghi, rồi xóa linh kiện khỏi kho.
                                  final partId = orig['part_id'] as String;
                                  await _reverseExternalPart(
                                    orderCode: orderCode,
                                    orderId: orderId,
                                    storeId: storeId,
                                    partId: orig['part_id'] as String,
                                    partName: orig['name'] ?? '',
                                  );
                                  await SupabaseService.client.from('inventory_transactions').delete().eq('part_id', partId);
                                  // Xoá hẳn khỏi bảng; fallback soft-delete nếu RLS/FK chặn.
                                  try {
                                    await SupabaseService.client.from('inventory_parts').delete().eq('id', partId);
                                  } catch (_) {
                                    await SupabaseService.client.from('inventory_parts').update({
                                      'deleted_at': DateTime.now().toIso8601String(),
                                    }).eq('id', partId);
                                  }
                                } else {
                                  final part = await SupabaseService.client
                                      .from('inventory_parts')
                                      .select('quantity')
                                      .eq('id', orig['part_id'])
                                      .single();
                                  await SupabaseService.client
                                      .from('inventory_parts')
                                      .update({'quantity': (part['quantity'] as int) + (orig['quantity'] as int)})
                                      .eq('id', orig['part_id']);
                                }
                              } else if (match.first['quantity'] != orig['quantity']) {
                                final delta = (match.first['quantity'] as int) - (orig['quantity'] as int);
                                await SupabaseService.client
                                    .from('inventory_transactions')
                                    .update({'quantity': match.first['quantity']}).eq('id', orig['tx_id']);
                                if (delta > 0) {
                                  // Tăng số lượng dùng -> trừ kho atomic, chặn âm kho.
                                  if (!await _decStock(orig['part_id'] as String, delta)) {
                                    throw Exception('Không đủ tồn kho linh kiện đã chọn.');
                                  }
                                } else if (delta < 0) {
                                  // Giảm số lượng dùng -> hoàn kho.
                                  final part = await SupabaseService.client
                                      .from('inventory_parts')
                                      .select('quantity')
                                      .eq('id', orig['part_id'])
                                      .single();
                                  await SupabaseService.client
                                      .from('inventory_parts')
                                      .update({'quantity': (part['quantity'] as int) - delta})
                                      .eq('id', orig['part_id']);
                                }
                              }
                            }
                            for (final cur in currentPartsUsed) {
                              final existedBefore = originalPartsUsed.any((o) => o['part_id'] == cur['part_id']);
                              if (!existedBefore) {
                                await SupabaseService.client.from('inventory_transactions').insert({
                                  'store_id': storeId,
                                  'part_id': cur['part_id'],
                                  'type': 'out',
                                  'quantity': cur['quantity'],
                                  'repair_order_id': orderId,
                                  'created_by': uid,
                                });
                                if (!await _decStock(cur['part_id'] as String, cur['quantity'] as int)) {
                                  throw Exception('Không đủ tồn kho linh kiện đã chọn.');
                                }
                                // Linh kiện ngoài mua cho đơn này: ghi phiếu chi /
                                // nợ NCC NGAY tại lúc lưu đơn (đã có mã đơn) để khi
                                // hủy đơn đảo được khoản này.
                                if (cur['is_external'] == true) {
                                  final extCost = (cur['external_cost'] as num?) ?? 0;
                                  final extPay = cur['external_pay'] as String?;
                                  if (extCost > 0 && extPay != null) {
                                    final extName = (cur['name'] ?? '').toString();
                                    final extQty = (cur['quantity'] as num?)?.toInt() ?? 0;
                                    if (extPay == 'debt') {
                                      final supplierId = cur['external_supplier_id'] as String?;
                                      final debtContactName = supplierId != null
                                          ? ((cur['external_supplier_name'] as String?)?.toString().trim() ?? '')
                                          : 'Nhập lk ngoài';
                                      String debtId;
                                      if (supplierId != null) {
                                        final sup = await SupabaseService.client
                                            .from('debts').select('total_debt').eq('id', supplierId).maybeSingle();
                                        final curDebt = (sup?['total_debt'] as num?) ?? 0;
                                        await SupabaseService.client.from('debts')
                                            .update({'total_debt': curDebt + extCost}).eq('id', supplierId);
                                        debtId = supplierId;
                                      } else {
                                        // Không chọn NCC -> ghi nợ vào công nợ chung
                                        // "Nhập lk ngoài" (nội dung nhập lk ngoài,
                                        // không lấy tên NCC gõ tay).
                                        const contactName = 'Nhập lk ngoài';
                                        final existingDebt = await SupabaseService.client
                                            .from('debts')
                                            .select('id, total_debt')
                                            .eq('store_id', storeId)
                                            .eq('type', 'supplier')
                                            .eq('contact_name', contactName)
                                            .maybeSingle();
                                        if (existingDebt != null) {
                                          await SupabaseService.client.from('debts')
                                              .update({'total_debt': ((existingDebt['total_debt'] as num?) ?? 0) + extCost})
                                              .eq('id', existingDebt['id']);
                                          debtId = existingDebt['id'] as String;
                                        } else {
                                          final inserted = await SupabaseService.client.from('debts').insert({
                                            'store_id': storeId, 'type': 'supplier', 'contact_name': contactName,
                                            'total_debt': extCost, 'note': 'Nhập kho $extName',
                                          }).select('id').single();
                                          debtId = inserted['id'] as String;
                                        }
                                      }
                                      // Liên kết đơn + linh kiện để khi bỏ linh kiện
                                      // ra khỏi đơn đảo được công nợ chính xác.
                                      // Nếu chưa chạy migration (chưa có 2 cột này) thì
                                      // ghi bình thường, việc đảo vẫn dò theo mô tả.
                                      try {
                                        await SupabaseService.client.from('debt_transactions').insert({
                                          'store_id': storeId, 'debt_id': debtId, 'type': 'add',
                                          'amount': extCost,
                                          'description': 'Đơn $orderCode · Nhập kho $extName x$extQty',
                                          'created_by': uid,
                                          'repair_order_id': orderId,
                                          'inventory_part_id': cur['part_id'],
                                          'transaction_date': (paidAt ?? DateTime.now()).toIso8601String(),
                                        });
                                      } catch (_) {
                                        await SupabaseService.client.from('debt_transactions').insert({
                                          'store_id': storeId, 'debt_id': debtId, 'type': 'add',
                                          'amount': extCost,
                                          'description': 'Đơn $orderCode · Nhập kho $extName x$extQty',
                                          'created_by': uid,
                                          'transaction_date': (paidAt ?? DateTime.now()).toIso8601String(),
                                        });
                                      }
                                      await notifyWholeStore(
                                        storeId: storeId,
                                        title: 'Nợ NCC ${_currency.format(extCost)}',
                                        body: 'Nhập kho $extName x$extQty · $debtContactName (đơn $orderCode)',
                                        data: {
                                          'finance': true,
                                          'type': 'debt',
                                          'category': 'Nợ NCC',
                                          'order_id': orderId,
                                          'order_code': orderCode,
                                        },
                                      );
                                    } else if (extPay == 'cash' || extPay == 'transfer') {
                                      final acct = await _ensureAccount(storeId, extPay == 'cash' ? 'cash' : 'bank');
                                      await SupabaseService.client.from('transactions').insert({
                                        'store_id': storeId,
                                        'type': 'expense',
                                        'category': 'Linh kiện',
                                        'amount': extCost,
                                        'description': 'Nhập kho $extName x$extQty · Đơn $orderCode',
                                        'repair_order_id': orderId,
                                        'created_by': uid,
                                        if (acct != null) 'account_id': acct['id'],
                                        'transaction_date': (paidAt ?? DateTime.now()).toIso8601String(),
                                      });
                                      if (acct != null) {
                                        await SupabaseService.client.from('cash_accounts')
                                            .update({'balance': ((acct['balance'] as num?) ?? 0) - extCost})
                                            .eq('id', acct['id']);
                                      }
                                      await notifyWholeStore(
                                        storeId: storeId,
                                        title: 'Chi linh kiện ${_currency.format(extCost)}',
                                        body: 'Nhập kho $extName x$extQty · ${extPay == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'} (đơn $orderCode)',
                                        data: {
                                          'finance': true,
                                          'type': 'expense',
                                          'category': 'Linh kiện',
                                          'order_id': orderId,
                                          'order_code': orderCode,
                                        },
                                      );
                                    }
                                  }
                                }
                              }
                            }

                            // Tạo/sửa đơn "đã trả máy" -> ghi nhận / điều chỉnh doanh thu
                            // hoặc công nợ. _recordDeliveredRevenue idempotent nên gọi lại
                            // an toàn (kể cả khi chỉ sửa giá/phương thức thanh toán).
                            if (status == 'delivered') {
                              final finalAmount = num.tryParse(priceCtrl.text.trim()) ?? 0;
                              if (finalAmount > 0) {
                                // Đơn đang trả máy và đổi phương thức thanh toán ->
                                // đảo hạch toán cũ rồi ghi lại theo phương thức mới.
                                if (isEditing && editing.status == 'delivered' &&
                                    paymentMethod != editing.paymentMethod) {
                                  await _reverseOrderRevenue(editing, storeId);
                                }
                                await _recordDeliveredRevenue(
                                  orderId: orderId,
                                  orderCode: orderCode,
                                  customerId: customerId,
                                  storeId: storeId,
                                  uid: uid,
                                  paymentMethod: paymentMethod,
                                  amount: finalAmount,
                                  transactionDate: paidAt,
                                );
                              }
                            }

                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                              showToast(context, isEditing ? 'Đã cập nhật đơn' : 'Đã tạo đơn mới');
                            }
                            await AppLogger.instance.action(
                              '${isEditing ? 'Sửa đơn' : 'Tạo đơn'} $orderCode · ${nameCtrl.text.trim()}',
                              category: 'don_sua',
                              data: {'order_id': orderId, 'status': status, 'customer_id': customerId},
                            );
                            if (mounted) _clearSelection();
                            // Tải lại danh sách ngay (không chờ realtime) để đơn
                            // mới/sửa hiện lên tức thì kể cả khi realtime bị đứng.
                            await _reloadOrders();
                          } catch (e) {
                            setStateDialog(() {
                              saving = false;
                              error = 'Lỗi: ${friendlyError(e)}';
                            });
                          }
                        },
                  child: saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
                      : Text(isEditing ? 'Lưu thay đổi' : 'Tạo đơn'),
                ),
              ),
      );
    } finally {
      // Dialog đã đóng nhưng route vẫn còn chạy animation thoát ra, các TextField
      // (đặc biệt là ô autocomplete tên khách) vẫn còn mount và vẫn dùng những
      // FocusNode này. Dispose ngay ở đây sẽ gây "A FocusNode was used after being
      // disposed" khi route rebuild trong lúc thoát (kéo theo loạt lỗi framework
      // như "_dependents.isEmpty"). Đợi route tháo xong rồi mới dispose.
      Future.delayed(const Duration(milliseconds: 700), () {
        modelFocusNode.dispose();
        nameFocusNode.dispose();
        phoneFocusNode.dispose();
      });
    }
  }


  Future<Map<String, dynamic>?> _showCustomerPicker(BuildContext parentCtx) async {
    final searchCtrl = TextEditingController();
    return showModalBottomSheet<Map<String, dynamic>>(
      context: parentCtx,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setStateSheet) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Tìm khách hàng theo tên hoặc SĐT',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setStateSheet(() {}),
                  ),
                ),
                Expanded(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: autoReconnectStream(() => SupabaseService.client.from('customers').stream(primaryKey: ['id']).order('name'), label: 'customers_dlg'),
                    builder: (context, snap) {
                      final all = (snap.data ?? [])
                          .where((c) => c['deleted_at'] == null)
                          .toList();
                      final q = searchCtrl.text.trim().toLowerCase();
                      final filtered = q.isEmpty
                          ? all
                          : all.where((c) =>
                              (c['name'] ?? '').toString().toLowerCase().contains(q) ||
                              (c['phone'] ?? '').toString().toLowerCase().contains(q)).toList();
                      if (filtered.isEmpty) {
                        return const Center(child: Text('Không tìm thấy khách hàng.'));
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final c = filtered[i];
                          final isWholesale = c['customer_type'] == 'wholesale';
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isWholesale ? const Color(0xFF1B3A6B) : null,
                              child: Icon(
                                isWholesale ? Icons.groups : Icons.person,
                                color: isWholesale ? Colors.white : null,
                                size: 18,
                              ),
                            ),
                            title: Text(c['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Row(children: [
                              Text(c['phone'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                              if (isWholesale) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1B3A6B).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('Sỉ', style: TextStyle(fontSize: 10, color: Color(0xFF1B3A6B), fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ]),
                            onTap: () => Navigator.pop(ctx, c),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _showSupplierPicker(BuildContext parentCtx) async {
    final searchCtrl = TextEditingController();
    return showModalBottomSheet<Map<String, dynamic>>(
      context: parentCtx,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setStateSheet) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Tìm nhà cung cấp theo tên hoặc SĐT',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setStateSheet(() {}),
                  ),
                ),
                Expanded(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: autoReconnectStream(() => SupabaseService.client
                        .from('debts')
                        .stream(primaryKey: ['id'])
                        .eq('type', 'supplier')
                        .order('contact_name'), label: 'debts_dlg'),
                    builder: (context, snap) {
                      final all = (snap.data ?? []).toList();
                      final q = searchCtrl.text.trim().toLowerCase();
                      final filtered = q.isEmpty
                          ? all
                          : all.where((s) =>
                              (s['contact_name'] ?? '').toString().toLowerCase().contains(q) ||
                              (s['contact_phone'] ?? '').toString().toLowerCase().contains(q)).toList();
                      if (filtered.isEmpty) {
                        return const Center(child: Text('Không tìm thấy nhà cung cấp.'));
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final s = filtered[i];
                          return ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.business_outlined)),
                            title: Text(s['contact_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(s['contact_phone'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(ctx, s),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<String> _generateUniqueOrderCode(String storeId) async {
    final now = DateTime.now();
    final datePart = DateFormat('yyMMdd').format(now);
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final todayOrders = await SupabaseService.client
        .from('repair_orders')
        .select('id')
        .eq('store_id', storeId)
        .gte('received_at', dayStart.toIso8601String())
        .lt('received_at', dayEnd.toIso8601String());
    var seq = (todayOrders as List).length + 1;

    for (var attempt = 0; attempt < 5; attempt++) {
      final code = 'SC$datePart${seq.toString().padLeft(3, '0')}';
      final exists = await SupabaseService.client
          .from('repair_orders')
          .select('id')
          .eq('store_id', storeId)
          .eq('code', code)
          .maybeSingle();
      if (exists == null) return code;
      seq++;
    }
    return 'SC$datePart${DateTime.now().millisecondsSinceEpoch % 1000}';
  }

  // ---------------- Cập nhật trạng thái ----------------

  Future<void> _showStatusUpdateDialog(List<RepairOrder> orders) async {
    final isBulk = orders.length > 1;
    final single = isBulk ? null : orders.first;
    String status = single?.status ?? 'repairing';
    String? assignedToId = single?.technicianId;
    bool assigneeTouched = false;
    // Ưu tiên final_cost (giá đã chốt) — nếu chưa có thì lấy giá lúc tạo đơn
    // (estimated_cost) thay vì để trống, để không mất thông tin giá đã nhập.
    final initialPriceValue = single == null
        ? 0
        : (single.finalCost != 0 ? single.finalCost : single.estimatedCost);
    final priceCtrl = TextEditingController(
      text: initialPriceValue == 0 ? '' : initialPriceValue.toStringAsFixed(0),
    );
    final noteCtrl = TextEditingController(text: single?.note ?? '');
    DateTime? paidAt = single?.paidAt;
    String paymentMethod = single?.paymentMethod ?? 'cash';
    bool saving = false;
    String? error;

    final initialStatus = status;
    final initialAssignedToId = assignedToId;
    final initialPrice = priceCtrl.text;
    final initialNote = noteCtrl.text;
    final initialPaidAt = paidAt;
    final initialPaymentMethod = paymentMethod;

    // Toàn bộ nhân viên trong cửa hàng (không chỉ KTV — đơn có thể được giao
    // cho lễ tân/admin), để dropdown luôn khớp đúng người đang được giao,
    // tránh bị reset về "chưa giao" nhầm khi người đó không phải KTV.
    final storeId = await _currentStoreId();
    var staffList = <Map<String, dynamic>>[];
    try {
      final rows = await SupabaseService.client
          .from('profiles')
          .select('id, full_name, role')
          .eq('store_id', storeId);
      staffList = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
    String? roleOf(String? staffId) =>
        staffList.firstWhere((s) => s['id'] == staffId, orElse: () => const {})['role'] as String?;

    // Đang có thay đổi so với ban đầu — dùng chung cho nút Hủy và phím ESC.
    bool statusFormDirty() =>
        status != initialStatus ||
        assignedToId != initialAssignedToId ||
        priceCtrl.text.trim() != initialPrice.trim() ||
        noteCtrl.text.trim() != initialNote.trim() ||
        paidAt != initialPaidAt ||
        paymentMethod != initialPaymentMethod;

    if (!mounted) return;
    await showAdaptiveFormDialog(
      context: context,
      title: isBulk ? 'Cập nhật ${orders.length} đơn đã chọn' : 'Cập nhật đơn ${single!.code}',
      desktopWidth: 460,
      // Phím ESC = hủy như nút Hủy (có xác nhận nếu đang có thay đổi).
      onEscCancel: (dlgCtx) async {
        if (saving) return;
        if (dlgCtx.mounted) Navigator.pop(dlgCtx);
      },
      escIsDirty: statusFormDirty,
      contentBuilder: (ctx, setStateDialog) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isBulk)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text('Để trống "Giao cho" = giữ nguyên người đang phụ trách của từng đơn',
                        style: TextStyle(color: Colors.black54, fontSize: 11)),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Builder(builder: (context) {
                        final validIds = staffList.map((s) => s['id'] as String).toSet();
                        final safeId = (assignedToId != null && validIds.contains(assignedToId)) ? assignedToId : null;
                        return DropdownButtonFormField<String>(
                          key: ValueKey('assignee_dropdown_${staffList.length}_$safeId'),
                          initialValue: safeId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Giao cho',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          ),
                          items: [
                            DropdownMenuItem(value: null, child: Text('-- Chưa giao --', overflow: TextOverflow.ellipsis)),
                            for (final s in staffList)
                              DropdownMenuItem(value: s['id'] as String, child: Text(s['full_name'] ?? '', overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setStateDialog(() {
                            assignedToId = v;
                            assigneeTouched = true;
                            if (!isBulk) {
                              final allowed = statusOptionsForRole(roleOf(v));
                              if (!allowed.contains(status)) status = allowed.first;
                            }
                          }),
                        );
                      }),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Builder(builder: (context) {
                        final allowed = statusOptionsForRole(roleOf(SupabaseService.currentUser?.id));
                        final safeStatus = allowed.contains(status) ? status : allowed.first;
                        return DropdownButtonFormField<String>(
                          key: ValueKey('status_dropdown_${assignedToId}_$safeStatus'),
                          initialValue: safeStatus,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Trạng thái',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          ),
                          items: [
                            for (final s in allowed)
                              DropdownMenuItem(value: s, child: Text(StatusColors.label[s] ?? s, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setStateDialog(() => status = v ?? status),
                        );
                      }),
                    ),
                  ],
                ),
                if (!isBulk) ...[
                  const SizedBox(height: 8),
                  MoneyInputField(controller: priceCtrl, label: 'Giá tiền'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú',
                      helperText: 'Bổ sung chi tiết sau khi kiểm tra máy',
                      isDense: true,
                    ),
                  ),
                ] else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'Không sửa được giá tiền khi chọn nhiều đơn (mỗi đơn có giá khác nhau).',
                      style: TextStyle(color: Colors.black54, fontSize: 11),
                    ),
                  ),
                if (status == 'delivered') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: paidAt ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                              locale: const Locale('vi'),
                            );
                            if (picked != null) setStateDialog(() => paidAt = picked);
                          },
                          icon: const Icon(Icons.calendar_today, size: 14),
                          label: Text(paidAt == null ? 'Ngày thanh toán' : _dateFmt.format(paidAt!), style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<String>(
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          segments: const [
                            ButtonSegment(value: 'debt', label: Text('Ghi nợ')),
                            ButtonSegment(value: 'cash', label: Text('T.Mặt')),
                            ButtonSegment(value: 'transfer', label: Text('C.Khoản')),
                          ],
                          selected: {paymentMethod},
                          onSelectionChanged: (s) => setStateDialog(() => paymentMethod = s.first),
                        ),
                      ),
                    ],
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ],
            ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
              onCancel: saving ? null : () => Navigator.pop(ctx),
              isDirty: statusFormDirty,
              primaryButton: ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        setStateDialog(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          // Sửa lại ngày trả máy -> ngày tạo đơn tự sửa trùng với
                          // ngày trả máy (chỉ áp dụng khi sửa 1 đơn, vì mỗi đơn có
                          // ngày tạo khác nhau).
                          bool syncReceivedDate = false;
                          final paidDate = paidAt;
                          if (!isBulk && status == 'delivered' && paidDate != null &&
                              (initialStatus != status ||
                                  (initialPaidAt != null &&
                                      !paidDate.isAtSameMomentAs(initialPaidAt)))) {
                            syncReceivedDate = true;
                          }

                          final payload = <String, dynamic>{
                            'status': status,
                            'status_changed_at': DateTime.now().toIso8601String(),
                            'aging_alert_level': 0,
                          };
                          if (!isBulk || assigneeTouched) {
                            payload['technician_id'] = assignedToId;
                          }
                          if (!isBulk) {
                            payload['final_cost'] = num.tryParse(priceCtrl.text.trim()) ?? 0;
                            payload['note'] = noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim();
                          }
                          if (status == 'delivered') {
                            // Ngày trả máy = ngày thanh toán đã chọn (nếu có),
                            // nếu không chọn thì lấy thời điểm hiện tại.
                            if (initialStatus != status) {
                              payload['delivered_at'] = (paidAt ?? DateTime.now()).toIso8601String();
                            } else if (paidAt != null) {
                              // Đơn đã trả máy, sửa ngày thanh toán -> đồng bộ ngày trả máy.
                              payload['delivered_at'] = paidAt!.toIso8601String();
                            }
                            // Thanh toán lúc trả máy: chuyển sang trạng thái "đã trả máy"
                            // mà không chọn ngày thì mặc định ngày hôm nay.
                            if (initialStatus != status) {
                              payload['paid_at'] = (paidAt ?? DateTime.now()).toIso8601String();
                            } else if (paidAt != null) {
                              payload['paid_at'] = paidAt!.toIso8601String();
                            }
                            payload['payment_method'] = paymentMethod;
                          }
                          if (status == 'repaired') {
                            payload['completed_at'] = DateTime.now().toIso8601String();
                          }
                          if (syncReceivedDate && paidAt != null) {
                            payload['received_at'] = paidAt!.toIso8601String();
                          }

                          for (final o in orders) {
                            final perOrderPayload = Map<String, dynamic>.from(payload);
                            if (status == 'repaired') {
                              perOrderPayload['repaired_by'] =
                                  perOrderPayload['technician_id'] ?? o.technicianId;
                            }
                            // Đơn đang "đã trả máy" bị chuyển sang trạng thái khác ->
                            // đảo hạch toán và xoá các trường trả máy.
                            if (o.status == 'delivered' && status != 'delivered') {
                              await _reverseOrderRevenue(o, storeId);
                              perOrderPayload['delivered_at'] = null;
                              perOrderPayload['paid_at'] = null;
                              perOrderPayload['payment_method'] = null;
                            }
                            // Hủy đơn -> đảo cả nợ NCC / phiếu chi linh kiện ngoài của đơn.
                            if (status == 'cancelled') {
                              await _reverseOrderExternalPayments(o, storeId);
                            }
                            // Bulk: không ghi đè ngày trả máy / phương thức thanh toán
                            // của đơn đã trả máy từ trước.
                            if (isBulk && o.status == 'delivered' && status == 'delivered') {
                              perOrderPayload.remove('delivered_at');
                              perOrderPayload.remove('paid_at');
                              perOrderPayload.remove('payment_method');
                            }
                            await SupabaseService.client.from('repair_orders').update(perOrderPayload).eq('id', o.id);
                            if (!isBulk && initialStatus != status) {
                              try {
                                DiscordWebhook.notifyStatusChange(
                                  storeId: storeId,
                                  orderCode: o.code,
                                  oldStatus: initialStatus,
                                  newStatus: status,
                                  technicianId: assignedToId ?? o.technicianId,
                                );
                              } catch (_) {}
                            }
                          }

                          // Nếu trả máy -> ghi nhận / điều chỉnh doanh thu hoặc công nợ.
                          // _recordDeliveredRevenue là idempotent nên có thể gọi lại an toàn.
                          if (status == 'delivered') {
                            final uid = SupabaseService.currentUser?.id ?? '';
                            if (isBulk) {
                              // Hàng loạt: mỗi đơn dùng đúng giá + ngày của đơn đó.
                              for (final o in orders) {
                                if (o.status == 'delivered') continue;
                                final amount = o.finalCost > 0 ? o.finalCost : o.estimatedCost;
                                if (amount > 0) {
                                  await _recordDeliveredRevenue(
                                    orderId: o.id,
                                    orderCode: o.code,
                                    customerId: o.customerId,
                                    storeId: storeId,
                                    uid: uid,
                                    paymentMethod: paymentMethod,
                                    amount: amount,
                                    transactionDate: o.paidAt ?? o.receivedAt,
                                  );
                                }
                              }
                            } else {
                              // Đơn đang trả máy và đổi phương thức thanh toán -> đảo
                              // hạch toán cũ rồi ghi lại theo phương thức mới.
                              if (initialStatus == 'delivered' && paymentMethod != initialPaymentMethod) {
                                await _reverseOrderRevenue(single!, storeId);
                              }
                              final finalAmount = num.tryParse(priceCtrl.text.trim()) ?? 0;
                              if (finalAmount > 0) {
                                await _recordDeliveredRevenue(
                                  orderId: single!.id,
                                  orderCode: single.code,
                                  customerId: single!.customerId,
                                  storeId: storeId,
                                  uid: uid,
                                  paymentMethod: paymentMethod,
                                  amount: finalAmount,
                                  transactionDate: paidAt,
                                );
                              }
                            }
                          }

                          // Nếu vừa đổi người giao (khác ban đầu) -> báo riêng cho người đó.
                          if (assigneeTouched && assignedToId != null && assignedToId != initialAssignedToId) {
                            try {
                              await SupabaseService.client.from('notifications').insert({
                                'store_id': storeId,
                                'user_id': assignedToId,
                                'title': isBulk
                                    ? 'Bạn được giao ${orders.length} đơn sửa chữa'
                                    : 'Bạn được giao đơn ${single!.code}',
                                'body': 'Trạng thái: ${StatusColors.label[status] ?? status}',
                                if (!isBulk) 'data': {'order_id': single!.id, 'order_code': single.code},
                              });
                            } catch (_) {}
                          }

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            showToast(context, 'Đã cập nhật trạng thái');
                          }
                          if (mounted) _clearSelection();
                        } catch (e) {
                          setStateDialog(() {
                            saving = false;
                            error = 'Lỗi: ${friendlyError(e)}';
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
                    : const Text('Cập nhật'),
              ),
            ),
    );
  }


  /// Lấy vai trò của người đang thao tác để lọc trạng thái được phép.
  Future<String?> _currentUserRole() async {
    try {
      final uid = SupabaseService.currentUser?.id;
      if (uid == null) return null;
      final row = await SupabaseService.client
          .from('profiles')
          .select('role')
          .eq('id', uid)
          .maybeSingle();
      return row?['role'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ---------------- Đơn hoàn tất (đã trả máy + khách không sửa) ----------------

  /// Mở dialog chi tiết đơn đã hoàn tất. Trạng thái chọn trực tiếp trong
  /// dialog bằng dropdown; đổi trạng thái sẽ qua [_applyStatusChange] để giữ
  /// đúng logic hạch toán/thông báo như menu nhanh.
  Future<void> _openCompleteOrderDialog(
    RepairOrder order,
    String customerName,
    String customerPhone,
  ) async {
    final allowedStatuses = statusOptionsForRole(await _currentUserRole())
        .where((s) => s != 'received')
        .toList();
    if (!mounted) return;
    await showCompleteOrderDialog(
      context: context,
      order: order,
      customerName: customerName,
      customerPhone: customerPhone,
      allowedStatuses: allowedStatuses,
      onChangeStatus: _changeCompleteOrderStatus,
    );
  }

  /// Xử lý đổi trạng thái từ dialog đơn hoàn tất: nếu chuyển sang "đã trả máy"
  /// thì hỏi hình thức thanh toán trước, rồi mới ghi bằng [_applyStatusChange].
  Future<void> _changeCompleteOrderStatus(RepairOrder order, String newStatus) async {
    if (newStatus == order.status) return;
    String? paymentMethod;
    if (newStatus == 'delivered') {
      paymentMethod = await _pickPaymentMethod(context);
      if (paymentMethod == null || !mounted) return;
    }
    await _applyStatusChange(order, newStatus, paymentMethod);
  }

  /// Hỏi hình thức thanh toán (ghi nợ / tiền mặt / chuyển khoản).
  Future<String?> _pickPaymentMethod(BuildContext dialogContext) {
    return showDialog<String>(
      context: dialogContext,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Hình thức thanh toán'),
        content: const Text('Đơn sẽ chuyển sang "Đã trả máy". Khách thanh toán bằng hình thức nào?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'debt'),
            child: const Text('Ghi nợ'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cash'),
            child: const Text('Tiền mặt'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'transfer'),
            child: const Text('Chuyển khoản'),
          ),
        ],
      ),
    );
  }

  // ---------------- Đổi trạng thái / giao việc nhanh (bấm vào chip trạng thái) ----------------

  Future<void> _showQuickStatusMenu(RepairOrder order, Offset tapPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(tapPosition, tapPosition),
      Offset.zero & overlay.size,
    );

    // Lọc theo vai trò người thao tác (giống dialog đổi trạng thái) để KTV
    // không tự trả máy/hủy đơn dù được giao làm.
    final allowedStatuses = statusOptionsForRole(await _currentUserRole())
        .where((s) => s != 'received')
        .toList();

    final newStatus = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final s in allowedStatuses)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Icon(Icons.circle, size: 10, color: StatusColors.map[s]),
                const SizedBox(width: 10),
                Text(StatusColors.label[s] ?? s),
                if (s == order.status) ...[
                  const Spacer(),
                  const Icon(Icons.check, size: 16),
                ],
              ],
            ),
          ),
      ],
    );
    if (newStatus == null || !mounted) return;

    String? paymentMethod;
    if (newStatus == 'delivered') {
      paymentMethod = await showMenu<String>(
        context: context,
        position: position,
        items: [
          PopupMenuItem(
            value: 'debt',
            child: const Text('Ghi nợ'),
          ),
          PopupMenuItem(
            value: 'cash',
            child: const Text('Tiền mặt'),
          ),
          PopupMenuItem(
            value: 'transfer',
            child: const Text('Chuyển khoản'),
          ),
        ],
      );
      if (paymentMethod == null || !mounted) return;
    }

    await _applyStatusChange(order, newStatus, paymentMethod);
  }

  /// Ghi trạng thái mới cho đơn + xử lý kèm theo: hạch toán/đảo hạch toán
  /// doanh thu, dọn các trường trả máy, thông báo Discord.
  /// Dùng chung cho menu nhanh (chip trạng thái) và dropdown trong dialog
  /// đơn hoàn tất để logic không bị lệch nhau.
  Future<void> _applyStatusChange(
    RepairOrder order,
    String newStatus,
    String? paymentMethod,
  ) async {
    final payload = <String, dynamic>{
      'status': newStatus,
      'status_changed_at': DateTime.now().toIso8601String(),
      'aging_alert_level': 0,
    };
    if (newStatus == 'delivered') {
      payload['delivered_at'] = DateTime.now().toIso8601String();
      payload['payment_method'] = paymentMethod;
      if (paymentMethod != 'debt') payload['paid_at'] = DateTime.now().toIso8601String();
    }
    if (newStatus == 'repaired') {
      payload['completed_at'] = DateTime.now().toIso8601String();
      payload['repaired_by'] = order.technicianId;
    }
    // Rời khỏi trạng thái "đã trả máy" -> đảo hạch toán và xoá các trường trả máy.
    if (order.status == 'delivered' && newStatus != 'delivered') {
      payload['delivered_at'] = null;
      payload['paid_at'] = null;
      payload['payment_method'] = null;
    }

    try {
      final storeId = _cachedStoreId ?? await _currentStoreId();
      if (order.status == 'delivered' && newStatus != 'delivered') {
        await _reverseOrderRevenue(order, storeId);
      }
      // Hủy đơn -> đảo cả nợ NCC / phiếu chi linh kiện ngoài của đơn.
      if (newStatus == 'cancelled') {
        await _reverseOrderExternalPayments(order, storeId);
      }
      await SupabaseService.client.from('repair_orders').update(payload).eq('id', order.id);

      if (newStatus == 'delivered' && newStatus != order.status) {
        final amount = order.finalCost > 0 ? order.finalCost : order.estimatedCost;
        if (amount > 0) {
          final uid = SupabaseService.currentUser?.id ?? '';
          // Dùng ngày thanh toán (paidAt) nếu có, fallback ngày nhận đơn.
          // Tránh dùng DateTime.now()导致 giao dịch bị gom nhầm vào ngày hiện tại
          // thay vì ngày đơn thực sự được ghi nhận.
          await _recordDeliveredRevenue(
            orderId: order.id,
            orderCode: order.code,
            customerId: order.customerId,
            storeId: storeId,
            uid: uid,
            paymentMethod: paymentMethod,
            amount: amount,
            transactionDate: order.paidAt ?? order.receivedAt,
          );
        }
      }

      if (newStatus != order.status) {
        try {
          DiscordWebhook.notifyStatusChange(
            storeId: storeId,
            orderCode: order.code,
            oldStatus: order.status,
            newStatus: newStatus,
            technicianId: order.technicianId,
          );
        } catch (_) {}
      }
      if (newStatus != order.status) {
        await AppLogger.instance.action(
          'Đơn ${order.code}: ${StatusColors.label[order.status] ?? order.status} → ${StatusColors.label[newStatus] ?? newStatus}',
          category: 'don_sua',
          data: {'order_id': order.id, 'old_status': order.status, 'new_status': newStatus, 'payment_method': paymentMethod},
        );
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  // ---------------- Xóa (thùng rác) ----------------

  Future<void> _deleteOrders(List<RepairOrder> orders) async {
    final delivered = orders.where((o) => o.status == 'delivered').toList();
    if (delivered.isNotEmpty) {
      if (mounted) {
        showToast(
          context,
          delivered.length == orders.length
              ? 'Không thể xóa đơn đã trả máy (${delivered.length} đơn)'
              : 'Đã bỏ qua ${delivered.length} đơn đã trả máy — không thể xóa',
          error: true,
          duration: const Duration(seconds: 4),
        );
      }
      orders = orders.where((o) => o.status != 'delivered').toList();
      if (orders.isEmpty) return;
    }

    final confirm = await showConfirmDialog(
      context: context,
      title: 'Chuyển vào thùng rác?',
      message: '${orders.length} đơn sẽ được chuyển vào thùng rác, lưu trong 90 ngày. '
          'Chỉ admin mới khôi phục được.',
      confirmLabel: 'Xóa',
      danger: true,
    );
    if (!confirm) return;

    try {
      final uid = SupabaseService.currentUser?.id ?? '';
      final storeId = await _currentStoreId();
      for (final o in orders) {
        await _reverseOrderRevenue(o, storeId);
        await _reverseOrderExternalPayments(o, storeId);
        await SupabaseService.client.from('repair_orders').update({
          'deleted_at': DateTime.now().toIso8601String(),
          'deleted_by': uid,
        }).eq('id', o.id);
      }

      final me = await SupabaseService.client.from('profiles').select('full_name').eq('id', uid).single();
      await SupabaseService.client.from('notifications').insert({
        'store_id': storeId,
        'user_id': null,
        'title': orders.length == 1 ? 'Đơn ${orders.first.code} đã bị xóa' : '${orders.length} đơn đã bị xóa',
        'body': 'Bởi ${me['full_name']} · Xem trong Thùng rác để khôi phục (còn 90 ngày).',
      });

      if (mounted) {
        _clearSelection();
        showToast(context, 'Đã chuyển ${orders.length} đơn vào thùng rác');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  // ---------------- In ----------------

  Future<void> _showPrintPreview(List<RepairOrder> orders) async {
    Store? store;
    try {
      final storeId = _cachedStoreId ?? await _currentStoreId();
      final row = await SupabaseService.client.from('stores').select().eq('id', storeId).single();
      store = Store.fromMap(row);
    } catch (_) {}
    final staffName = SupabaseService.currentUser?.email ?? '';
    String buildText(RepairOrder o) => PrinterService.buildReceiptText(
      storeName: store?.name ?? '',
      storeAddress: store?.address ?? '',
      storePhone: store?.phone ?? '',
      storeTaxCode: store?.taxCode,
      bankName: store?.bankName,
      bankAccount: store?.bankAccount,
      bankBranch: store?.bankBranch,
      orderCode: o.code,
      customerName: '',
      customerPhone: '',
      deviceModel: o.deviceModel ?? '',
      imei: o.imei,
      issueDescription: o.issueDescription ?? '',
      status: o.status,
      finalCost: o.finalCost > 0 ? o.finalCost : o.estimatedCost,
      paymentMethod: o.paymentMethod ?? 'cash',
      receivedAt: o.receivedAt,
      warrantyDays: o.warrantyDays,
      headerText: store?.printHeader,
      footerText: store?.printFooter,
      staffName: staffName,
      showTimestamp: store?.printShowTimestamp ?? true,
      showTaxCode: store?.printShowTaxCode ?? true,
      showBank: store?.printShowBank ?? true,
    );
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(orders.length == 1 ? 'In phiếu ${orders.first.code}' : 'In ${orders.length} phiếu'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (store == null)
                  for (final o in orders) ...[
                    Text(o.code, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('${o.deviceModel ?? ''} · ${StatusColors.label[o.status]}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('Báo giá: ${_currency.format(o.estimatedCost)}'),
                    if (o.finalCost > 0) Text('Giá cuối: ${_currency.format(o.finalCost)}'),
                    const Divider(),
                  ]
                else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F4F5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          orders.map(buildText).join('\n'),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3),
                        ),
                        if (store!.printShowBank && store!.bankQr != null && store!.bankQr!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          FutureBuilder<String?>(
                            future: getRepairPhotoUrl(store!.bankQr!),
                            builder: (ctx, snap) {
                              final url = snap.data;
                              if (url == null) return const SizedBox.shrink();
                              return Center(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  color: Colors.white,
                                  child: Image.network(url, width: 120, height: 120, fit: BoxFit.contain),
                                ),
                              );
                            },
                          ),
                        ],
                        if (store!.printShowBank && store!.bankName != null && store!.bankName!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          SelectableText(
                            PrinterService.buildBankInfoText(
                              bankName: store!.bankName!,
                              bankAccount: store!.bankAccount,
                              bankBranch: store!.bankBranch,
                            ),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Máy in: ${store!.printerAddress ?? 'Chưa cấu hình'}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  Text('Loại: ${Platform.isAndroid ? "Bluetooth" : "TCP/IP"}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.print, size: 16),
                    label: const Text('In ngay'),
                    onPressed: () async {
                      final s = store;
                      if (s == null) return;
                      final addr = s.printerAddress;
                      if (addr == null || addr.isEmpty) {
                        showToast(ctx, 'Chưa cấu hình máy in trong Cài đặt');
                        return;
                      }
                      Uint8List? qrBytes;
                      String? bankInfoText;
                      if (s.printShowBank) {
                        if (s.bankQr != null && s.bankQr!.isNotEmpty) {
                          qrBytes = await downloadStoreFile(s.bankQr!);
                        }
                        if (s.bankName != null && s.bankName!.isNotEmpty) {
                          bankInfoText = PrinterService.buildBankInfoText(
                            bankName: s.bankName!,
                            bankAccount: s.bankAccount,
                            bankBranch: s.bankBranch,
                          );
                        }
                      }
                      for (final o in orders) {
                        final err = await PrinterService.printReceipt(
                          printerAddress: addr,
                          receiptText: buildText(o),
                          qrImageBytes: qrBytes,
                          bankInfoText: bankInfoText,
                        );
                        if (err != null && ctx.mounted) {
                          showToast(ctx, err, error: true);
                        }
                      }
                      if (ctx.mounted) {
                        showToast(ctx, 'Đã gửi lệnh in');
                      }
                    },
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: _showSearch
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.black87),
                cursorColor: Colors.black87,
                decoration: const InputDecoration(
                  hintText: 'Tìm theo mã đơn, khách hàng, model...',
                  hintStyle: TextStyle(color: Colors.black45),
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Đơn sửa chữa'),
        actions: [
          if (_showSearch)
            IconButton(
              key: _filterBtnKey,
              icon: Icon(
                Icons.filter_list,
                color: (_statusFilter.isEmpty && _filterMonth == null && _filterYear == null)
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
              tooltip: 'Lọc theo trạng thái, tháng, năm',
              onPressed: _showStatusFilterMenu,
            ),
          IconButton(
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchCtrl.clear();
                _statusFilter.clear();
                _filterMonth = null;
                _filterYear = null;
              }
            }),
          ),
          const NotificationBell(),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_selectedIds.isNotEmpty) _buildSelectionBar(),
          Expanded(
            child: RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: _customersController!.stream,
        builder: (context, customerRows) {
          final customerNames = {
            for (final c in customerRows) c['id'] as String: (c['name'] ?? '') as String,
          };
          final customerPhones = {
            for (final c in customerRows) c['id'] as String: (c['phone'] ?? '') as String,
          };
          return RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: _ordersController.stream,
        builder: (context, allRows) {
          _latestRows = allRows;
          WidgetsBinding.instance.addPostFrameCallback((_) => _checkAgingAlerts(allRows));
          var rows = allRows.where((r) => r['deleted_at'] == null).toList();
          if (widget.technicianId != null) {
            rows = rows.where((r) => r['technician_id'] == widget.technicianId).toList();
          }
          final q = _searchCtrl.text.trim().toLowerCase();
          if (q.isNotEmpty) {
            rows = rows.where((r) =>
                (r['code'] ?? '').toString().toLowerCase().contains(q) ||
                (r['device_model'] ?? '').toString().toLowerCase().contains(q) ||
                (customerNames[r['customer_id']] ?? '').toLowerCase().contains(q)).toList();
          }
          if (_statusFilter.isNotEmpty) {
            rows = rows.where((r) => _statusFilter.contains(r['status'])).toList();
          }
          if (_filterMonth != null || _filterYear != null) {
            rows = rows.where((r) {
              final received = DateTime.tryParse(r['received_at']?.toString() ?? '');
              if (received == null) return false;
              if (_filterYear != null && received.year != _filterYear) return false;
              if (_filterMonth != null && received.month != _filterMonth) return false;
              return true;
            }).toList();
          }
          if (rows.isEmpty) {
            return const Center(child: Text('Chưa có đơn sửa chữa nào.'));
          }

          // Nhóm theo ngày tạo đơn (received_at) — rows đã được sắp xếp mới
          // nhất trước từ query nên nhóm cũng tự động theo thứ tự đó.
          // Nếu bật sắp xếp theo ngày thanh toán: nhóm "Chưa thanh toán" = các
          // máy ĐÃ TRẢ (status delivered) còn nợ, lên trên cùng; đơn đã thu đủ
          // nhóm theo ngày thanh toán; đơn chưa trả máy xếp riêng cuối danh sách.
          final groups = <String, List<RepairOrder>>{};
          final sortedRows = List<Map<String, dynamic>>.from(rows);
          int paidBucket(Map<String, dynamic> r) {
            if (r['status'] != 'delivered') return 2;
            return r['payment_method'] == 'debt' ? 0 : 1;
          }
          if (_sortByPaidDate) {
            sortedRows.sort((a, b) {
              final ba = paidBucket(a), bb = paidBucket(b);
              if (ba != bb) return ba - bb;
              if (ba == 1) {
                final da = DateTime.tryParse(a['paid_at']?.toString() ?? '') ??
                    DateTime.tryParse(a['received_at']?.toString() ?? '');
                final db = DateTime.tryParse(b['paid_at']?.toString() ?? '') ??
                    DateTime.tryParse(b['received_at']?.toString() ?? '');
                if (da != null && db != null) return db.compareTo(da);
              }
              return 0;
            });
          }
          for (final r in sortedRows) {
            final order = RepairOrder.fromMap(r);
            final String dateKey;
            if (_sortByPaidDate) {
              if (order.status == 'delivered' && order.paymentMethod == 'debt') {
                dateKey = 'Chưa thanh toán';
              } else if (order.status == 'delivered') {
                dateKey = _dateFmt.format(order.paidAt ?? order.deliveredAt ?? order.receivedAt);
              } else {
                dateKey = 'Chưa trả máy';
              }
            } else {
              dateKey = _dateFmt.format(order.receivedAt);
            }
            groups.putIfAbsent(dateKey, () => []).add(order);
          }

          return RefreshIndicator(
            onRefresh: _reloadOrders,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 96),
              children: [
                for (final entry in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        InkWell(
                          onTap: () => setState(() => _sortByPaidDate = !_sortByPaidDate),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _sortByPaidDate
                                      ? (entry.key == 'Chưa thanh toán' || entry.key == 'Chưa trả máy'
                                          ? entry.key
                                           : 'Ngày TT: ${entry.key}')
                                       : 'Ngày tạo: ${entry.key}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF2563EB)),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _sortByPaidDate ? Icons.arrow_downward : Icons.swap_vert,
                                  size: 13,
                                  color: const Color(0xFF2563EB),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'Thu: ${_currency.format(_dayRevenue(entry.value))}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Color(0xFF16A34A)),
                            ),
                            Text(
                              'Tổng số đơn: ${entry.value.length}',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  for (final order in entry.value)
                    _buildOrderTile(
                      order,
                      customerNames[order.customerId] ?? '',
                      customerPhones[order.customerId] ?? '',
                    ),
                ],
              ],
            ),
          );
        },
          );
        },
        ),
      ),
      ],
    ),
      floatingActionButton: _selectedIds.isEmpty
          ? FloatingActionButton.extended(
              heroTag: 'repair_orders_fab',
              onPressed: () => _showReceiveOrEditDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Tiếp nhận đơn'),
            )
          : null,
    );
  }

  /// Tổng doanh thu của 1 ngày (nhóm theo ngày tạo đơn): chỉ tính các đơn đã
  /// trả máy và đã thu tiền (bỏ qua đơn ghi nợ).
  num _dayRevenue(List<RepairOrder> orders) {
    num total = 0;
    for (final o in orders) {
      if (o.status != 'delivered' || o.paymentMethod == 'debt') continue;
      total += o.finalCost > 0 ? o.finalCost : o.estimatedCost;
    }
    return total;
  }

  Widget _buildOrderTile(RepairOrder order, String customerName, String customerPhone) {
    final selected = _selectedIds.contains(order.id);
    final isComplete = order.status == 'delivered' || order.status == 'cancelled';
    final displayPrice = order.finalCost > 0 ? order.finalCost : order.estimatedCost;
    final Color priceColor;
    if (order.status == 'cancelled') {
      priceColor = const Color(0xFFDC2626); // đỏ: khách không sửa
    } else if (order.status == 'delivered') {
      // cam: đã trả máy nhưng GHI NỢ (chưa thu được tiền); xanh: đã thu đủ.
      priceColor = order.paymentMethod == 'debt'
          ? const Color(0xFFF97316)
          : const Color(0xFF16A34A);
    } else {
      priceColor = Colors.black45; // xám: chưa trả máy
    }

    // Hàng 1: mã phiếu (tô màu cảnh báo nếu ì lâu) . tên khách — to, đậm.
    final restParts = [
      if (customerName.isNotEmpty) customerName,
    ];
    final line1Rest = restParts.isEmpty ? '' : ' · ${restParts.join(' · ')}';
    final agingColor = _agingCodeColor(order);

    // Hàng 2: model . lỗi . ghi chú — nhỏ, tự rút gọn "..." nếu dài.
    final line2Parts = [
      if ((order.deviceModel ?? '').isNotEmpty) order.deviceModel!,
      if ((order.issueDescription ?? '').isNotEmpty) order.issueDescription!,
      if ((order.note ?? '').isNotEmpty) order.note!,
    ];
    final line2 = line2Parts.join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: selected ? const Color(0xFFDCEBFF) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isComplete
            ? () => _openCompleteOrderDialog(order, customerName, customerPhone)
            : () => _showReceiveOrEditDialog(editing: order),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleSelect(order.id),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: selected
                      ? const Color(0xFF2563EB)
                      : isComplete
                          ? (order.status == 'delivered'
                              ? const Color(0xFF16A34A)
                              : const Color(0xFFDC2626))
                          : null,
                  child: Icon(
                    selected
                        ? Icons.check
                        : isComplete
                            ? (order.status == 'delivered'
                                ? Icons.check_rounded
                                : Icons.close_rounded)
                            : Icons.build_rounded,
                    size: 18,
                    color: selected
                        ? Colors.white
                        : isComplete
                            ? Colors.white
                            : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hàng 1: chữ to, đậm + trạng thái ở cuối hàng.
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: order.code,
                                  style: TextStyle(color: agingColor ?? Colors.black87),
                                ),
                                TextSpan(text: line1Rest, style: const TextStyle(color: Colors.black87)),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: Platform.isAndroid ? 14 : 15),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: order.status == 'delivered' || order.status == 'cancelled'
                              ? null
                              : (details) => _showQuickStatusMenu(order, details.globalPosition),
                          child: StatusChip(status: order.status, dense: true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: line2.isNotEmpty
                              ? Text(
                                  line2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: Platform.isAndroid ? 11 : 12, color: Colors.black54),
                                )
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Đơn mới tiếp nhận / đang sửa: bấm giá để sửa nhanh.
                          onTap: (order.status == 'received' || order.status == 'repairing')
                              ? () => _showQuickPriceDialog(order)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (order.paymentMethod == 'transfer')
                                  Icon(Icons.account_balance, size: 14, color: priceColor)
                                else if (order.paymentMethod == 'cash')
                                  Icon(Icons.payments, size: 14, color: priceColor),
                                const SizedBox(width: 3),
                                Text(
                                  _currency.format(displayPrice),
                                  style: TextStyle(fontSize: Platform.isAndroid ? 11 : 12, fontWeight: FontWeight.w700, color: priceColor),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Popup sửa nhanh giá tiền cho đơn đang "tiếp nhận" / "đang sửa".
  /// Ô nhập giá có viền cam nổi bật kèm hiển thị giá hiện tại để dễ nhận biết.
  Future<void> _showQuickPriceDialog(RepairOrder order) async {
    final editingFinal = order.finalCost > 0;
    final current = order.finalCost > 0 ? order.finalCost : order.estimatedCost;
    final ctrl = TextEditingController(text: current > 0 ? current.toStringAsFixed(0) : '');
    String? error;
    var saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: Text(editingFinal ? 'Sửa giá chốt' : 'Sửa giá tiền'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Banner giá hiện tại — nổi bật để biết đang sửa từ số nào.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                border: Border.all(color: const Color(0xFFF97316), width: 1.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Giá hiện tại: ${_currency.format(current)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF9A3412)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFFC2410C)),
              decoration: InputDecoration(
                labelText: 'Giá mới',
                suffixText: 'đ',
                filled: true,
                fillColor: const Color(0xFFFFF7ED),
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0xFFF97316), width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0xFFF97316), width: 2.5),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: saving ? null : () async {
                final v = num.tryParse(ctrl.text.trim());
                if (v == null || v <= 0) {
                  setStateDialog(() => error = 'Nhập giá tiền hợp lệ.');
                  return;
                }
                setStateDialog(() { saving = true; error = null; });
                try {
                  await SupabaseService.client.from('repair_orders').update({
                    editingFinal ? 'final_cost' : 'estimated_cost': v,
                  }).eq('id', order.id);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; });
                }
              },
              child: saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar() {
    final rows = _latestRows.where((r) => _selectedIds.contains(r['id'])).toList();
    final orders = rows.map((r) => RepairOrder.fromMap(r)).toList();
    final isSingle = orders.length == 1;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2))],
      ),
        child: Row(
          children: [
            IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
            Text('${orders.length} đã chọn', style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (isSingle)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Sửa',
                onPressed: orders.isEmpty ? null : () => _showReceiveOrEditDialog(editing: orders.first),
              ),
            IconButton(
              icon: const Icon(Icons.sync_alt_rounded),
              tooltip: 'Cập nhật trạng thái',
              onPressed: orders.isEmpty ? null : () => _showStatusUpdateDialog(orders),
            ),
            IconButton(
              icon: const Icon(Icons.print_outlined),
              tooltip: 'In',
              onPressed: orders.isEmpty ? null : () => _showPrintPreview(orders),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Xóa (thùng rác)',
              onPressed: orders.isEmpty ? null : () => _deleteOrders(orders),
            ),
          ],
        ),
      );
  }
}

/// Ô hiển thị/chụp 1 tấm ảnh thiết bị (mặt trước hoặc mặt sau).
class _PhotoSlot extends StatelessWidget {
  final String label;
  final Uint8List? bytes;
  final String? existingUrl;
  final VoidCallback onTap;
  final double height;

  const _PhotoSlot({
    required this.label,
    required this.bytes,
    required this.existingUrl,
    required this.onTap,
    this.height = 90,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (bytes != null) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(bytes!, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
      );
    } else if (existingUrl != null) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(existingUrl!, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
      );
    } else {
      content = Icon(Icons.camera_alt_outlined, color: Colors.grey, size: height * 0.35);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        const SizedBox(height: 2),
        GestureDetector(
          onTap: onTap,
          child: Container(
            height: height,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            child: content,
          ),
        ),
      ],
    );
  }
}

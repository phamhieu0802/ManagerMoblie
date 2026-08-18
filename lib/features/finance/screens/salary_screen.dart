import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:intl/intl.dart';
import 'package:file_selector/file_selector.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/app_toast.dart';
import '../../../core/supabase_service.dart';
import '../../../core/notify_helper.dart';
import '../../../core/error_utils.dart';
import '../../../widgets/realtime_stream_view.dart';
import 'salary_payment_detail_screen.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);
final _dateFmt = DateFormat('dd/MM/yyyy');

/// Doanh thu thực của một đơn: ưu tiên final_cost (giá chốt), fallback
/// estimated_cost khi đơn trả máy qua quick menu không có final_cost.
num _revOf(Map<String, dynamic> o) {
  final fc = (o['final_cost'] as num?) ?? 0;
  return fc > 0 ? fc : ((o['estimated_cost'] as num?) ?? 0);
}

/// Màn Lương KTV — hoa hồng KTV + báo cáo doanh thu S1A.
class SalaryScreen extends StatelessWidget {
  final Widget? appBarLeading;
  const SalaryScreen({super.key, this.appBarLeading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBarLeading,
        title: const Text('Lương KTV'),
      ),
      body: const SalaryView(),
    );
  }
}

class SalaryView extends StatefulWidget {
  const SalaryView({super.key});

  @override
  State<SalaryView> createState() => _SalaryViewState();
}

class _SalaryViewState extends State<SalaryView> {
  // ----- Phần lương hoa hồng -----
  // Chỉ chọn tháng + năm; _period.start = ngày 1 của tháng, _period.end = ngày 1 tháng sau.
  DateTimeRange _period = DateTimeRange(
    start: DateTime(DateTime.now().year, DateTime.now().month, 1),
    end: DateTime(DateTime.now().year, DateTime.now().month + 1, 1),
  );
  /// Danh sách employee_id đã có phiếu lương trong tháng đang chọn (chặn trả lần 2).
  final Set<String> _paidTechIds = {};
  List<Map<String, dynamic>> _techProfiles = [];
  bool _salaryLoading = false;
  Map<String, TechCommission> _computedCommissions = {};

  @override
  void initState() {
    super.initState();
    _loadTechProfiles();
  }

  Future<void> _loadTechProfiles() async {
    try {
      final profile = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', SupabaseService.currentUser?.id ?? '')
          .single();
      // Dùng select('*') để không bị lỗi nếu DB chưa có cột commission_type/commission_amount.
      final rows = await SupabaseService.client
          .from('profiles')
          .select('*')
          .eq('store_id', profile['store_id'])
          .inFilter('role', ['admin', 'receptionist', 'technician']);
      if (mounted) setState(() => _techProfiles = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {}
  }

  /// Nạp danh sách nhân viên đã có phiếu lương trong tháng đang chọn.
  Future<void> _loadPaidState(String storeId) async {
    try {
      final periodStart = _period.start.toIso8601String().split('T')[0];
      final rows = await SupabaseService.client
          .from('salary_payments')
          .select('employee_id')
          .eq('store_id', storeId)
          .eq('period_start', periodStart);
      if (!mounted) return;
      setState(() {
        _paidTechIds.clear();
        for (final r in rows as List) {
          _paidTechIds.add(r['employee_id'] as String);
        }
      });
    } catch (_) {}
  }

  Future<void> _computeCommissions() async {
    setState(() => _salaryLoading = true);
    try {
      // Nạp lại danh sách KTV + cơ chế/giá trị hoa hồng mới nhất từ DB
      // (có thể đã được sửa ở màn Nhân viên sau khi màn Lương mở).
      await _loadTechProfiles();

      final storeId = (await SupabaseService.client.from('profiles')
          .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];

      await _loadPaidState(storeId);

      final orders = await SupabaseService.client
          .from('repair_orders')
          .select('id, technician_id, repaired_by, received_by, final_cost, estimated_cost, status, delivered_at')
          .eq('store_id', storeId)
          .eq('status', 'delivered')
          .isFilter('deleted_at', null)
          .neq('payment_method', 'debt')
          .gte('delivered_at', _period.start.toIso8601String())
          .lt('delivered_at', _period.end.toIso8601String());

      final allOrders = List<Map<String, dynamic>>.from(orders as List);

      // Lấy chi phí linh kiện
      final orderIds = allOrders.map((o) => o['id'] as String).toList();
      Map<String, num> partsCost = {};
      if (orderIds.isNotEmpty) {
        final txRows = await SupabaseService.client
            .from('inventory_transactions')
            .select('repair_order_id, quantity, inventory_parts(unit_cost)')
            .eq('type', 'out')
            .inFilter('repair_order_id', orderIds);
        for (final r in txRows as List) {
          final oid = r['repair_order_id'] as String?;
          if (oid == null) continue;
          final unitCost = (r['inventory_parts'] as Map?)?['unit_cost'] as num? ?? 0;
          final qty = r['quantity'] as num? ?? 0;
          partsCost[oid] = (partsCost[oid] ?? 0) + (unitCost * qty);
        }
      }

      final result = <String, TechCommission>{};
      for (final tech in _techProfiles) {
        final techId = tech['id'] as String;
        final mech = tech['commission_type'] as String? ?? 'labor_fixed';
        final isLabor = mech == 'labor_fixed';
        final isReceptionist = tech['role'] == 'receptionist';

        // Ghi nhận máy theo vai trò:
        // - Lễ tân: máy họ tiếp nhận (received_by), tính 1 lần khi tạo đơn.
        // - KTV: máy được giao (technician_id) và đã trả máy (delivered);
        //   máy hoàn thành tính theo người thực sự sửa (repaired_by), fallback
        //   technician_id khi cột cũ để trống -> tránh double-count.
        final techOrders = allOrders.where((o) {
          final rb = o['repaired_by'] as String?;
          if (isReceptionist) return o['received_by'] == techId;
          return rb == techId || (rb == null && o['technician_id'] == techId);
        }).toList();

        final assignedCount = isReceptionist
            ? allOrders.where((o) => o['received_by'] == techId).length
            : allOrders.where((o) => o['technician_id'] == techId).length;

        num laborTotal = 0;
        num profitTotal = 0;
        for (final o in techOrders) {
          final fc = (o['final_cost'] as num?) ?? 0;
          final rev = fc > 0 ? fc : ((o['estimated_cost'] as num?) ?? 0);
          laborTotal += rev;
          profitTotal += rev - (partsCost[o['id']] ?? 0);
        }

        if (isLabor) {
          final amount = (tech['commission_amount'] as num?)?.toDouble();
          if (amount == null || amount <= 0) continue;
          result[techId] = TechCommission(
            laborTotal: laborTotal,
            profitTotal: profitTotal,
            orderCount: techOrders.length,
            assignedCount: assignedCount,
            completedCount: techOrders.length,
            laborAmount: amount,
            profitPct: 0,
          );
        } else {
          final rate = (tech['commission_rate'] as num?)?.toDouble();
          if (rate == null || rate <= 0) continue;
          result[techId] = TechCommission(
            laborTotal: laborTotal,
            profitTotal: profitTotal,
            orderCount: techOrders.length,
            assignedCount: assignedCount,
            completedCount: techOrders.length,
            laborAmount: 0,
            profitPct: rate,
          );
        }
      }
      if (mounted) setState(() { _computedCommissions = result; _salaryLoading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _salaryLoading = false);
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  Future<void> _paySalary(Map<String, dynamic> tech) async {
    final techId = tech['id'] as String;
    final fullName = tech['full_name'] as String? ?? '';
    final comm = _computedCommissions[techId];
    if (comm == null) return;
    if (_paidTechIds.contains(techId)) return;

    // Dùng đúng cơ chế đã cài trong mục Nhân viên, không hỏi lại lúc trả lương.
    final mechType = tech['commission_type'] as String? ?? 'labor_fixed';
    final isLabor = mechType == 'labor_fixed';
    final rate = isLabor ? comm.laborAmount : comm.profitPct;
    final total = isLabor ? comm.laborCommission : comm.profitCommission;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận'),
        content: Text(
          'Lập phiếu chi lương cho $fullName\n'
          '(${isLabor ? 'Tiền công ${_currency.format(comm.laborAmount)}/đơn × ${comm.orderCount} đơn' : '% lợi nhuận ${comm.profitPct.toStringAsFixed(0)}%'}): '
          '${_currency.format(total)}?',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Đồng ý')),
        ],
      ),
    );
    if (confirm != true) return;

    // Chọn hình thức thanh toán (Tiền mặt / Chuyển khoản).
    final payChoice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hình thức thanh toán'),
        content: Text(
          'Trả lương $fullName: ${_currency.format(total)}.\nThanh toán bằng?',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cash'), child: const Text('Tiền mặt')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'transfer'), child: const Text('Chuyển khoản')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
        ],
      ),
    );
    if (payChoice == null) return;

    try {
      final user = SupabaseService.currentUser;
      if (user == null) throw Exception('Chua dang nhap');
      final storeId = (await SupabaseService.client.from('profiles')
          .select('store_id').eq('id', user.id).single())['store_id'];

      // Kiểm tra lại 1 lần nữa để không trả lương 2 lần trong 1 tháng.
      final existing = await SupabaseService.client
          .from('salary_payments')
          .select('id')
          .eq('store_id', storeId)
          .eq('employee_id', techId)
          .eq('period_start', _period.start.toIso8601String().split('T')[0])
          .maybeSingle();
      if (existing != null) {
        if (mounted) {
          showToast(context, 'Tháng này đã trả lương rồi.', error: true);
        }
        _loadPaidState(storeId);
        return;
      }

      // Tìm/tạo tài khoản (két tiền mặt hoặc ngân hàng) tương ứng.
      final acctType = payChoice == 'cash' ? 'cash' : 'bank';
      final acct = await _ensureAccount(storeId, acctType);

      // Ghi phiếu lương TRƯỚC (commit): unique(store_id, employee_id, period_start)
      // sẽ chặn trả 2 lần trước khi đụng đến tiền. Nếu phiếu lương không ghi được
      // thì không có khoản nào bị trừ — không lệch két.
      final salaryRow = await SupabaseService.client.from('salary_payments').insert({
        'store_id': storeId, 'employee_id': techId,
        'period_start': _period.start.toIso8601String().split('T')[0],
        'period_end': _period.end.toIso8601String().split('T')[0],
        'commission_type': isLabor ? 'labor_fixed' : 'profit_pct',
        'commission_rate': isLabor ? null : rate,
        'commission_amount': isLabor ? rate : null,
        'total_commission': total,
        'total_deductions': 0,
        'net_amount': total,
        'order_count': comm.orderCount,
        'assigned_count': comm.assignedCount,
        'completed_count': comm.completedCount,
        'labor_total': comm.laborTotal,
        'profit_total': comm.profitTotal,
        'pay_method': payChoice,
        'created_by': user.id,
      }).select('id').single();
      final salaryId = salaryRow['id'] as String;

      String? txId;
      try {
        final tx = await SupabaseService.client.from('transactions').insert({
          'store_id': storeId, 'type': 'expense', 'category': 'Lương KTV',
          'amount': total, 'description': 'Lương $fullName (${_monthLabel()})',
          'created_by': user.id, if (acct != null) 'account_id': acct['id'],
          'transaction_date': DateTime.now().toIso8601String(),
        }).select('id').single();
        txId = tx['id'] as String;

        // Trừ số dư tài khoản tương ứng.
        if (acct != null) {
          await SupabaseService.client.from('cash_accounts')
              .update({'balance': ((acct['balance'] as num?) ?? 0) - total})
              .eq('id', acct['id']);
        }
      } catch (e) {
        // Ghi chi / trừ két thất bại -> gỡ phiếu lương vừa tạo để không có
        // phiếu "đã trả lương" mà tiền không hề rời két.
        try {
          await SupabaseService.client.from('salary_payments').delete().eq('id', salaryId);
        } catch (_) {}
        rethrow;
      }

      await SupabaseService.client.from('salary_payments')
          .update({'transaction_id': txId}).eq('id', salaryId);

      // Push thông báo cho nhân viên + toàn bộ admin.
      await notifyEmployeeAndAdmins(
        storeId: storeId,
        userId: techId,
        title: 'Đã trả lương tháng ${_monthLabel()}',
        body: 'Lương $fullName: ${_currency.format(total)} · ${payChoice == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'}',
        data: {'transaction_id': txId, 'employee_id': techId, 'salary': true},
      );

      if (mounted) {
        showToast(context, 'Đã trả lương $fullName: ${_currency.format(total)} (${payChoice == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'})');
        _computeCommissions();
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  String _monthLabel() {
    final m = _period.start.month.toString().padLeft(2, '0');
    return '${m}/${_period.start.year}';
  }

  /// Tìm tài khoản theo loại (cash/bank); không có thì tự tạo mới.
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSalarySection(),
      ],
    );
  }

  Widget _buildSalarySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Lương & hoa hồng', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _showMonthPicker,
              icon: const Icon(Icons.calendar_month, size: 16),
              label: Text('Tháng ${_monthLabel()}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: ElevatedButton.icon(
              onPressed: _salaryLoading ? null : _computeCommissions,
              icon: _salaryLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.calculate, size: 18),
              label: const Text('Tính'),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        if (_techProfiles.isEmpty)
          const Center(child: Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text('Chưa có KTV nào được cài % hoa hồng.', style: TextStyle(color: Colors.black54)),
          )),
        for (final tech in _techProfiles) ...[
          Builder(
            builder: (ctx) {
              final action = _buildCommissionAction(tech);
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: const CircleAvatar(
                    child: Icon(Icons.engineering, size: 18),
                  ),
                  title: Text(tech['full_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: _buildCommissionSubtitle(tech['id'] as String),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (action != null) action,
                      const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
                    ],
                  ),
                  onTap: () => _showTechDetail(tech),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 20),
        const SalaryHistorySection(),
      ],
    );
  }

  Widget? _buildCommissionSubtitle(String techId) {
    final comm = _computedCommissions[techId];
    if (comm == null) return const Text('Bấm "Tính" để xem hoa hồng', style: TextStyle(fontSize: 11));
    final isLabor = comm.laborAmount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Được giao: ${comm.assignedCount} · Hoàn thành: ${comm.completedCount}', style: const TextStyle(fontSize: 11)),
        Text('Doanh thu: ${_currency.format(comm.laborTotal)}', style: const TextStyle(fontSize: 11)),
        Text('Lợi nhuận: ${_currency.format(comm.profitTotal)}', style: const TextStyle(fontSize: 11)),
        if (isLabor)
          Text('Tiền công ${_currency.format(comm.laborAmount)}/đơn: ${_currency.format(comm.laborCommission)}',
              style: const TextStyle(fontSize: 11, color: Colors.green))
        else
          Text('% LN (${comm.profitPct.toStringAsFixed(0)}%): ${_currency.format(comm.profitCommission)}',
              style: const TextStyle(fontSize: 11, color: Colors.green)),
      ],
    );
  }

  Widget? _buildCommissionAction(Map<String, dynamic> tech) {
    final techId = tech['id'] as String;
    final comm = _computedCommissions[techId];
    if (comm == null || (comm.laborCommission <= 0 && comm.profitCommission <= 0)) return null;
    if (_paidTechIds.contains(techId)) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 14, color: Colors.green),
            SizedBox(width: 4),
            Text('Đã trả lương', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    return TextButton(
      onPressed: () => _paySalary(tech),
      style: TextButton.styleFrom(foregroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 8)),
      child: const Text('Trả lương', style: TextStyle(fontSize: 12)),
    );
  }

  void _showTechDetail(Map<String, dynamic> tech) {
    final techId = tech['id'] as String;
    final fullName = tech['full_name'] as String? ?? '';
    final comm = _computedCommissions[techId];
    final isPaid = _paidTechIds.contains(techId);
    final mechType = tech['commission_type'] as String? ?? 'labor_fixed';
    final isLabor = mechType == 'labor_fixed';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF1D4ED8),
              child: Text(fullName.isNotEmpty ? fullName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(fullName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(isLabor ? 'Hoa hồng: Tiền công' : 'Hoa hồng: % Lợi nhuận',
                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
        content: comm == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: Text('Chưa tính hoa hồng.\nBấm "Tính" trên màn hình lương.', textAlign: TextAlign.center, style: TextStyle(color: Colors.black54))),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _detailRow(Icons.assignment, 'Đơn được giao', '${comm.assignedCount}'),
                  _detailRow(Icons.check_circle_outline, 'Đơn hoàn thành', '${comm.completedCount}'),
                  const Divider(height: 16),
                  _detailRow(Icons.attach_money, 'Doanh thu', _currency.format(comm.laborTotal)),
                  _detailRow(Icons.account_balance_wallet, 'Chi phí linh kiện', _currency.format(comm.laborTotal - comm.profitTotal)),
                  _detailRow(Icons.trending_up, 'Lợi nhuận', _currency.format(comm.profitTotal), valueColor: comm.profitTotal > 0 ? Colors.green : Colors.red),
                  const Divider(height: 16),
                  if (isLabor)
                    _detailRow(Icons.monetization_on, 'Tiền công / đơn', _currency.format(comm.laborAmount)),
                  if (!isLabor)
                    _detailRow(Icons.percent, 'Tỷ lệ hoa hồng', '${comm.profitPct.toStringAsFixed(0)}%'),
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1D4ED8).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Tổng hoa hồng', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(_currency.format(isLabor ? comm.laborCommission : comm.profitCommission),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF1D4ED8))),
                      ],
                    ),
                  ),
                ],
              ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
          if (!isPaid && comm != null && (comm.laborCommission > 0 || comm.profitCommission > 0))
            ElevatedButton.icon(
              icon: const Icon(Icons.payments, size: 16),
              label: const Text('Trả lương'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(ctx);
                _paySalary(tech);
              },
            ),
          if (isPaid)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.green.shade300),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, size: 14, color: Colors.green),
                  SizedBox(width: 4),
                  Text('Đã trả', style: TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.black45),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: valueColor)),
        ],
      ),
    );
  }

  /// Chọn tháng + năm (không chọn ngày). Không cho chọn tháng tương lai.
  Future<void> _showMonthPicker() async {
    int year = _period.start.year;
    int month = _period.start.month;
    final now = DateTime.now();
    final picked = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Chọn tháng', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => setDialogState(() => year--),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('$year', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    IconButton(
                      onPressed: () => setDialogState(() => year++),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.6,
                  children: [
                    for (var m = 1; m <= 12; m++)
                      OutlinedButton(
                        onPressed: year > now.year || (year == now.year && m > now.month)
                            ? null
                            : () => Navigator.pop(ctx, (year, m)),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: (m == month && year == _period.start.year)
                              ? const Color(0xFF1D4ED8)
                              : null,
                          foregroundColor: (m == month && year == _period.start.year)
                              ? Colors.white
                              : (year > now.year || (year == now.year && m > now.month)
                                  ? Colors.black26
                                  : null),
                          padding: EdgeInsets.zero,
                        ),
                        child: Text('$m', style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ],
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _period = DateTimeRange(
          start: DateTime(picked.$1, picked.$2, 1),
          end: DateTime(picked.$1, picked.$2 + 1, 1),
        );
        _paidTechIds.clear();
      });
    }
  }
}

class TechCommission {
  final num laborTotal;
  final num profitTotal;
  final int orderCount;

  /// Số máy được giao (lễ tân: received_by; KTV: technician_id).
  final int assignedCount;

  /// Số máy hoàn thành (người thực sự sửa, đã trả máy).
  final int completedCount;

  /// Số tiền nhận trên 1 đơn (VNĐ), dùng khi cơ chế 'labor_fixed'.
  final double laborAmount;

  /// % lợi nhuận của 1 đơn, dùng khi cơ chế 'profit_pct'.
  final double profitPct;

  TechCommission({
    required this.laborTotal,
    required this.profitTotal,
    required this.orderCount,
    required this.assignedCount,
    required this.completedCount,
    required this.laborAmount,
    required this.profitPct,
  });

  num get laborCommission => laborAmount * orderCount;
  num get profitCommission => profitTotal > 0 ? profitTotal * profitPct / 100 : 0;
}

// =====================================================================
// BÁO CÁO S1A
// =====================================================================
class ReportSection extends StatefulWidget {
  const ReportSection({super.key});

  @override
  State<ReportSection> createState() => _ReportSectionState();
}

class _ReportSectionState extends State<ReportSection> {
  int _year = DateTime.now().year;
  int? _month;
  bool _groupByDay = false;
  List<Map<String, dynamic>> _orders = [];
  bool _loading = false;
  Map<String, dynamic>? _storeInfo;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    _loadStoreInfo();
    _fetchData();
  }

  Future<void> _loadStoreInfo() async {
    try {
      final profile = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', SupabaseService.currentUser?.id ?? '')
          .single();
      final store = await SupabaseService.client
          .from('stores')
          .select('name, address, phone, tax_code')
          .eq('id', profile['store_id'])
          .single();
      _storeInfo = Map<String, dynamic>.from(store);
    } catch (_) {}
  }

  Future<void> _fetchData() async {
    setState(() => _loading = true);
    try {
      final profile = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', SupabaseService.currentUser?.id ?? '')
          .single();
      final storeId = profile['store_id'];

      dynamic query = SupabaseService.client
          .from('repair_orders')
          .select('code, delivered_at, estimated_cost, final_cost, payment_method, status')
          .eq('store_id', storeId)
          .eq('status', 'delivered')
          .isFilter('deleted_at', null)
          .neq('payment_method', 'debt');

      if (_month != null) {
        final from = DateTime(_year, _month!, 1);
        final to = DateTime(_year, _month! + 1, 1);
        query = query
            .gte('delivered_at', from.toIso8601String())
            .lt('delivered_at', to.toIso8601String());
      } else {
        final from = DateTime(_year, 1, 1);
        final to = DateTime(_year + 1, 1, 1);
        query = query
            .gte('delivered_at', from.toIso8601String())
            .lt('delivered_at', to.toIso8601String());
      }

      query = query.order('delivered_at', ascending: true);

      final rows = await query;

      final orderList = (rows as List).map((r) => <String, dynamic>{
        'code': r['code'],
        'delivered_at': r['delivered_at'],
        'final_cost': r['final_cost'],
        'estimated_cost': r['estimated_cost'],
        'payment_method': r['payment_method'],
      }).toList();

      setState(() {
        _orders = orderList;
        _statusText = '${_orders.length} đơn đã trả máy';
      });
    } catch (e) {
      _statusText = 'Lỗi: ${friendlyError(e)}';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _exportPdf() async {
    if (_orders.isEmpty) {
      if (mounted) showToast(context, 'Không có dữ liệu để xuất');
      return;
    }

    // Đảm bảo đã load thông tin cửa hàng
    if (_storeInfo == null) {
      try {
        final profile = await SupabaseService.client
            .from('profiles')
            .select('store_id')
            .eq('id', SupabaseService.currentUser?.id ?? '')
            .single();
        final store = await SupabaseService.client
            .from('stores')
            .select('name, address, phone, tax_code')
            .eq('id', profile['store_id'])
            .single();
        _storeInfo = Map<String, dynamic>.from(store);
      } catch (e) {
        if (mounted) showToast(context, 'Không thể tải thông tin cửa hàng: ${friendlyError(e)}', error: true);
        return;
      }
    }

    try {
      final pdf = pw.Document();
      final font = await _loadFont();
      final bold = await _loadBoldFont();

      final monthlyGroups = _groupOrdersByMonth();

      for (final entry in monthlyGroups.entries) {
        final monthOrders = entry.value;
        if (monthOrders.isEmpty) continue;
        final period = 'Tháng ${entry.key} năm $_year';
        pdf.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(40),
            build: (ctx) => _buildPdfPage(font, bold, monthOrders, period),
          ),
        );
      }

      final fileName = 'S1A_${_year}${_month != null ? '_${_month!.toString().padLeft(2, '0')}' : ''}.pdf';

      if (Platform.isAndroid) {
        const channel = MethodChannel('com.phonerepair.phone_repair_shop/save_file');
        final saved = await channel.invokeMethod<String>('savePdf', {
          'bytes': await pdf.save(),
          'fileName': fileName,
        });
        if (!mounted) return;
        if (saved == null) {
          showToast(context, 'Đã hủy xuất PDF');
          return;
        }
        showToast(context, 'Đã xuất: $saved');
        return;
      }

      final initialDir = '${Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Public'}\\Desktop';

      final saveLocation = await getSaveLocation(
        acceptedTypeGroups: const [XTypeGroup(label: 'PDF', extensions: ['pdf'])],
        suggestedName: fileName,
        initialDirectory: initialDir,
      );
      if (saveLocation == null) {
        if (mounted) showToast(context, 'Đã hủy xuất PDF');
        return;
      }

      final file = File(saveLocation.path);
      await file.writeAsBytes(await pdf.save());
      if (mounted) showToast(context, 'Đã xuất: ${saveLocation.path}');
    } catch (e) {
      if (mounted) showToast(context, 'Lỗi xuất PDF: ${friendlyError(e)}', error: true);
    }
  }

  Map<int, List<Map<String, dynamic>>> _groupOrdersByMonth() {
    final result = <int, List<Map<String, dynamic>>>{};
    for (final o in _orders) {
      final dt = DateTime.tryParse(o['delivered_at'] ?? '');
      if (dt == null) continue;
      // Nếu chọn tháng cụ thể thì chỉ lấy tháng đó
      if (_month != null && dt.month != _month) continue;
      result.putIfAbsent(dt.month, () => []).add(o);
    }
    return result;
  }

  Future<pw.Font> _loadFont() async {
    try {
      final regular = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      return pw.Font.ttf(regular);
    } catch (_) {
      return pw.Font.courier();
    }
  }

  Future<pw.Font> _loadBoldFont() async {
    try {
      final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
      return pw.Font.ttf(bold);
    } catch (_) {
      return pw.Font.courierBold();
    }
  }

  List<pw.Widget> _buildPdfPage(pw.Font font, pw.Font bold, List<Map<String, dynamic>> orders, String period) {
    final style = pw.TextStyle(font: font, fontSize: 9);
    final boldStyle = pw.TextStyle(font: bold, fontSize: 9);
    final titleStyle = pw.TextStyle(font: bold, fontSize: 13);
    final smallStyle = pw.TextStyle(font: font, fontSize: 7);

    final storeName = _storeInfo?['name'] as String? ?? '.............................';
    final storeAddress = _storeInfo?['address'] as String? ?? '.............................................';
    final taxCode = _storeInfo?['tax_code'] as String? ?? '........................................';

    final rows = <pw.Widget>[
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(flex: 3, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('HỘ, CÁ NHÂN KINH DOANH: $storeName', style: boldStyle),
          pw.SizedBox(height: 2),
          pw.Text('Địa chỉ: $storeAddress', style: boldStyle),
          pw.SizedBox(height: 2),
          pw.Text('Mã số thuế: $taxCode', style: boldStyle),
        ])),
        pw.SizedBox(width: 8),
        pw.Expanded(flex: 2, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('Mẫu số S1a-HKD', style: pw.TextStyle(font: bold, fontSize: 11, color: PdfColors.black), textAlign: pw.TextAlign.right),
          pw.SizedBox(height: 2),
          pw.Text('(Kèm theo Thông tư số 152/2025/TT-BTC',
              style: smallStyle, textAlign: pw.TextAlign.right),
          pw.Text('ngày 31 tháng 12 năm 2025',
              style: smallStyle, textAlign: pw.TextAlign.right),
          pw.Text('của Bộ trưởng Bộ Tài chính)',
              style: smallStyle, textAlign: pw.TextAlign.right),
        ])),
      ]),
      pw.SizedBox(height: 12),
      pw.Center(child: pw.Text('SỔ CHI TIẾT DOANH THU BÁN HÀNG HÓA, DỊCH VỤ', style: titleStyle)),
      pw.SizedBox(height: 4),
      pw.Center(child: pw.Text('Địa điểm kinh doanh: $storeAddress', style: style)),
      pw.SizedBox(height: 2),
      pw.Center(child: pw.Text('Kỳ kê khai: $period', style: style)),
      pw.SizedBox(height: 10),
    ];

    if (_groupByDay) {
      rows.add(_buildGroupedPdfTable(font, bold, orders));
    } else {
      rows.add(_buildDetailedPdfTable(font, bold, orders));
    }

    rows.add(pw.SizedBox(height: 30));
    rows.add(pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.Text('Ngày ......... tháng ......... năm .........', style: style),
        pw.SizedBox(height: 6),
        pw.Text('NGƯỜI ĐẠI DIỆN HỘ KINH DOANH/CÁ NHÂN KINH DOANH',
            style: pw.TextStyle(font: bold, fontSize: 10)),
        pw.Text('(Ký, ghi rõ họ tên, đóng dấu (nếu có))', style: smallStyle),
      ]),
    ]));

    return rows;
  }

  pw.Widget _buildDetailedPdfTable(pw.Font font, pw.Font bold, List<Map<String, dynamic>> orders) {
    final style = pw.TextStyle(font: font, fontSize: 8);
    final boldStyle = pw.TextStyle(font: bold, fontSize: 8);
    final border = pw.TableBorder.all(color: PdfColors.black, width: 0.5);

    pw.Widget hCell(String text) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Text(text, style: boldStyle, textAlign: pw.TextAlign.center),
    );

    pw.Widget dCell(String text, {pw.TextAlign align = pw.TextAlign.center}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: pw.Text(text, style: style, textAlign: align),
    );

    final tableRows = <pw.TableRow>[
      pw.TableRow(children: [hCell('Ngày tháng'), hCell('Diễn giải'), hCell('Số tiền')]),
      pw.TableRow(children: [hCell('A'), hCell('B'), hCell('1')]),
    ];

    num total = 0;
    for (final o in orders) {
      final date = o['delivered_at'] != null
          ? _dateFmt.format(DateTime.tryParse(o['delivered_at']) ?? DateTime.now())
          : '';
      final amount = _revOf(o);
      total += amount;
      final desc = 'Thu tiền sửa chữa ${o['code'] ?? ''}';
      tableRows.add(pw.TableRow(children: [
        dCell(date),
        dCell(desc, align: pw.TextAlign.left),
        dCell(_fmtPdfMoney(amount), align: pw.TextAlign.right),
      ]));
    }

    tableRows.add(pw.TableRow(children: [
      dCell(''),
      dCell('Tổng cộng', align: pw.TextAlign.center),
      dCell(_fmtPdfMoney(total), align: pw.TextAlign.right),
    ]));

    return pw.Table(border: border, columnWidths: {
      0: const pw.FlexColumnWidth(1),
      1: const pw.FlexColumnWidth(5),
      2: const pw.FlexColumnWidth(3),
    }, children: tableRows);
  }

  pw.Widget _buildGroupedPdfTable(pw.Font font, pw.Font bold, List<Map<String, dynamic>> orders) {
    final style = pw.TextStyle(font: font, fontSize: 8);
    final boldStyle = pw.TextStyle(font: bold, fontSize: 8);
    final border = pw.TableBorder.all(color: PdfColors.black, width: 0.5);

    pw.Widget hCell(String text) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Text(text, style: boldStyle, textAlign: pw.TextAlign.center),
    );

    pw.Widget dCell(String text, {pw.TextAlign align = pw.TextAlign.center}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: pw.Text(text, style: style, textAlign: align),
    );

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final o in orders) {
      final key = o['delivered_at'] != null
          ? _dateFmt.format(DateTime.tryParse(o['delivered_at']) ?? DateTime.now())
          : 'Không rõ';
      grouped.putIfAbsent(key, () => []).add(o);
    }

    final tableRows = <pw.TableRow>[
      pw.TableRow(children: [hCell('Ngày tháng'), hCell('Diễn giải'), hCell('Số tiền')]),
      pw.TableRow(children: [hCell('A'), hCell('B'), hCell('1')]),
    ];

    num grandTotal = 0;
    for (final entry in grouped.entries) {
      final dayTotal = entry.value.fold<num>(0, (s, o) => s + _revOf(o));
      grandTotal += dayTotal;
      final desc = 'Thu tiền sửa chữa (${entry.value.length} phiếu)';
      tableRows.add(pw.TableRow(children: [
        dCell(entry.key),
        dCell(desc, align: pw.TextAlign.left),
        dCell(_fmtPdfMoney(dayTotal), align: pw.TextAlign.right),
      ]));
    }

    tableRows.add(pw.TableRow(children: [
      dCell(''),
      dCell('Tổng cộng', align: pw.TextAlign.center),
      dCell(_fmtPdfMoney(grandTotal), align: pw.TextAlign.right),
    ]));

    return pw.Table(border: border, columnWidths: {
      0: const pw.FlexColumnWidth(1),
      1: const pw.FlexColumnWidth(5),
      2: const pw.FlexColumnWidth(3),
    }, children: tableRows);
  }

  String _fmtPdfMoney(num n) {
    if (n == 0) return '0';
    final s = n.toStringAsFixed(0);
    final parts = <String>[];
    for (int i = s.length; i > 0; i -= 3) {
      parts.insert(0, s.substring(i > 3 ? i - 3 : 0, i));
    }
    return '${parts.join('.')}₫';
  }

  @override
  Widget build(BuildContext context) {
    final monthNames = [
      '', 'Tháng 1', 'Tháng 2', 'Tháng 3', 'Tháng 4', 'Tháng 5', 'Tháng 6',
      'Tháng 7', 'Tháng 8', 'Tháng 9', 'Tháng 10', 'Tháng 11', 'Tháng 12',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Báo cáo S1A', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: _year,
                decoration: const InputDecoration(labelText: 'Năm', isDense: true),
                items: List.generate(10, (i) => DateTime.now().year - 5 + i).map((y) =>
                  DropdownMenuItem(value: y, child: Text('$y')),
                ).toList(),
                onChanged: (v) {
                  if (v != null) {
                    _year = v;
                    _fetchData();
                  }
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<int?>(
                value: _month,
                decoration: const InputDecoration(labelText: 'Tháng', isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Cả năm')),
                  for (int m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text(monthNames[m])),
                ],
                onChanged: (v) {
                  _month = v;
                  _fetchData();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, label: Text('Từng hóa đơn')),
            ButtonSegment(value: true, label: Text('Gộp ngày')),
          ],
          selected: {_groupByDay},
          onSelectionChanged: (s) => setState(() => _groupByDay = s.first),
        ),
        const SizedBox(height: 8),
        Text(_statusText, style: TextStyle(color: Colors.black54, fontSize: 13)),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.picture_as_pdf, size: 18),
          label: const Text('Xuất PDF'),
          onPressed: _loading ? null : _exportPdf,
        ),
        if (_loading) ...[
          const SizedBox(height: 12),
          const Center(child: CircularProgressIndicator()),
        ],
        if (_orders.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Xem trước', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 4),
          _buildPreviewTable(),
        ],
      ],
    );
  }

  Widget _buildPreviewTable() {
    if (_groupByDay) return _buildGroupedPreview();
    return _buildDetailedPreview();
  }

  Widget _buildDetailedPreview() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 12,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 40,
        columns: const [
          DataColumn(label: Text('Ngày tháng', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
          DataColumn(label: Text('Diễn giải', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
          DataColumn(label: Text('Số tiền', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
        ],
        rows: _orders.map((o) {
          final date = o['delivered_at'] != null
              ? _dateFmt.format(DateTime.tryParse(o['delivered_at']) ?? DateTime.now())
              : '';
          final amount = _revOf(o);
      final desc = 'Thu tiền sửa chữa ${o['code'] ?? ''}';
          return DataRow(cells: [
            DataCell(Text(date, style: const TextStyle(fontSize: 11))),
            DataCell(Text(desc, style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis)),
            DataCell(Text('${_currency.format(amount)}', style: const TextStyle(fontSize: 11))),
          ]);
        }).toList(),
      ),
    );
  }

  Widget _buildGroupedPreview() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final o in _orders) {
      final key = o['delivered_at'] != null
          ? _dateFmt.format(DateTime.tryParse(o['delivered_at']) ?? DateTime.now())
          : 'Không rõ';
      grouped.putIfAbsent(key, () => []).add(o);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 12,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 40,
        columns: const [
          DataColumn(label: Text('Ngày tháng', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
          DataColumn(label: Text('Diễn giải', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
          DataColumn(label: Text('Số tiền', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
        ],
        rows: grouped.entries.map((e) {
          final dayTotal = e.value.fold<num>(0, (s, o) => s + _revOf(o));
          final desc = 'Thu tiền sửa chữa (${e.value.length} phiếu)';
          return DataRow(cells: [
            DataCell(Text(e.key, style: const TextStyle(fontSize: 11))),
            DataCell(Text(desc, style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis)),
            DataCell(Text('${_currency.format(dayTotal)}', style: const TextStyle(fontSize: 11))),
          ]);
        }).toList(),
      ),
    );
  }
}

class SalaryHistorySection extends StatefulWidget {
  /// Lọc theo [employeeId] (dùng cho KTV tự xem lương của mình).
  final String? employeeId;
  const SalaryHistorySection({super.key, this.employeeId});

  @override
  State<SalaryHistorySection> createState() => _SalaryHistorySectionState();
}

class _SalaryHistorySectionState extends State<SalaryHistorySection> {
  Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _loadNames();
  }

  Future<void> _loadNames() async {
    try {
      final profile = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', SupabaseService.currentUser?.id ?? '')
          .single();
      final rows = await SupabaseService.client
          .from('profiles')
          .select('id, full_name')
          .eq('store_id', profile['store_id']);
      if (!mounted) return;
      setState(() {
        _names = {
          for (final r in rows as List)
            if (r['id'] != null && r['full_name'] != null)
              r['id'] as String: r['full_name'] as String,
        };
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Lịch sử trả lương', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: autoReconnectStream(
            () => SupabaseService.client
                .from('salary_payments')
                .stream(primaryKey: ['id'])
                .order('created_at', ascending: false),
            label: 'salary_payments',
          ),
          builder: (context, rows) {
            final visible = widget.employeeId == null
                ? rows
                : rows.where((r) => r['employee_id'] == widget.employeeId).toList();
            if (visible.isEmpty) return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('Chưa có lịch sử.', style: TextStyle(color: Colors.black54))),
            );
            return Column(
              children: visible.take(20).map((s) {
                final empId = s['employee_id'] as String? ?? '';
                final name = _names[empId] ?? empId;
                final periodStart = DateTime.tryParse(s['period_start']?.toString() ?? '');
                final periodLabel = periodStart != null
                    ? 'Tháng ${periodStart.month.toString().padLeft(2, '0')}/${periodStart.year}'
                    : '';
                final payMethod = s['pay_method'] == 'transfer' ? 'Chuyển khoản' : 'Tiền mặt';
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.receipt, size: 18),
                    title: Text('$name — ${_currency.format(s['net_amount'] ?? 0)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    subtitle: Text('$periodLabel · $payMethod'
                        '${s['created_at'] != null ? ' · ${_dateFmt.format(DateTime.tryParse(s['created_at']) ?? DateTime.now())}' : ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SalaryPaymentDetailScreen(
                          payment: s,
                          employeeName: name,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

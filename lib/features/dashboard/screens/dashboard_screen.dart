import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/repair_order.dart';
import '../../../models/profile.dart';
import '../../auth/controllers/auth_controller.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/realtime_stream_view.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);
final _dateFmt = DateFormat('dd/MM/yyyy');
final _dayFmt = DateFormat('dd/MM');
const _monthNames = [
  'Tháng 1', 'Tháng 2', 'Tháng 3', 'Tháng 4', 'Tháng 5', 'Tháng 6',
  'Tháng 7', 'Tháng 8', 'Tháng 9', 'Tháng 10', 'Tháng 11', 'Tháng 12',
];

String _compactMoney(num v) {
  if (v.abs() >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
  return v.toStringAsFixed(0);
}

/// Dashboard: biểu đồ Thu/Chi/Lợi nhuận + danh sách tổng hợp + máy quá hạn.
class DashboardScreen extends ConsumerStatefulWidget {
  final String? technicianId;
  final Widget? appBarLeading;
  const DashboardScreen({super.key, this.technicianId, this.appBarLeading});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final Stream<List<Map<String, dynamic>>> _ordersStream;

  @override
  void initState() {
    super.initState();
    _ordersStream = autoReconnectStream(
      () => SupabaseService.client.from('repair_orders').stream(primaryKey: ['id']),
      label: 'dashboard_orders',
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileProvider).value;

    return Scaffold(
      appBar: AppBar(leading: widget.appBarLeading, title: const Text('Dashboard'), actions: const [NotificationBell(), SizedBox(width: 4)]),
      body: RealtimeStreamView<List<Map<String, dynamic>>>(
        stream: _ordersStream,
        builder: (context, orderRows) {
          final allOrders = orderRows
              .where((r) => r['deleted_at'] == null)
              .map((r) => RepairOrder.fromMap(r))
              .toList();
          final techId = widget.technicianId;
          final filteredOrders = techId != null
              ? allOrders.where((o) => o.technicianId == techId || o.repairedBy == techId).toList()
              : allOrders;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (profile != null)
                _ThuChiChartSection(currentProfile: profile),
              const SizedBox(height: 24),

              const Text('Máy chưa hoàn thành', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              const Text(
                'Đơn quá 5 ngày chưa trả máy (tính từ ngày tiếp nhận).',
                style: TextStyle(color: Colors.black45, fontSize: 11),
              ),
              const SizedBox(height: 8),
              _OverdueOrdersList(orders: filteredOrders),
            ],
          );
        },
      ),
    );
  }
}

// =====================================================================
// Aggregation helpers
// =====================================================================
class _MonthAgg {
  num income = 0;
  num expense = 0;
  final List<Map<String, dynamic>> incomeTx = [];
  final List<Map<String, dynamic>> expenseTx = [];
}

class _DayAgg {
  final DateTime date;
  num income = 0;
  num expense = 0;
  _DayAgg(this.date);
}

DateTime? _txDate(Map<String, dynamic> r) {
  return DateTime.tryParse(r['transaction_date']?.toString() ?? '') ??
      DateTime.tryParse(r['created_at']?.toString() ?? '');
}

/// Tổng hợp 1 dòng trong danh sách (tháng hoặc ngày).
class _SummaryRow {
  final String label;
  final num income;
  final num expense;
  final int incomeCount;
  final int expenseCount;
  final int salaryCount;
  final List<Map<String, dynamic>>? transactions;
  const _SummaryRow({
    required this.label,
    required this.income,
    required this.expense,
    this.incomeCount = 0,
    this.expenseCount = 0,
    this.salaryCount = 0,
    this.transactions,
  });
}

// =====================================================================
// Biểu đồ + danh sách Thu / Chi / Lợi nhuận
// =====================================================================
class _ThuChiChartSection extends StatefulWidget {
  final Profile currentProfile;
  const _ThuChiChartSection({required this.currentProfile});

  @override
  State<_ThuChiChartSection> createState() => _ThuChiChartSectionState();
}

class _ThuChiChartSectionState extends State<_ThuChiChartSection> {
  String? _targetTechId;
  String _targetLabel = 'Cửa hàng';
  late int _year;
  int? _selectedMonth;
  List<Map<String, dynamic>> _staffList = [];

  bool get _isTechnician => widget.currentProfile.role == UserRole.technician;

  @override
  void initState() {
    super.initState();
    _year = DateTime.now().year;
    _selectedMonth = DateTime.now().month;
    if (_isTechnician) {
      _targetTechId = widget.currentProfile.id;
      _targetLabel = widget.currentProfile.fullName;
    } else {
      _loadStaffList();
    }
  }

  Future<void> _loadStaffList() async {
    final storeId = widget.currentProfile.storeId;
    if (storeId == null) return;
    try {
      final rows = await SupabaseService.client
          .from('profiles')
          .select('id, full_name, role')
          .eq('store_id', storeId)
          .inFilter('role', ['admin', 'technician']);
      if (mounted) setState(() => _staffList = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {}
  }

  Future<Map<int, _MonthAgg>> _loadTransactions(String storeId) async {
    final result = <int, _MonthAgg>{for (var m = 1; m <= 12; m++) m: _MonthAgg()};
    try {
      // Lọc rộng bằng created_at (±1 tháng) để không bỏ sót giao dịch nhập trễ,
      // sau đó dùng _txDate() (ưu tiên transaction_date) để nhóm đúng ngày TT.
      final wideStart = DateTime.utc(_year - 1, 12, 1);
      final wideEnd = DateTime.utc(_year + 1, 2, 1);
      var query = SupabaseService.client
          .from('transactions')
          .select('id, type, amount, category, description, transaction_date, created_at, created_by')
          .eq('store_id', storeId)
          .gte('created_at', wideStart.toIso8601String())
          .lt('created_at', wideEnd.toIso8601String());
      if (_targetTechId != null) {
        query = query.eq('created_by', _targetTechId!);
      }
      final rows = await query;
      for (final r in rows as List) {
        final d = _txDate(r as Map<String, dynamic>);
        if (d == null || d.year != _year) continue;
        final agg = result[d.month] ?? _MonthAgg();
        if (r['type'] == 'income') {
          agg.income += (r['amount'] as num?) ?? 0;
          agg.incomeTx.add(r);
        } else if (r['type'] == 'expense') {
          agg.expense += (r['amount'] as num?) ?? 0;
          agg.expenseTx.add(r);
        }
      }
    } catch (_) {}
    return result;
  }

  /// Tạo danh sách tóm tắt theo tháng (cả năm).
  List<_SummaryRow> _buildYearlySummary(Map<int, _MonthAgg> monthly) {
    return List.generate(12, (i) {
      final m = i + 1;
      final agg = monthly[m] ?? _MonthAgg();
      final salaryCount = agg.expenseTx.where((tx) => _isSalary(tx as Map<String, dynamic>)).length;
      final nonSalaryExpenseCount = agg.expenseTx.length - salaryCount;
      return _SummaryRow(
        label: _monthNames[i],
        income: agg.income, expense: agg.expense,
        incomeCount: agg.incomeTx.length,
        expenseCount: nonSalaryExpenseCount,
        salaryCount: salaryCount,
      );
    });
  }

  /// Tạo danh sách tóm tắt theo ngày trong 1 tháng.
  List<_SummaryRow> _buildDailySummary(_MonthAgg agg, int month) {
    final dayMap = <int, _DayAgg>{};
    final dayTxMap = <int, List<Map<String, dynamic>>>{};
    for (final tx in agg.incomeTx) {
      final d = _txDate(tx as Map<String, dynamic>);
      if (d == null || d.month != month) continue;
      dayMap.putIfAbsent(d.day, () => _DayAgg(d)).income += (tx['amount'] as num?) ?? 0;
      dayTxMap.putIfAbsent(d.day, () => []).add(tx);
    }
    for (final tx in agg.expenseTx) {
      final d = _txDate(tx as Map<String, dynamic>);
      if (d == null || d.month != month) continue;
      dayMap.putIfAbsent(d.day, () => _DayAgg(d)).expense += (tx['amount'] as num?) ?? 0;
      dayTxMap.putIfAbsent(d.day, () => []).add(tx);
    }
    final days = dayMap.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    return days.map((d) {
      final txList = dayTxMap[d.date.day] ?? [];
      final incomeList = txList.where((tx) => tx['type'] == 'income').toList();
      final expenseList = txList.where((tx) => tx['type'] == 'expense').toList();
      final salaryList = expenseList.where((tx) => _isSalary(tx as Map<String, dynamic>)).toList();
      return _SummaryRow(
        label: '${_dayFmt.format(d.date)} (${_weekdayName(d.date.weekday)})',
        income: d.income, expense: d.expense,
        incomeCount: incomeList.length,
        expenseCount: expenseList.length - salaryList.length,
        salaryCount: salaryList.length,
        transactions: txList,
      );
    }).toList();
  }

  bool _isSalary(Map<String, dynamic> tx) {
    final cat = (tx['category'] ?? '').toString().toLowerCase();
    return cat.contains('lương') || cat.contains('salary');
  }

  String _weekdayName(int w) {
    const names = ['', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];
    return w < names.length ? names[w] : '';
  }

  void _openDetail(int month, _MonthAgg agg) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _MonthDetailScreen(
          title: '$_targetLabel · ${_monthNames[month - 1]} $_year',
          agg: agg,
        ),
      ),
    );
  }

  RelativeRect _menuPos(GlobalKey key) {
    final rb = key.currentContext!.findRenderObject() as RenderBox;
    final ob = Overlay.of(context).context.findRenderObject() as RenderBox;
    final tl = rb.localToGlobal(Offset.zero, ancestor: ob);
    return RelativeRect.fromLTRB(tl.dx, tl.dy + rb.size.height + 4,
        ob.size.width - (tl.dx + rb.size.width), 0);
  }

  Future<void> _pickTarget(GlobalKey key) async {
    final choice = await showMenu<Map<String, dynamic>>(
      context: context, position: _menuPos(key),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 260),
      items: [
        PopupMenuItem(
          value: const {'id': '', 'name': 'Cửa hàng'},
          child: Row(children: [
            const Icon(Icons.storefront_outlined, size: 18),
            const SizedBox(width: 10),
            const Expanded(child: Text('Cửa hàng (tất cả)')),
            if (_targetTechId == null) const Icon(Icons.check, size: 16),
          ]),
        ),
        if (_staffList.isNotEmpty) const PopupMenuDivider(),
        for (final s in _staffList)
          PopupMenuItem(
            value: {'id': s['id'] as String, 'name': (s['full_name'] ?? '').toString()},
            child: Row(children: [
              const Icon(Icons.engineering_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text((s['full_name'] ?? '').toString(), overflow: TextOverflow.ellipsis)),
              if (_targetTechId == s['id']) const Icon(Icons.check, size: 16),
            ]),
          ),
      ],
    );
    if (choice != null && mounted) {
      setState(() {
        _targetTechId = (choice['id'] as String).isEmpty ? null : choice['id'] as String;
        _targetLabel = choice['name'] as String;
      });
    }
  }

  Future<void> _pickYear(GlobalKey key) async {
    final now = DateTime.now();
    final years = List.generate(5, (i) => now.year - i);
    final choice = await showMenu<int>(
      context: context, position: _menuPos(key),
      constraints: const BoxConstraints(minWidth: 120),
      items: [for (final y in years) PopupMenuItem(value: y, child: Row(children: [Expanded(child: Text('$y')), if (y == _year) const Icon(Icons.check, size: 16)]))],
    );
    if (choice != null && mounted) setState(() { _year = choice; _selectedMonth = null; });
  }

  @override
  Widget build(BuildContext context) {
    final storeId = widget.currentProfile.storeId ?? '';
    final targetKey = GlobalKey();
    final yearKey = GlobalKey();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Thu / Chi / Lợi nhuận', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: targetKey,
              onPressed: _isTechnician ? null : () => _pickTarget(targetKey),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
              icon: const Icon(Icons.person_outline, size: 15),
              label: Text(_targetLabel, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              key: yearKey,
              onPressed: () => _pickYear(yearKey),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
              icon: const Icon(Icons.calendar_today, size: 15),
              label: Text('$_year', style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 12),

        FutureBuilder<Map<int, _MonthAgg>>(
          future: _loadTransactions(storeId),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final monthly = snap.data!;

            // Tổng hợp
            num yearIncome = 0, yearExpense = 0;
            for (final agg in monthly.values) { yearIncome += agg.income; yearExpense += agg.expense; }
            final yearProfit = yearIncome - yearExpense;
            final mAgg = _selectedMonth != null ? monthly[_selectedMonth!] : null;
            final dIncome = mAgg?.income ?? yearIncome;
            final dExpense = mAgg?.expense ?? yearExpense;
            // Danh sách tóm tắt
            final summaryRows = _selectedMonth == null
                ? _buildYearlySummary(monthly)
                : _buildDailySummary(mAgg ?? _MonthAgg(), _selectedMonth!);

            return Column(
              children: [
                // ---- Chips chọn tháng ----
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal, itemCount: 13,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final isSelected = i == 0 ? _selectedMonth == null : _selectedMonth == i;
                      final monthAgg = i == 0 ? null : monthly[i];
                      final hasData = i > 0 && (monthAgg != null && (monthAgg.income > 0 || monthAgg.expense > 0));
                      return ChoiceChip(
                        label: i == 0 ? const Text('Cả năm', style: TextStyle(fontSize: 12)) : Text('T$i', style: const TextStyle(fontSize: 12)),
                        selected: isSelected,
                        onSelected: (_) => setState(() => _selectedMonth = i == 0 ? null : i),
                        selectedColor: const Color(0xFF3B82F6),
                        labelStyle: TextStyle(color: isSelected ? Colors.white : (hasData ? Colors.black87 : Colors.black38), fontSize: 12),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),

                // ---- Biểu đồ ----
                if (_selectedMonth == null)
                  _YearBarChart(monthly: monthly, onTapMonth: (m) => setState(() => _selectedMonth = m))
                else
                  _MonthHorizontalChart(agg: mAgg ?? _MonthAgg(), onTapCategory: (type) {
                    final agg = mAgg ?? _MonthAgg();
                    if ((type == 'income' ? agg.incomeTx : agg.expenseTx).isNotEmpty) {
                      _openDetail(_selectedMonth!, agg);
                    }
                  }),

                const SizedBox(height: 16),

                // ---- Danh sách tóm tắt (tháng hoặc ngày) ----
                _SummaryListSection(
                  title: _selectedMonth == null
                      ? 'Tổng hợp theo tháng ($_year)'
                      : 'Tổng hợp theo ngày · ${_monthNames[_selectedMonth! - 1]} $_year',
                  rows: summaryRows,
                  isDaily: _selectedMonth != null,
                  totalIncome: dIncome,
                  totalExpense: dExpense,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// =====================================================================
// Danh sách tóm tắt theo tháng/ngày
// =====================================================================
class _SummaryListSection extends StatelessWidget {
  final String title;
  final List<_SummaryRow> rows;
  final bool isDaily;
  final num totalIncome;
  final num totalExpense;
  const _SummaryListSection({
    required this.title, required this.rows, this.isDaily = false,
    this.totalIncome = 0, this.totalExpense = 0,
  });

  @override
  Widget build(BuildContext context) {
    final totalProfit = totalIncome - totalExpense;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        for (int i = 0; i < rows.length; i++)
          _SummaryListTile(row: rows[i], isLast: false, isDaily: isDaily),

        // ---- Tổng cộng ----
        if (rows.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 140, child: Text('Tổng cộng', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  SizedBox(
                    width: 100,
                    child: Text(
                      totalIncome > 0 ? _currency.format(totalIncome) : '—',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 100,
                    child: Text(
                      totalExpense > 0 ? _currency.format(totalExpense) : '—',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB91C1C)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 100,
                    child: Text(
                      _currency.format(totalProfit),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: totalProfit >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316)),
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('Không có dữ liệu', style: TextStyle(color: Colors.black45))),
          ),
      ],
    );
  }
}

class _SummaryListTile extends StatelessWidget {
  final _SummaryRow row;
  final bool isLast;
  final bool isDaily;
  const _SummaryListTile({required this.row, required this.isLast, this.isDaily = false});

  @override
  Widget build(BuildContext context) {
    final profit = row.income - row.expense;
    final parts = <String>[];
    if (row.incomeCount > 0) parts.add('${row.incomeCount} phiếu thu');
    if (row.expenseCount > 0) parts.add('${row.expenseCount} phiếu chi');
    if (row.salaryCount > 0) parts.add('${row.salaryCount} trả lương');

    return InkWell(
      onTap: isDaily && row.transactions != null && row.transactions!.isNotEmpty
          ? () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => _DayDetailScreen(title: row.label, transactions: row.transactions!)))
          : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: isLast ? Colors.transparent : Colors.grey.shade200)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 140,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDaily ? const Color(0xFF1D4ED8) : Colors.black87)),
                    if (parts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(parts.join(', '), style: const TextStyle(fontSize: 11, color: Colors.black45)),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: row.income > 0
                    ? Text(_currency.format(row.income), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF)))
                    : const Text('—', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.black38)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 100,
                child: row.expense > 0
                    ? Text(_currency.format(row.expense), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C)))
                    : const Text('—', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.black38)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 100,
                child: Text(
                  _currency.format(profit),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: profit >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Tổng quan card
// =====================================================================
class _SummaryCard extends StatelessWidget {
  final String label;
  final num amount;
  final Color color;
  final IconData icon;
  const _SummaryCard({required this.label, required this.amount, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(_currency.format(amount), style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================
// Biểu đồ cột dọc: cả năm
// =====================================================================
class _YearBarChart extends StatelessWidget {
  final Map<int, _MonthAgg> monthly;
  final ValueChanged<int> onTapMonth;
  const _YearBarChart({required this.monthly, required this.onTapMonth});

  @override
  Widget build(BuildContext context) {
    final maxYVal = monthly.values.fold<num>(0, (m, a) {
      final hi = a.income > a.expense ? a.income : a.expense;
      return hi > m ? hi : m;
    });
    final maxNeg = monthly.values.fold<num>(0, (m, a) {
      final p = a.income - a.expense;
      return p < 0 && p.abs() > m ? p.abs() : m;
    });
    final maxY = maxYVal <= 0 ? 100000.0 : (maxYVal * 1.2).toDouble();
    final minY = maxNeg > 0 ? -(maxNeg * 1.2).toDouble() : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = Platform.isAndroid ? 640.0 : constraints.maxWidth;
        final barW = (w / 12 * 0.22).clamp(5.0, 14.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: Platform.isAndroid ? const BouncingScrollPhysics() : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: w, height: 220,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxY, minY: minY,
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (g, gi, rod, ri) {
                      final pVal = (monthly[gi + 1]?.income ?? 0) - (monthly[gi + 1]?.expense ?? 0);
                      final labels = ['Thu', 'Chi', pVal >= 0 ? 'Lãi' : 'Lỗ'];
                      return BarTooltipItem('${labels[ri]}: ${_currency.format(rod.toY)}',
                          const TextStyle(color: Colors.white, fontSize: 11));
                    },
                  ),
                  touchCallback: (event, response) {
                    if (event is FlTapUpEvent && response?.spot != null) {
                      onTapMonth(response!.spot!.touchedBarGroupIndex + 1);
                    }
                  },
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true, reservedSize: 20,
                      getTitlesWidget: (v, _) => Text('T${v.toInt()}', style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true, reservedSize: 44,
                      getTitlesWidget: (v, _) => Text(_compactMoney(v), style: const TextStyle(fontSize: 9)),
                    ),
                  ),
                ),
                barGroups: [
                  for (var m = 1; m <= 12; m++) ...[
                    BarChartGroupData(
                      x: m, barsSpace: 1,
                      barRods: [
                        BarChartRodData(toY: (monthly[m]?.income ?? 0).toDouble(), color: const Color(0xFF3B82F6), width: barW, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                        BarChartRodData(toY: (monthly[m]?.expense ?? 0).toDouble(), color: const Color(0xFFEF4444), width: barW, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                        BarChartRodData(
                          toY: ((monthly[m]?.income ?? 0) - (monthly[m]?.expense ?? 0)).toDouble(),
                          color: ((monthly[m]?.income ?? 0) - (monthly[m]?.expense ?? 0)) >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316),
                          width: barW,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// =====================================================================
// Biểu đồ ngang: 1 tháng theo danh mục
// =====================================================================
class _MonthHorizontalChart extends StatelessWidget {
  final _MonthAgg agg;
  final ValueChanged<String> onTapCategory;
  const _MonthHorizontalChart({required this.agg, required this.onTapCategory});

  @override
  Widget build(BuildContext context) {
    final incomeByCat = <String, num>{};
    final expenseByCat = <String, num>{};
    for (final tx in agg.incomeTx) {
      final cat = (tx['category'] as String?)?.isNotEmpty == true ? tx['category'] as String : 'Khác';
      incomeByCat[cat] = (incomeByCat[cat] ?? 0) + ((tx['amount'] as num?) ?? 0);
    }
    for (final tx in agg.expenseTx) {
      final cat = (tx['category'] as String?)?.isNotEmpty == true ? tx['category'] as String : 'Khác';
      expenseByCat[cat] = (expenseByCat[cat] ?? 0) + ((tx['amount'] as num?) ?? 0);
    }

    if (incomeByCat.isEmpty && expenseByCat.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('Không có giao dịch trong tháng này', style: TextStyle(color: Colors.black45))),
      );
    }

    final allCats = <MapEntry<String, num>>[];
    for (final e in incomeByCat.entries) { allCats.add(MapEntry('Thu · ${e.key}', e.value)); }
    for (final e in expenseByCat.entries) { allCats.add(MapEntry('Chi · ${e.key}', e.value)); }
    allCats.sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final maxVal = allCats.isEmpty ? 0 : allCats.first.value.abs();

    return Column(
      children: [
        for (int i = 0; i < allCats.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _HorizontalBar(
            label: allCats[i].key,
            amount: allCats[i].value,
            fraction: maxVal > 0 ? allCats[i].value.abs() / maxVal : 0,
            color: allCats[i].key.startsWith('Thu') ? const Color(0xFF3B82F6) : const Color(0xFFEF4444),
            onTap: () => onTapCategory(allCats[i].key.startsWith('Thu') ? 'income' : 'expense'),
          ),
        ],
        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 8),
        _HorizontalBar(
          label: (agg.income - agg.expense) >= 0 ? 'Lãi' : 'Lỗ',
          amount: agg.income - agg.expense,
          fraction: maxVal > 0 ? (agg.income - agg.expense).abs() / maxVal : 0,
          color: (agg.income - agg.expense) >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316),
          onTap: null,
        ),
      ],
    );
  }
}

// =====================================================================
// Horizontal bar widget
// =====================================================================
class _HorizontalBar extends StatelessWidget {
  final String label;
  final num amount;
  final double fraction;
  final Color color;
  final VoidCallback? onTap;
  const _HorizontalBar({required this.label, required this.amount, required this.fraction, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isIncome = color == const Color(0xFF3B82F6);
    final amtColor = isIncome ? const Color(0xFF1E40AF) : const Color(0xFFB91C1C);
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Stack(
              children: [
                Container(height: 24, decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6))),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.01, 1.0),
                  child: Container(height: 24, decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withValues(alpha: 0.5), color]), borderRadius: BorderRadius.circular(6))),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(_currency.format(amount), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fraction > 0.3 ? Colors.white : amtColor)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Máy quá hạn
// =====================================================================
class _OverdueOrdersList extends StatelessWidget {
  final List<RepairOrder> orders;
  const _OverdueOrdersList({required this.orders});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final overdue = orders.where((o) {
      if (o.status == 'delivered' || o.status == 'cancelled') return false;
      return now.difference(o.receivedAt).inDays >= 5;
    }).toList()..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));

    if (overdue.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Không có đơn quá hạn', style: TextStyle(color: Colors.black45))),
      );
    }

    return Column(
      children: overdue.map((o) => Card(
        margin: const EdgeInsets.symmetric(vertical: 3),
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
          title: Text('${o.code} · ${o.deviceModel ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text(
            'Nhận: ${_dateFmt.format(o.receivedAt)} · ${now.difference(o.receivedAt).inDays} ngày',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Text(StatusColors.label[o.status] ?? o.status,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: StatusColors.map[o.status])),
        ),
      )).toList(),
    );
  }
}

// =====================================================================
// Chi tiết 1 tháng
// =====================================================================
class _MonthDetailScreen extends StatelessWidget {
  final String title;
  final _MonthAgg agg;
  const _MonthDetailScreen({required this.title, required this.agg});

  @override
  Widget build(BuildContext context) {
    final profit = agg.income - agg.expense;
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(child: _SummaryCard(label: 'Thu', amount: agg.income, color: const Color(0xFF3B82F6), icon: Icons.arrow_downward_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _SummaryCard(label: 'Chi', amount: agg.expense, color: const Color(0xFFEF4444), icon: Icons.arrow_upward_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _SummaryCard(label: profit >= 0 ? 'Lãi' : 'Lỗ', amount: profit, color: profit >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316), icon: profit >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded)),
            ]),
            const SizedBox(height: 20),

            if (agg.incomeTx.isNotEmpty) ...[
              Text('Phiếu thu (${agg.incomeTx.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              for (final tx in agg.incomeTx) _TransactionTile(tx: tx, color: const Color(0xFF3B82F6), icon: Icons.arrow_downward_rounded),
              const SizedBox(height: 12),
            ],
            if (agg.expenseTx.isNotEmpty) ...[
              Text('Phiếu chi (${agg.expenseTx.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              for (final tx in agg.expenseTx) _TransactionTile(tx: tx, color: const Color(0xFFEF4444), icon: Icons.arrow_upward_rounded),
            ],
            if (agg.incomeTx.isEmpty && agg.expenseTx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Không có giao dịch', style: TextStyle(color: Colors.black45))),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  final Color color;
  final IconData icon;
  const _TransactionTile({required this.tx, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    final date = _txDate(tx);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: color, size: 20),
        title: Text(
          '${tx['category'] ?? (color == const Color(0xFF3B82F6) ? 'Thu' : 'Chi')} · ${_currency.format(tx['amount'] ?? 0)}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${tx['description'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        trailing: Text(date != null ? _dateFmt.format(date) : '—', style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}

// =====================================================================
// Chi tiết 1 ngày: danh sách phiếu thu + chi
// =====================================================================
class _DayDetailScreen extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> transactions;
  const _DayDetailScreen({required this.title, required this.transactions});

  @override
  Widget build(BuildContext context) {
    num totalIncome = 0, totalExpense = 0;
    final incomeTx = <Map<String, dynamic>>[];
    final expenseTx = <Map<String, dynamic>>[];
    for (final tx in transactions) {
      if (tx['type'] == 'income') {
        totalIncome += (tx['amount'] as num?) ?? 0;
        incomeTx.add(tx);
      } else {
        totalExpense += (tx['amount'] as num?) ?? 0;
        expenseTx.add(tx);
      }
    }
    final profit = totalIncome - totalExpense;

    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(child: _SummaryCard(label: 'Thu', amount: totalIncome, color: const Color(0xFF3B82F6), icon: Icons.arrow_downward_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _SummaryCard(label: 'Chi', amount: totalExpense, color: const Color(0xFFEF4444), icon: Icons.arrow_upward_rounded)),
              const SizedBox(width: 8),
              Expanded(child: _SummaryCard(label: profit >= 0 ? 'Lãi' : 'Lỗ', amount: profit, color: profit >= 0 ? const Color(0xFF16A34A) : const Color(0xFFF97316), icon: profit >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded)),
            ]),
            const SizedBox(height: 20),

            if (incomeTx.isNotEmpty) ...[
              Text('Phiếu thu (${incomeTx.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              for (final tx in incomeTx) _TransactionTile(tx: tx, color: const Color(0xFF3B82F6), icon: Icons.arrow_downward_rounded),
              const SizedBox(height: 12),
            ],
            if (expenseTx.isNotEmpty) ...[
              Text('Phiếu chi (${expenseTx.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              for (final tx in expenseTx) _TransactionTile(tx: tx, color: const Color(0xFFEF4444), icon: Icons.arrow_upward_rounded),
            ],

            if (incomeTx.isEmpty && expenseTx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Không có giao dịch', style: TextStyle(color: Colors.black45))),
              ),
          ],
        ),
      ),
    );
  }
}

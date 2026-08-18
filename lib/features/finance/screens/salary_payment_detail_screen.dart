import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

/// Trang chi tiết 1 phiếu trả lương. Hiển thị dạng văn bản với các con số
/// quan trọng được in đậm / đổi màu.
class SalaryPaymentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> payment;
  final String employeeName;
  const SalaryPaymentDetailScreen({
    super.key,
    required this.payment,
    required this.employeeName,
  });

  @override
  State<SalaryPaymentDetailScreen> createState() => _SalaryPaymentDetailScreenState();
}

class _SalaryPaymentDetailScreenState extends State<SalaryPaymentDetailScreen> {
  String? _paidByName;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPaidByName();
  }

  Future<void> _loadPaidByName() async {
    try {
      final createdBy = widget.payment['created_by'] as String?;
      if (createdBy != null) {
        final row = await SupabaseService.client
            .from('profiles')
            .select('full_name')
            .eq('id', createdBy)
            .maybeSingle();
        if (mounted) setState(() => _paidByName = row?['full_name'] as String? ?? '');
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final periodStart = DateTime.tryParse(p['period_start']?.toString() ?? '');
    final periodEnd = DateTime.tryParse(p['period_end']?.toString() ?? '');
    final created = DateTime.tryParse(p['created_at']?.toString() ?? '');
    final isLabor = p['commission_type'] == 'labor_fixed';

    final rate = (p['commission_rate'] as num?)?.toDouble() ?? 0;
    final amount = (p['commission_amount'] as num?)?.toDouble() ?? 0;
    final totalCommission = (p['total_commission'] as num?) ?? 0;
    final netAmount = (p['net_amount'] as num?) ?? 0;
    final orderCount = (p['order_count'] as num?)?.toInt() ?? 0;
    final assignedCount = (p['assigned_count'] as num?)?.toInt() ?? orderCount;
    final completedCount = (p['completed_count'] as num?)?.toInt() ?? orderCount;
    final laborTotal = (p['labor_total'] as num?) ?? 0;
    final profitTotal = (p['profit_total'] as num?) ?? 0;
    final payMethod = p['pay_method'] == 'transfer' ? 'Chuyển khoản' : 'Tiền mặt';

    final span = (String t, {bool bold = false, Color? color, double? size}) =>
        TextSpan(
          text: t,
          style: TextStyle(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: color ?? Colors.black87,
            fontSize: size ?? 14,
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Phiếu trả lương')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Text.rich(
                      TextSpan(children: [
                        span('PHIẾU TRẢ LƯƠNG\n', bold: true, size: 16),
                        span('${periodStart != null ? '${periodStart.day.toString().padLeft(2, '0')}/${periodStart.month.toString().padLeft(2, '0')}/${periodStart.year}' : ''}'
                            ' - '
                            '${periodEnd != null ? '${periodEnd.day.toString().padLeft(2, '0')}/${periodEnd.month.toString().padLeft(2, '0')}/${periodEnd.year}' : ''}',
                            size: 13, color: Colors.black54),
                      ]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(height: 28),
                  _row('Nhân viên', widget.employeeName, boldValue: true),
                  _row('Ngày trả', created != null ? '${created.day}/${created.month}/${created.year} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}' : '', boldValue: true),
                  _row('Hình thức', payMethod, boldValue: true),
                  const Divider(height: 28),
                  Text('CÁCH TÍNH LƯƠNG', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.blueGrey.shade600)),
                  const SizedBox(height: 10),
                  if (isLabor) ...[
                    _row('Tiền công / đơn', _currency.format(amount)),
                    _row('Số máy được giao', '$assignedCount máy'),
                    _row('Số máy hoàn thành', '$completedCount máy'),
                    _row('Doanh thu', _currency.format(laborTotal)),
                    _row('Lợi nhuận', _currency.format(profitTotal)),
                    _row('Tổng tiền công', _currency.format(totalCommission), valueColor: Colors.green, boldValue: true),
                  ] else ...[
                    _row('Tỷ lệ % lợi nhuận', '${rate.toStringAsFixed(0)}%'),
                    _row('Số máy được giao', '$assignedCount máy'),
                    _row('Số máy hoàn thành', '$completedCount máy'),
                    _row('Doanh thu', _currency.format(laborTotal)),
                    _row('Lợi nhuận', _currency.format(profitTotal)),
                    _row('Tổng hoa hồng', _currency.format(totalCommission), valueColor: Colors.green, boldValue: true),
                  ],
                  _row('Các khoản trừ', _currency.format((p['total_deductions'] as num?) ?? 0), valueColor: Colors.red),
                  const Divider(height: 28),
                  _row('THỰC NHẬN', _currency.format(netAmount), valueColor: const Color(0xFF1D4ED8), boldValue: true, boldLabel: true),
                  const SizedBox(height: 16),
                  if (!_loading && _paidByName != null)
                    Text(
                      'Người trả: $_paidByName',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  Text(
                    'Mã phiếu: ${p['id'] ?? ''}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool boldLabel = false, bool boldValue = false, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.black54,
                  fontWeight: boldLabel ? FontWeight.w700 : FontWeight.w400,
                )),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                color: valueColor ?? Colors.black87,
                fontWeight: boldValue ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

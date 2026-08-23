import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/repair_order.dart';

/// Kiểu xử lý đổi trạng thái 1 đơn hoàn tất. Được truyền từ màn hình cha
/// (RepairOrdersListScreen) để tái sử dụng đúng logic đã có: lọc trạng thái
/// theo vai trò, chọn hình thức thanh toán khi trả máy, hạch toán/đảo hạch
/// toán doanh thu, thông báo Discord — không phải copy lại logic ở đây.
typedef CompleteOrderStatusChange =
    Future<void> Function(RepairOrder order, String newStatus);

final _dateFmt = DateFormat('dd/MM/yyyy');
final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

/// Hiện dialog chi tiết 1 đơn đã HOÀN TẤT (đã trả máy + khách không sửa).
/// Toàn bộ thông tin khách hàng/đơn hàng hiển thị đọc-only dạng liệt kê cho
/// dễ nhìn; trạng thái chọn trực tiếp ngay trong dialog bằng dropdown.
Future<void> showCompleteOrderDialog({
  required BuildContext context,
  required RepairOrder order,
  required String customerName,
  required String customerPhone,
  required List<String> allowedStatuses,
  required CompleteOrderStatusChange onChangeStatus,
}) {
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: Text('Đơn hoàn tất ${order.code}'),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: SizedBox(
        width: 510,
        child: SingleChildScrollView(
          child: _CompleteOrderCard(
            order: order,
            customerName: customerName,
            customerPhone: customerPhone,
            allowedStatuses: allowedStatuses,
            onChangeStatus: onChangeStatus,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Đóng'),
        ),
      ],
    ),
  );
}

/// 1 đơn hoàn tất hiển thị dạng thẻ liệt kê đọc-only. Trạng thái là dropdown
/// chọn trực tiếp tại dialog.
class _CompleteOrderCard extends StatefulWidget {
  final RepairOrder order;
  final String customerName;
  final String customerPhone;
  final List<String> allowedStatuses;
  final CompleteOrderStatusChange onChangeStatus;

  const _CompleteOrderCard({
    required this.order,
    required this.customerName,
    required this.customerPhone,
    required this.allowedStatuses,
    required this.onChangeStatus,
  });

  @override
  State<_CompleteOrderCard> createState() => _CompleteOrderCardState();
}

class _CompleteOrderCardState extends State<_CompleteOrderCard> {
  late String _status = widget.order.status;
  bool _saving = false;

  List<String> get _statusOptions => [
        _status,
        ...widget.allowedStatuses.where((s) => s != _status),
      ];

  Future<Map<String, String>> _resolveNames() async {
    final ids = <String>{
      if (widget.order.receivedBy != null) widget.order.receivedBy!,
      if (widget.order.technicianId != null) widget.order.technicianId!,
      if (widget.order.deliveredBy != null) widget.order.deliveredBy!,
    };
    if (ids.isEmpty) return {};
    try {
      final rows = await SupabaseService.client
          .from('profiles')
          .select('id, full_name')
          .inFilter('id', ids.toList());
      return {
        for (final r in rows)
          r['id'] as String: (r['full_name'] as String? ?? '').trim(),
      };
    } catch (_) {
      return {};
    }
  }

  String _paymentLabel() {
    switch (widget.order.paymentMethod) {
      case 'debt':
        return 'Ghi nợ';
      case 'transfer':
        return 'Chuyển khoản';
      case 'cash':
        return 'Tiền mặt';
      default:
        return '—';
    }
  }

  Widget _infoRow(String label, String value) {
    final isMoney = label.contains('giá');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.black87,
                fontWeight: isMoney ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeStatus(String? newStatus) async {
    if (newStatus == null || newStatus == _status || _saving) return;
    setState(() {
      _status = newStatus;
      _saving = true;
    });
    try {
      await widget.onChangeStatus(widget.order, newStatus);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final deviceModel = (order.deviceModel ?? '').trim();
    final customerLine = widget.customerName.isNotEmpty
        ? widget.customerPhone.isNotEmpty
            ? '${widget.customerName} · ${widget.customerPhone}'
            : widget.customerName
        : widget.customerPhone;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                order.code,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            _StatusDropdownButton(
              status: _status,
              options: _statusOptions,
              saving: _saving,
              onSelected: _changeStatus,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _infoRow('Khách hàng', customerLine),
        if (deviceModel.isNotEmpty) _infoRow('Model máy', deviceModel),
        _infoRow('IMEI', order.imei ?? ''),
        _infoRow('Lỗi', order.issueDescription ?? ''),
        _infoRow('Báo giá', _currency.format(order.estimatedCost)),
        if (order.finalCost > 0)
          _infoRow('Giá cuối', _currency.format(order.finalCost)),
        _infoRow('Bảo hành', order.warrantyDays > 0 ? '${order.warrantyDays} ngày' : ''),
        _infoRow('Ngày tạo', _dateFmt.format(order.receivedAt)),
        if (order.deliveredAt != null)
          _infoRow('Ngày trả máy', _dateFmt.format(order.deliveredAt!)),
        if (order.paymentMethod != null)
          _infoRow('Thanh toán', _paymentLabel()),
        if ((order.note ?? '').isNotEmpty)
          _infoRow('Ghi chú', order.note!),
        const SizedBox(height: 10),
        FutureBuilder<Map<String, String>>(
          future: _resolveNames(),
          builder: (context, snap) {
            final names = snap.data ?? {};
            String _name(String? id) =>
                (id == null || (names[id] ?? '').isEmpty) ? '—' : names[id]!;
            final steps = <_JourneyStep>[
              _JourneyStep(
                icon: Icons.how_to_reg_rounded,
                label: 'Tiếp nhận',
                name: _name(order.receivedBy),
                color: Colors.blue,
              ),
              if (order.technicianId != null)
                _JourneyStep(
                  icon: Icons.build_rounded,
                  label: 'Sửa máy',
                  name: _name(order.technicianId),
                  color: Colors.orange,
                ),
              if (order.deliveredBy != null)
                _JourneyStep(
                  icon: Icons.assignment_return_rounded,
                  label: 'Trả máy',
                  name: _name(order.deliveredBy),
                  color: Colors.green,
                ),
            ];
            if (steps.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Hành trình máy',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (int i = 0; i < steps.length; i++) ...[
                      Expanded(child: _JourneyStepWidget(step: steps[i])),
                      if (i < steps.length - 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(Icons.arrow_forward_ios_rounded, size: 10, color: Colors.grey[400]),
                        ),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Nút trạng thái vừa HIỂN THỊ trạng thái hiện tại vừa là nút CHỌN trạng thái:
/// bấm vào chip sẽ mở menu các trạng thái cho phép, chọn để đổi ngay. Thay
/// thế cho hộp dropdown "Trạng thái" riêng bên dưới.
class _StatusDropdownButton extends StatelessWidget {
  final String status;
  final List<String> options;
  final bool saving;
  final ValueChanged<String?> onSelected;

  const _StatusDropdownButton({
    required this.status,
    required this.options,
    required this.saving,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.map[status] ?? Colors.grey;
    final label = StatusColors.label[status] ?? status;
    return PopupMenuButton<String>(
      initialValue: status,
      enabled: !saving,
      tooltip: 'Đổi trạng thái',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final s in options)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Icon(Icons.circle, size: 10, color: StatusColors.map[s]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    StatusColors.label[s] ?? s,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (s == status)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.check, size: 16, color: Colors.black54),
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

class _JourneyStep {
  final IconData icon;
  final String label;
  final String name;
  final Color color;
  const _JourneyStep({required this.icon, required this.label, required this.name, required this.color});
}

class _JourneyStepWidget extends StatelessWidget {
  final _JourneyStep step;
  const _JourneyStepWidget({required this.step});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: step.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(step.icon, size: 14, color: step.color),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  step.label,
                  style: TextStyle(fontSize: 9, color: step.color, fontWeight: FontWeight.w600),
                ),
                Text(
                  step.name,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

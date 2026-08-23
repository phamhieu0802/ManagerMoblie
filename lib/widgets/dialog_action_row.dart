import 'package:flutter/material.dart';
import 'confirm_dialog.dart';

/// Nếu [isDirty] trả về true (đang có dữ liệu nhập dở / đã thay đổi so với
/// ban đầu) thì hiện hộp xác nhận "Hủy bỏ thay đổi?" trước khi gọi [onDiscard].
/// Dùng chung cho nút Hủy và phím ESC của mọi dialog để hành vi luôn nhất quán.
Future<void> confirmDiscardChanges(
  BuildContext context, {
  required VoidCallback onDiscard,
  bool Function()? isDirty,
}) async {
  final dirty = isDirty?.call() ?? false;
  if (dirty) {
    final confirm = await showConfirmDialog(
      context: context,
      title: 'Hủy bỏ thay đổi?',
      message: 'Dữ liệu mới chưa được lưu.\nBạn muốn thoát ?',
      cancelLabel: 'Nhập tiếp',
      confirmLabel: 'Thoát',
      cancelIsPrimary: true,
      width: 280,
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dữ liệu mới chưa được lưu.', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFB91C1C))),
          SizedBox(height: 2),
          Text('Bạn muốn thoát ?'),
        ],
      ),
    );
    if (!confirm) return;
  }
  onDiscard();
}

/// Hàng nút hành động chuẩn cho MỌI dialog trong app.
/// Thiết kế đồng nhất: nút Hủy nền đỏ nhạt NGẮN HƠN, nút hành động chính nền
/// xanh dương nhạt RỘNG HƠN (tỉ lệ 1:2) — cùng chiều cao, cùng bo góc, cùng
/// cỡ chữ 15, nổi bật cả 2 để dễ nhìn hơn hẳn so với nút trong suốt/viền mỏng.
///
/// Nếu [isDirty] trả về true (đang có dữ liệu nhập dở / đã thay đổi so với
/// ban đầu) khi bấm Hủy, sẽ hiện hộp thoại xác nhận trước khi thực sự đóng,
/// tránh mất dữ liệu do bấm nhầm.
class DialogActionRow extends StatelessWidget {
  final VoidCallback? onCancel;
  final String cancelLabel;
  final Widget primaryButton;
  final bool Function()? isDirty;

  const DialogActionRow({
    super.key,
    required this.onCancel,
    required this.primaryButton,
    this.cancelLabel = 'Hủy',
    this.isDirty,
  });

  static const _radius = 12.0;
  static const _height = 46.0;
  static const _cancelBg = Color(0xFFFEE2E2);
  static const _cancelFg = Color(0xFFB91C1C);
  static const _primaryBg = Color(0xFFDCEBFF);
  static const _primaryFg = Color(0xFF1D4ED8);

  Future<void> _handleCancel(BuildContext context) async {
    final cancel = onCancel;
    if (cancel == null) return;
    await confirmDiscardChanges(context, isDirty: isDirty, onDiscard: cancel);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: _height,
            child: ElevatedButton(
              onPressed: onCancel == null ? null : () => _handleCancel(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: _cancelBg,
                foregroundColor: _cancelFg,
                elevation: 0,
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(cancelLabel),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: _height,
            child: Theme(
              data: Theme.of(context).copyWith(
                elevatedButtonTheme: ElevatedButtonThemeData(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryBg,
                    foregroundColor: _primaryFg,
                    elevation: 0,
                    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
                  ),
                ),
              ),
              child: primaryButton,
            ),
          ),
        ),
      ],
    );
  }
}

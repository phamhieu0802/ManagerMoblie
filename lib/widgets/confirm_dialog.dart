import 'package:flutter/material.dart';

/// Hộp thoại xác nhận dùng chung cho toàn app (xác nhận xoá, đăng xuất, huỷ
/// thay đổi...). Thiết kế đồng nhất với DialogActionRow: nút Hủy nền đỏ
/// nhạt NGẮN HƠN, nút xác nhận nền xanh dương nhạt RỘNG HƠN (tỉ lệ 1:2),
/// cùng chiều cao, cùng cỡ chữ 15, nổi bật dễ nhìn.
///
/// Nếu [cancelIsPrimary] = true (VD: hộp "Hủy bỏ thay đổi?"), nút hủy trở
/// thành hành động chính: rộng hơn + nền xanh dương, còn nút xác nhận thu
/// ngắn lại + nền đỏ nhạt (hành động "thoát" mất dữ liệu là hành động phụ).
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Đồng ý',
  String cancelLabel = 'Hủy',
  bool danger = false,
  bool cancelIsPrimary = false,
  double? width,
  Widget? content,
}) async {
  final cancelBg = cancelIsPrimary ? const Color(0xFFDCEBFF) : const Color(0xFFFEE2E2);
  final cancelFg = cancelIsPrimary ? const Color(0xFF1D4ED8) : const Color(0xFFB91C1C);
  final confirmBg = cancelIsPrimary ? const Color(0xFFFEE2E2) : const Color(0xFFDCEBFF);
  final confirmFg = cancelIsPrimary ? const Color(0xFFB91C1C) : const Color(0xFF1D4ED8);
  final cancelFlex = cancelIsPrimary ? 2 : 1;
  final confirmFlex = cancelIsPrimary ? 1 : 2;

  void safePop(BuildContext ctx, dynamic value) {
    try {
      if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop(value);
    } catch (_) {}
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      Widget dlg = AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        title: Text(title),
        content: content ?? Text(message),
        actions: [
          Row(
            children: [
              Expanded(
                flex: cancelFlex,
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    onPressed: () => safePop(ctx, false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: cancelBg,
                      foregroundColor: cancelFg,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        cancelLabel,
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: confirmFlex,
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: confirmBg,
                      foregroundColor: confirmFg,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => safePop(ctx, true),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        confirmLabel,
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
      if (width != null) dlg = SizedBox(width: width, child: dlg);
      return dlg;
    },
  );
  return result == true;
}

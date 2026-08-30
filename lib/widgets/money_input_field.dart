import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/money_words.dart';

/// Tự động chèn dấu . phân cách hàng ngàn khi gõ số tiền.
/// Input:   "1000000"  => Text hiển thị "1.000.000"
/// parse:   "1.000.000" => 1000000
class VnThousandSeparatorFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    // Chỉ giữ ký tự số
    final digits = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return const TextEditingValue(text: '');
    // Chèn dấu . từ phải sang trái, cứ 3 chữ số.
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      final fromRight = digits.length - i;
      if (i > 0 && fromRight % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Ô nhập số tiền dùng chung cho toàn app: tự chèn dấu . phân cách (1.000.000)
/// và tự hiện "= Một triệu đồng" bên dưới khi gõ. Dùng ở: báo giá đơn sửa
/// chữa, giao dịch thu chi, giá nhập/giá bán linh kiện...
class MoneyInputField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? helperPrefix;
  final bool enabled;

  const MoneyInputField({
    super.key,
    required this.controller,
    required this.label,
    this.helperPrefix,
    this.enabled = true,
  });

  /// Chuyển chuỗi "1.000.000" hoặc "1,000,000" -> số 1000000. null nếu không
  /// phải số hợp lệ.
  static num? parse(String text) {
    return num.tryParse(text.trim().replaceAll('.', '').replaceAll(',', ''));
  }

  /// Định dạng số ra chuỗi có dấu . phân cách: 1000000 -> "1.000.000".
  /// Dùng để prefill các ô nhập tiền khi sửa.
  static String formatNum(num value) {
    final s = value.round().toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final fromRight = s.length - i;
      if (i > 0 && fromRight % 3 == 0) buffer.write('.');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }

  @override
  State<MoneyInputField> createState() => _MoneyInputFieldState();
}

class _MoneyInputFieldState extends State<MoneyInputField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final amount = MoneyInputField.parse(widget.controller.text);
    final words = (amount != null && amount != 0) ? moneyToVietnameseWords(amount) : null;

    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      inputFormatters: [VnThousandSeparatorFormatter()],
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: 'đ',
        helperText: words == null
            ? (widget.helperPrefix ?? ' ')
            : '${widget.helperPrefix != null ? "${widget.helperPrefix} · " : ""}$words',
        helperMaxLines: 2,
      ),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/money_words.dart';

/// Ô nhập số tiền dùng chung cho toàn app: tự hiện "= Một triệu đồng" bên
/// dưới khi gõ, giúp phát hiện gõ nhầm số 0. Dùng ở: báo giá đơn sửa chữa,
/// giao dịch thu chi, giá nhập/giá bán linh kiện...
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
    final amount = num.tryParse(widget.controller.text.trim().replaceAll(',', ''));
    final words = (amount != null && amount != 0) ? moneyToVietnameseWords(amount) : null;

    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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

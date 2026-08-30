import 'package:flutter/material.dart';
import '../../../core/supabase_service.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/dialog_action_row.dart';

/// Ô chọn danh mục phiếu thu/chi: dropdown các danh mục đã dùng trong cửa hàng
/// + nút "+" để thêm danh mục mới (kiểu như ô danh mục linh kiện).
class CategoryPickerField extends StatefulWidget {
  final String storeId;
  final TextEditingController controller;
  final VoidCallback? onChanged;
  final bool enabled;

  const CategoryPickerField({
    super.key,
    required this.storeId,
    required this.controller,
    this.onChanged,
    this.enabled = true,
  });

  @override
  State<CategoryPickerField> createState() => _CategoryPickerFieldState();
}

class _CategoryPickerFieldState extends State<CategoryPickerField> {
  List<String> _categories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final rows = await SupabaseService.client
          .from('transactions')
          .select('category')
          .eq('store_id', widget.storeId)
          .not('category', 'is', null);
      final set = <String>{
        if (widget.controller.text.trim().isNotEmpty) widget.controller.text.trim(),
        for (final r in rows)
          if ((r['category']?.toString().trim() ?? '').isNotEmpty)
            r['category'].toString().trim(),
      }..remove('null');
      final list = set.toList()..sort();
      if (mounted) {
        setState(() {
          _categories = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addNewCategory() async {
    final ctrl = TextEditingController();
    final input = await showAdaptiveFormDialog<String>(
      context: context,
      title: 'Thêm danh mục mới',
      allowNested: true,
      contentBuilder: (ctx, setStateDialog) => TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Tên danh mục', helperText: 'VD: Mặt bằng, Điện nước, Quảng cáo...'),
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: () => Navigator.pop(ctx),
        isDirty: () => ctrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Thêm'),
        ),
      ),
    );
    if (input != null && input.isNotEmpty && mounted) {
      widget.controller.text = input;
      if (!_categories.contains(input)) setState(() => _categories = [..._categories, input]..sort());
      widget.onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.controller.text.trim();
    final hasCurrent = current.isNotEmpty || _categories.contains(current);
    if (_loading) {
      return const TextField(
        enabled: false,
        decoration: InputDecoration(labelText: 'Danh mục', hintText: 'Đang tải...'),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: hasCurrent ? current : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Danh mục',
        helperText: 'Chọn danh mục đã có hoặc thêm mới bằng nút +',
        suffixIcon: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.enabled ? _addNewCategory : null,
          child: const Icon(Icons.add, size: 18),
        ),
        suffixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 28),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('-- Không có --')),
        for (final c in _categories)
          DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: widget.enabled
          ? (v) {
              widget.controller.text = v ?? '';
              widget.onChanged?.call();
            }
          : null,
    );
  }
}
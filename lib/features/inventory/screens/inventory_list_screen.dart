import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/notify_helper.dart';
import '../../../core/app_logger.dart';
import '../../../core/app_toast.dart';
import '../../../core/error_utils.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/money_input_field.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);

Future<String> _currentStoreId() async {
  final row = await SupabaseService.client
      .from('profiles')
      .select('store_id')
      .eq('id', SupabaseService.currentUser?.id ?? '')
      .single();
  return row['store_id'] as String;
}

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

/// Chọn nhà cung cấp từ danh sách nợ (debts loại supplier) — bottom sheet
/// dùng chung cho mọi dialog nhập kho.
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
                  stream: autoReconnectStream(
                      () => SupabaseService.client
                          .from('debts')
                          .stream(primaryKey: ['id'])
                          .eq('type', 'supplier')
                          .order('contact_name'),
                      label: 'debts_dlg'),
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

class InventoryListScreen extends StatefulWidget {
  final Widget? appBarLeading;
  const InventoryListScreen({super.key, this.appBarLeading});

  @override
  State<InventoryListScreen> createState() => _InventoryListScreenState();
}

class _InventoryListScreenState extends State<InventoryListScreen> {
  late final Stream<List<Map<String, dynamic>>> _stream;
  late final Stream<List<Map<String, dynamic>>> _catStream;
  late final Stream<List<Map<String, dynamic>>> _inStream;
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  final _selectedPartIds = <String>{};
  // Linh kiện vừa soft-delete trong phiên này (realtime đôi khi không gửi
  // event UPDATE do RLS chặn đọc row đã xóa) — ẩn ngay khỏi danh sách kho.
  final _locallyDeletedPartIds = <String>{};

  @override
  void initState() {
    super.initState();
    _stream = autoReconnectStream(
      () => SupabaseService.client
          .from('inventory_parts')
          .stream(primaryKey: ['id'])
          .order('name'),
      label: 'inventory_parts',
    );
    _catStream = autoReconnectStream(
      () => SupabaseService.client
          .from('part_categories')
          .stream(primaryKey: ['id'])
          .order('name'),
      label: 'part_categories_kho',
    );
    _inStream = autoReconnectStream(
      () => SupabaseService.client
          .from('inventory_transactions')
          .stream(primaryKey: ['id'])
          .eq('type', 'in')
          .order('created_at', ascending: false),
      label: 'inventory_in_kho',
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<String> _generateSku(String storeId) async {
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

  Future<void> _showAddPartDialog() async {
    final nameCtrl = TextEditingController();
    final nameFocusNode = FocusNode();
    final costCtrl = TextEditingController(text: '0');
    final unitPriceCtrl = TextEditingController(text: '0');
    String? categoryId;
    bool saving = false;
    String? error;
    String? existingNamePicked;
    final storeId = await _currentStoreId();
    final sku = await _generateSku(storeId);

    if (!mounted) return;
    await showAdaptiveFormDialog(
      context: context,
      title: 'Thêm linh kiện',
      desktopWidth: 480,
      onEscCancel: (dlgCtx) async {
        if (saving) return;
        if (dlgCtx.mounted) Navigator.pop(dlgCtx);
      },
      escIsDirty: () => nameCtrl.text.trim().isNotEmpty,
      contentBuilder: (ctx, setStateDialog) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Mã linh kiện (tự tạo)'),
            child: Text(sku, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: autoReconnectStream(
                () => SupabaseService.client.from('inventory_parts').stream(primaryKey: ['id']).order('name'),
                label: 'inventory_parts_add'),
            builder: (context, snap) {
              final parts = (snap.data ?? []).where((p) => p['deleted_at'] == null).toList();
              final labels = <String, Map<String, dynamic>>{
                for (final p in parts) (p['name'] ?? '') as String: p,
              };
              return Autocomplete<String>(
                textEditingController: nameCtrl,
                focusNode: nameFocusNode,
                optionsBuilder: (v) {
                  if (v.text.trim().isEmpty) return const Iterable<String>.empty();
                  final q = v.text.toLowerCase();
                  return labels.keys.where((l) => l.toLowerCase().contains(q)).take(8);
                },
                onSelected: (label) {
                  final p = labels[label];
                  setStateDialog(() {
                    nameCtrl.text = (p?['name'] ?? '').toString();
                    if (p != null) {
                      existingNamePicked = p['name'] as String?;
                      if (costCtrl.text.trim().isEmpty || costCtrl.text.trim() == '0') {
                        costCtrl.text = ((p['unit_cost'] as num?) ?? 0).toStringAsFixed(0);
                      }
                      if (unitPriceCtrl.text.trim().isEmpty || unitPriceCtrl.text.trim() == '0') {
                        unitPriceCtrl.text = ((p['unit_price'] as num?) ?? 0).toStringAsFixed(0);
                      }
                    }
                  });
                },
                displayStringForOption: (label) => label,
                fieldViewBuilder: (context, ctrl, focusNode, onSubmit) {
                  return TextField(
                    controller: ctrl,
                    focusNode: focusNode,
                    onChanged: (_) => setStateDialog(() => existingNamePicked = null),
                    decoration: const InputDecoration(labelText: 'Tên linh kiện *'),
                  );
                },
              );
            },
          ),
          if (existingNamePicked != null) ...[
            const SizedBox(height: 4),
            Text(
              '"$existingNamePicked" đã có trong kho — sẽ tạo bản mới. Dùng nút "Nhập kho" để nhập thêm cho linh kiện có sẵn.',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          ],
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
                    key: ValueKey('category_dropdown_${categories.length}_$categoryId'),
                    initialValue: safeValue,
                    decoration: InputDecoration(
                      labelText: 'Danh mục',
                      suffixIcon: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () async {
                          final newId = await _showAddCategoryDialog(ctx, storeId);
                          if (newId != null) setStateDialog(() => categoryId = newId);
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
                    onChanged: (v) => setStateDialog(() => categoryId = v),
                  );
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          MoneyInputField(controller: costCtrl, label: 'Giá nhập'),
          const SizedBox(height: 8),
          MoneyInputField(controller: unitPriceCtrl, label: 'Giá thay khách lẻ'),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ]),
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => nameCtrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            if (nameCtrl.text.trim().isEmpty) {
              setStateDialog(() => error = 'Vui lòng nhập tên linh kiện.');
              return;
            }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SupabaseService.client
                  .from('inventory_parts')
                  .insert({
                    'store_id': storeId,
                    'name': nameCtrl.text.trim(),
                    'sku': sku,
                    'category_id': categoryId,
                    'quantity': 0,
                    'unit_cost': num.tryParse(costCtrl.text.trim()) ?? 0,
                    'unit_price': num.tryParse(unitPriceCtrl.text.trim()) ?? 0,
                  })
                  .select()
                  .single();
              await AppLogger.instance.action(
                'Thêm linh kiện mới "${nameCtrl.text.trim()}"',
                category: 'kho',
                data: {'sku': sku, 'cost': num.tryParse(costCtrl.text.trim()) ?? 0, 'price': num.tryParse(unitPriceCtrl.text.trim()) ?? 0},
              );
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; });
            }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Thêm'),
        ),
      ),
    );
  }

  Future<void> _showEditPartDialog(Map<String, dynamic> part) async {
    final nameCtrl = TextEditingController(text: part['name'] ?? '');
    final costCtrl = TextEditingController(text: (part['unit_cost'] as num?)?.toStringAsFixed(0) ?? '0');
    final unitPriceCtrl = TextEditingController(text: (part['unit_price'] as num?)?.toStringAsFixed(0) ?? '0');
    final barcodeCtrl = TextEditingController(text: part['barcode'] ?? '');
    final imeiCtrl = TextEditingController(text: part['imei'] ?? '');
    final thresholdCtrl = TextEditingController(text: (part['low_stock_threshold'] as int?)?.toString() ?? '3');
    final nccCtrl = TextEditingController(text: part['supplier_name'] ?? '');
    String? supplierId = part['supplier_id'] as String?;
    String? categoryId = part['category_id'] as String?;
    bool saving = false;
    String? error;
    final storeId = await _currentStoreId();

    if (!mounted) return;
    await showAdaptiveFormDialog(
      context: context,
      title: 'Sửa linh kiện',
      contentBuilder: (ctx, setStateDialog) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Mã linh kiện'),
            child: Text(part['sku'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
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
                    key: ValueKey('cat_edit_${categories.length}_$categoryId'),
                    initialValue: safeValue,
                    decoration: InputDecoration(
                      labelText: 'Danh mục',
                      suffixIcon: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () async {
                          final newId = await _showAddCategoryDialog(ctx, storeId);
                          if (newId != null) setStateDialog(() => categoryId = newId);
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
                    onChanged: (v) => setStateDialog(() => categoryId = v),
                  );
                },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: barcodeCtrl, decoration: const InputDecoration(labelText: 'Mã vạch'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: imeiCtrl, decoration: const InputDecoration(labelText: 'IMEI'))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(
              controller: thresholdCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Cảnh báo tồn'),
            )),
          ]),
          const SizedBox(height: 8),
          MoneyInputField(controller: costCtrl, label: 'Giá nhập'),
          const SizedBox(height: 8),
          MoneyInputField(controller: unitPriceCtrl, label: 'Giá thay khách lẻ'),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: nccCtrl,
                decoration: InputDecoration(
                  labelText: 'Nhập từ NCC (tùy chọn)',
                  hintText: 'Tên nhà cung cấp',
                  prefixIcon: const Icon(Icons.business_outlined),
                  suffixIcon: (supplierId != null || nccCtrl.text.trim().isNotEmpty)
                      ? IconButton(
                          tooltip: 'Bỏ chọn NCC',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setStateDialog(() {
                            supplierId = null;
                            nccCtrl.clear();
                          }),
                        )
                      : null,
                ),
                onChanged: (_) => setStateDialog(() {}),
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
                    setStateDialog(() {
                      supplierId = s['id'] as String?;
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
        ]),
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => nameCtrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            if (nameCtrl.text.trim().isEmpty) {
              setStateDialog(() => error = 'Vui lòng nhập tên linh kiện.');
              return;
            }
            setStateDialog(() { saving = true; error = null; });
            try {
              await SupabaseService.client
                  .from('inventory_parts')
                  .update({
                    'name': nameCtrl.text.trim(),
                    'category_id': categoryId,
                    'unit_cost': num.tryParse(costCtrl.text.trim()) ?? 0,
                    'unit_price': num.tryParse(unitPriceCtrl.text.trim()) ?? 0,
                    'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                    'imei': imeiCtrl.text.trim().isEmpty ? null : imeiCtrl.text.trim(),
                    'low_stock_threshold': int.tryParse(thresholdCtrl.text.trim()) ?? 3,
                    'supplier_id': supplierId,
                    'supplier_name': nccCtrl.text.trim().isEmpty ? null : nccCtrl.text.trim(),
                    'updated_at': DateTime.now().toIso8601String(),
                  })
                  .eq('id', part['id']);
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; });
            }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Lưu'),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  /// Xem thẻ linh kiện: chỉ thấy giá thay khách lẻ trên thẻ — mở thẻ mới thấy
  /// giá nhập + thông tin chi tiết, kèm các nhanh Nhập kho / Sửa / Xóa.
  Future<void> _showPartDetailDialog(Map<String, dynamic> p, Map<String, String> catNames) async {
    final qty = p['quantity'] as int? ?? 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p['name'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _detailRow('Mã linh kiện', p['sku'] ?? '-'),
            _detailRow('Danh mục', catNames[p['category_id'] as String?] ?? 'Chưa phân loại'),
            _detailRow('Tồn kho', '$qty'),
            _detailRow('Giá nhập', _currency.format(p['unit_cost'] ?? 0)),
            _detailRow('Giá thay khách lẻ', _currency.format(p['unit_price'] ?? 0)),
            if ((p['supplier_name'] ?? '').toString().isNotEmpty)
              _detailRow('Nhà cung cấp', p['supplier_name'].toString()),
            if ((p['barcode'] ?? '').toString().isNotEmpty)
              _detailRow('Mã vạch', p['barcode'].toString()),
            if ((p['imei'] ?? '').toString().isNotEmpty)
              _detailRow('IMEI', p['imei'].toString()),
            _detailRow('Cảnh báo tồn', '${p['low_stock_threshold'] ?? 3}'),
          ]),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _selectedPartIds..clear()..add(p['id'] as String));
              await _confirmDeleteParts([p]);
            },
            child: const Text('Xóa'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showEditPartDialog(p);
            },
            child: const Text('Sửa'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1D4ED8)),
            onPressed: () {
              Navigator.pop(ctx);
              _showRestockPartDialog(p);
            },
            icon: const Icon(Icons.add_shopping_cart, size: 18),
            label: const Text('Nhập kho'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRestockPartDialog(Map<String, dynamic> part) async {
    final currentQty = part['quantity'] as int? ?? 0;
    final currentCost = part['unit_cost'] as num? ?? 0;
    final qtyCtrl = TextEditingController(text: '1');
    final costCtrl = TextEditingController(text: currentCost.toStringAsFixed(0));    final nccCtrl = TextEditingController();
    Map<String, dynamic>? selectedSupplier;
    bool saving = false;
    String? error;
    final storeId = await _currentStoreId();

    if (!mounted) return;
    await showAdaptiveFormDialog(
      context: context,
      title: 'Nhập thêm: ${part['name'] ?? ''}',
      contentBuilder: (ctx, setStateDialog) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Đang tồn: $currentQty · Giá nhập hiện tại: ${_currency.format(currentCost)}',
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 12),
        TextField(
          controller: qtyCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Số lượng nhập thêm *'),
        ),
        const SizedBox(height: 8),
        MoneyInputField(controller: costCtrl, label: 'Đơn giá nhập'),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: nccCtrl,
              decoration: const InputDecoration(
                labelText: 'Nhập từ NCC (tùy chọn)',
                hintText: 'Tên nhà cung cấp',
                prefixIcon: Icon(Icons.business_outlined),
              ),
              onChanged: (_) => setStateDialog(() {}),
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
                  setStateDialog(() {
                    selectedSupplier = s;
                    nccCtrl.text = (s['contact_name'] ?? '').toString();
                  });
                }
              },
              icon: const Icon(Icons.list_alt),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1D4ED8).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Builder(builder: (context) {
            final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
            final cost = num.tryParse(costCtrl.text.trim()) ?? 0;
            final total = qty * cost;
            return Text(
              'Thành tiền: ${_currency.format(total)}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1D4ED8)),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text('Sau khi nhập: tồn kho sẽ là ${currentQty + (int.tryParse(qtyCtrl.text.trim()) ?? 0)}',
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ]),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => (int.tryParse(qtyCtrl.text.trim()) ?? 0) > 0,
        primaryButton: ElevatedButton(
          onPressed: saving ? null : () async {
            final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
            if (qty <= 0) {
              setStateDialog(() => error = 'Số lượng nhập phải lớn hơn 0.');
              return;
            }
            setStateDialog(() { saving = true; error = null; });
            try {
              final cost = num.tryParse(costCtrl.text.trim()) ?? 0;
              final newQty = currentQty + qty;
              final total = cost * qty;
              final hasSupplier = nccCtrl.text.trim().isNotEmpty;
              final supplierNote = hasSupplier ? ' · NCC: ${nccCtrl.text.trim()}' : '';
              await SupabaseService.client.from('inventory_parts').update({
                'quantity': newQty,
                'unit_cost': cost,
                'updated_at': DateTime.now().toIso8601String(),
              }).eq('id', part['id']);
              await SupabaseService.client.from('inventory_transactions').insert({
                'store_id': storeId,
                'part_id': part['id'],
                'type': 'in',
                'quantity': qty,
                'note': 'Nhập thêm${cost > 0 ? ' · giá $cost' : ''}$supplierNote',
                'created_by': SupabaseService.currentUser?.id ?? '',
              });

              String? payChoice;
              if (total > 0 && ctx.mounted) {
                payChoice = await showDialog<String>(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    title: const Text('Thanh toán linh kiện'),
                    content: Text(
                      'Nhập thêm "${part['name'] ?? ''}" x$qty = ${_currency.format(total)}.\n'
                      '${hasSupplier ? 'Nhà cung cấp: ${nccCtrl.text.trim()}\n' : ''}'
                      'Thanh toán bằng?',
                      textAlign: TextAlign.center,
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dctx, 'cash'), child: const Text('Tiền mặt')),
                      TextButton(onPressed: () => Navigator.pop(dctx, 'transfer'), child: const Text('Chuyển khoản')),
                      if (hasSupplier) TextButton(onPressed: () => Navigator.pop(dctx, 'debt'), child: const Text('Nợ NCC')),
                      TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Bỏ qua')),
                    ],
                  ),
                );
              }

              if (payChoice == 'debt') {
                final contactName = nccCtrl.text.trim();
                if (selectedSupplier != null) {
                  final cur = (selectedSupplier!['total_debt'] as num?) ?? 0;
                  await SupabaseService.client.from('debts')
                      .update({'total_debt': cur + total}).eq('id', selectedSupplier!['id']);
                  await SupabaseService.client.from('debt_transactions').insert({
                    'store_id': storeId, 'debt_id': selectedSupplier!['id'], 'type': 'add',
                    'amount': total, 'description': 'Nhập linh kiện ${part['name'] ?? ''} x$qty',
                    'created_by': SupabaseService.currentUser?.id ?? '',
                  });
                } else {
                  final debt = await SupabaseService.client.from('debts').insert({
                    'store_id': storeId, 'type': 'supplier', 'contact_name': contactName,
                    'total_debt': total, 'note': 'Nhập linh kiện ${part['name'] ?? ''}',
                  }).select('id').single();
                  await SupabaseService.client.from('debt_transactions').insert({
                    'store_id': storeId, 'debt_id': debt['id'], 'type': 'add',
                    'amount': total, 'description': 'Nhập linh kiện ${part['name'] ?? ''} x$qty',
                    'created_by': SupabaseService.currentUser?.id ?? '',
                  });
                }
                await notifyWholeStore(
                  storeId: storeId,
                  title: 'Nợ NCC ${_currency.format(total)}',
                  body: 'Nhập linh kiện ${part['name'] ?? ''} x$qty · $contactName',
                  data: {'finance': true, 'type': 'debt', 'category': 'Nợ NCC'},
                );
              } else if (payChoice == 'cash' || payChoice == 'transfer') {
                final acct = await _ensureAccount(storeId, payChoice == 'cash' ? 'cash' : 'bank');
                await SupabaseService.client.from('transactions').insert({
                  'store_id': storeId,
                  'type': 'expense',
                  'category': 'Linh kiện',
                  'amount': total,
                  'description': 'Nhập thêm ${part['name'] ?? ''} x$qty$supplierNote',
                  'created_by': SupabaseService.currentUser?.id ?? '',
                  if (acct != null) 'account_id': acct['id'],
                  'transaction_date': DateTime.now().toIso8601String(),
                });
                if (acct != null) {
                  await SupabaseService.client.from('cash_accounts')
                      .update({'balance': ((acct['balance'] as num?) ?? 0) - total})
                      .eq('id', acct['id']);
                }
                await notifyWholeStore(
                  storeId: storeId,
                  title: 'Chi linh kiện ${_currency.format(total)}',
                  body: 'Nhập thêm ${part['name'] ?? ''} x$qty · ${payChoice == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'}$supplierNote',
                  data: {'finance': true, 'type': 'expense', 'category': 'Linh kiện'},
                );
              }
              await AppLogger.instance.action(
                'Nhập thêm "${part['name'] ?? ''}" x$qty',
                category: 'kho',
                data: {'part_id': part['id'], 'qty': qty, 'cost_total': total, 'pay': payChoice, 'supplier': nccCtrl.text.trim()},
              );
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; });
            }
          },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Nhập kho'),
        ),
      ),
    );
  }

  /// Nhập kho nhiều linh kiện: ô "Thêm linh kiện" (gõ tên có gợi ý auto) có
  /// dấu + ở cuối — bấm vào load danh sách linh kiện có sẵn để chọn. Sửa giá
  /// nhập / giá thay tại đây sẽ cập nhật luôn giá của linh kiện (bảng giá).
  Future<void> _showStockInDialog() async {
    final storeId = await _currentStoreId();
    if (!mounted) return;
    final items = <Map<String, dynamic>>[]; // {id, name, qtyCtrl, costCtrl, priceCtrl}
    final nccCtrl = TextEditingController();
    Map<String, dynamic>? selectedSupplier;
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Nhập kho',
      desktopWidth: 620,
      onEscCancel: (dlgCtx) async {
        if (saving) return;
        if (dlgCtx.mounted) Navigator.pop(dlgCtx);
      },
      escIsDirty: () => items.isNotEmpty || nccCtrl.text.trim().isNotEmpty,
      contentBuilder: (ctx, setStateDialog) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: autoReconnectStream(
            () => SupabaseService.client.from('inventory_parts').stream(primaryKey: ['id']).order('name'),
            label: 'inventory_parts_stockin'),
        builder: (context, snap) {
          final allParts = (snap.data ?? []).where((p) => p['deleted_at'] == null).toList();
          final labels = <String, Map<String, dynamic>>{
            for (final p in allParts) '${p['name'] ?? ''} (${p['sku'] ?? '-'})': p,
          };

          void addItem(Map<String, dynamic> p, {int qty = 1}) {
            final id = p['id'] as String;
            if (items.any((it) => it['id'] == id)) return;
            setStateDialog(() {
              items.add({
                'id': id,
                'name': p['name'] ?? '',
                'stock': p['quantity'] as int? ?? 0,
                'qtyCtrl': TextEditingController(text: '$qty'),
                'costCtrl': TextEditingController(text: ((p['unit_cost'] as num?) ?? 0).toStringAsFixed(0)),
                'priceCtrl': TextEditingController(text: ((p['unit_price'] as num?) ?? 0).toStringAsFixed(0)),
              });
            });
          }

          return SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Autocomplete<String>(
                optionsBuilder: (v) {
                  if (v.text.trim().isEmpty) return const Iterable<String>.empty();
                  final q = v.text.toLowerCase();
                  return labels.keys.where((l) => l.toLowerCase().contains(q)).take(10);
                },
                onSelected: (label) => addItem(labels[label]!),
                displayStringForOption: (label) => label,
                fieldViewBuilder: (context, ctrl, focusNode, onSubmit) {
                  return TextField(
                    controller: ctrl,
                    focusNode: focusNode,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => onSubmit(),
                    decoration: InputDecoration(
                      labelText: 'Thêm linh kiện',
                      hintText: 'Gõ tên linh kiện...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: 'Chọn từ danh sách linh kiện có sẵn',
                        icon: const Icon(Icons.add),
                        onPressed: () async {
                          final picked = await _showStockInPartPicker(ctx, allParts, items);
                          if (picked != null && picked.isNotEmpty) {
                            setStateDialog(() {
                              for (final (p, q) in picked) {
                                addItem(p, qty: q);
                              }
                            });
                          }
                        },
                      ),
                    ),
                  );
                },
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Chưa có linh kiện nào. Gõ tên hoặc bấm dấu + để chọn từ kho.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
                ),
              for (final it in items) ...[
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(children: [
                      Row(children: [
                        Expanded(
                          child: Text(it['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                        Text('Tồn: ${it['stock'] ?? 0}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black54)),
                        IconButton(
                          tooltip: 'Bỏ linh kiện',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setStateDialog(() => items.remove(it)),
                          icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.red),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(flex: 2, child: TextField(
                          controller: it['qtyCtrl'] as TextEditingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'SL', isDense: true),
                          onChanged: (_) => setStateDialog(() {}),
                        )),
                        const SizedBox(width: 8),
                        Expanded(flex: 3, child: TextField(
                          controller: it['costCtrl'] as TextEditingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Giá nhập', isDense: true),
                          onChanged: (_) => setStateDialog(() {}),
                        )),
                        const SizedBox(width: 8),
                        Expanded(flex: 3, child: TextField(
                          controller: it['priceCtrl'] as TextEditingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Giá thay', isDense: true),
                          onChanged: (_) => setStateDialog(() {}),
                        )),
                      ]),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextField(
                    controller: nccCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nhà cung cấp (tùy chọn)',
                      hintText: 'Tên nhà cung cấp',
                      prefixIcon: Icon(Icons.business_outlined),
                    ),
                    onChanged: (_) => setStateDialog(() {}),
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
                        setStateDialog(() {
                          selectedSupplier = s;
                          nccCtrl.text = (s['contact_name'] ?? '').toString();
                        });
                      }
                    },
                    icon: const Icon(Icons.list_alt),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Builder(builder: (context) {
                num total = 0;
                for (final it in items) {
                  final qty = int.tryParse((it['qtyCtrl'] as TextEditingController).text.trim()) ?? 0;
                  final cost = num.tryParse((it['costCtrl'] as TextEditingController).text.trim()) ?? 0;
                  total += qty * cost;
                }
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1D4ED8).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('Thành tiền: ${_currency.format(total)} · ${items.length} linh kiện',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1D4ED8))),
                );
              }),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ]),
          );
        },
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: saving ? null : () => Navigator.pop(ctx),
        isDirty: () => items.isNotEmpty || nccCtrl.text.trim().isNotEmpty,
        primaryButton: ElevatedButton(
          onPressed: saving
              ? null
              : () async {
                  final valid = items.where((it) {
                    final qty = int.tryParse((it['qtyCtrl'] as TextEditingController).text.trim()) ?? 0;
                    return qty > 0;
                  }).toList();
                  if (valid.isEmpty) {
                    setStateDialog(() => error = 'Nhập số lượng > 0 cho ít nhất 1 linh kiện.');
                    return;
                  }
                  num total = 0;
                  for (final it in valid) {
                    final qty = int.tryParse((it['qtyCtrl'] as TextEditingController).text.trim()) ?? 0;
                    final cost = num.tryParse((it['costCtrl'] as TextEditingController).text.trim()) ?? 0;
                    total += qty * cost;
                  }
                  setStateDialog(() { saving = true; error = null; });
                  try {
                    final uid = SupabaseService.currentUser?.id ?? '';
                    final hasSupplier = nccCtrl.text.trim().isNotEmpty;
                    final supplierNote = hasSupplier ? ' · NCC: ${nccCtrl.text.trim()}' : '';
                    String? payChoice;
                    if (total > 0 && ctx.mounted) {
                      payChoice = await showDialog<String>(
                        context: ctx,
                        builder: (dctx) => AlertDialog(
                          title: const Text('Thanh toán linh kiện'),
                          content: Text(
                            'Nhập kho ${valid.length} linh kiện = ${_currency.format(total)}.\n'
                            '${hasSupplier ? 'Nhà cung cấp: ${nccCtrl.text.trim()}\n' : ''}'
                            'Thanh toán bằng?',
                            textAlign: TextAlign.center,
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dctx, 'cash'), child: const Text('Tiền mặt')),
                            TextButton(onPressed: () => Navigator.pop(dctx, 'transfer'), child: const Text('Chuyển khoản')),
                            if (hasSupplier) TextButton(onPressed: () => Navigator.pop(dctx, 'debt'), child: const Text('Nợ NCC')),
                            TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Bỏ qua')),
                          ],
                        ),
                      );
                    }
                    final now = DateTime.now().toIso8601String();
                    final detail = valid
                        .map((it) => '${it['name']} x${int.tryParse((it['qtyCtrl'] as TextEditingController).text.trim()) ?? 0}')
                        .join(', ');
                    for (final it in valid) {
                      final qty = int.tryParse((it['qtyCtrl'] as TextEditingController).text.trim()) ?? 0;
                      final cost = num.tryParse((it['costCtrl'] as TextEditingController).text.trim()) ?? 0;
                      final price = num.tryParse((it['priceCtrl'] as TextEditingController).text.trim()) ?? 0;
                      final curRow = await SupabaseService.client
                          .from('inventory_parts')
                          .select('quantity')
                          .eq('id', it['id'] as String)
                          .single();
                      final cur = (curRow['quantity'] as int?) ?? 0;
                      await SupabaseService.client
                          .from('inventory_parts')
                          .update({
                            'quantity': cur + qty,
                            'unit_cost': cost,
                            'unit_price': price,
                            'updated_at': now,
                          })
                          .eq('id', it['id'] as String);
                      await SupabaseService.client.from('inventory_transactions').insert({
                        'store_id': storeId,
                        'part_id': it['id'] as String,
                        'type': 'in',
                        'quantity': qty,
                        'note': 'Nhập kho$supplierNote',
                        'created_by': uid,
                      });
                    }

                    if (payChoice == 'debt') {
                      final contactName = nccCtrl.text.trim();
                      if (selectedSupplier != null) {
                        final cur = (selectedSupplier!['total_debt'] as num?) ?? 0;
                        await SupabaseService.client.from('debts')
                            .update({'total_debt': cur + total}).eq('id', selectedSupplier!['id']);
                        await SupabaseService.client.from('debt_transactions').insert({
                          'store_id': storeId, 'debt_id': selectedSupplier!['id'], 'type': 'add',
                          'amount': total, 'description': 'Nhập kho linh kiện: $detail',
                          'created_by': uid,
                        });
                      } else {
                        final debt = await SupabaseService.client.from('debts').insert({
                          'store_id': storeId, 'type': 'supplier', 'contact_name': contactName,
                          'total_debt': total, 'note': 'Nhập kho linh kiện: $detail',
                        }).select('id').single();
                        await SupabaseService.client.from('debt_transactions').insert({
                          'store_id': storeId, 'debt_id': debt['id'], 'type': 'add',
                          'amount': total, 'description': 'Nhập kho linh kiện: $detail',
                          'created_by': uid,
                        });
                      }
                      await notifyWholeStore(
                        storeId: storeId,
                        title: 'Nợ NCC ${_currency.format(total)}',
                        body: 'Nhập kho $detail · $contactName',
                        data: {'finance': true, 'type': 'debt', 'category': 'Nợ NCC'},
                      );
                    } else if (payChoice == 'cash' || payChoice == 'transfer') {
                      final acct = await _ensureAccount(storeId, payChoice == 'cash' ? 'cash' : 'bank');
                      await SupabaseService.client.from('transactions').insert({
                        'store_id': storeId,
                        'type': 'expense',
                        'category': 'Linh kiện',
                        'amount': total,
                        'description': 'Nhập kho linh kiện: $detail$supplierNote',
                        'created_by': uid,
                        if (acct != null) 'account_id': acct['id'],
                        'transaction_date': DateTime.now().toIso8601String(),
                      });
                      if (acct != null) {
                        await SupabaseService.client.from('cash_accounts')
                            .update({'balance': ((acct['balance'] as num?) ?? 0) - total})
                            .eq('id', acct['id']);
                      }
                      await notifyWholeStore(
                        storeId: storeId,
                        title: 'Chi linh kiện ${_currency.format(total)}',
                        body: 'Nhập kho $detail · ${payChoice == 'cash' ? 'Tiền mặt' : 'Chuyển khoản'}$supplierNote',
                        data: {'finance': true, 'type': 'expense', 'category': 'Linh kiện'},
                      );
                    }
                    await AppLogger.instance.action(
                      'Nhập kho ${valid.length} linh kiện',
                      category: 'kho',
                      data: {'items': valid.length, 'cost_total': total, 'pay': payChoice, 'supplier': nccCtrl.text.trim()},
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; });
                  }
                },
          child: saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
              : const Text('Nhập kho'),
        ),
      ),
    );
  }

  /// Bottom sheet chọn nhiều linh kiện có sẵn trong kho — mở từ dấu + của ô
  /// "Thêm linh kiện" trong dialog nhập kho.
  Future<List<(Map<String, dynamic>, int)>?> _showStockInPartPicker(
      BuildContext parentCtx, List<Map<String, dynamic>> allParts, List<Map<String, dynamic>> items) async {
    final searchCtrl = TextEditingController();
    final alreadyIds = items.map((it) => it['id'] as String).toSet();
    final picked = <String, int>{};
    return showModalBottomSheet<List<(Map<String, dynamic>, int)>>(
      context: parentCtx,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.92,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: searchCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Tìm linh kiện trong kho',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setSheet(() {}),
                ),
              ),
              Expanded(
                child: Builder(builder: (context) {
                  final q = searchCtrl.text.trim().toLowerCase();
                  final visible = q.isEmpty
                      ? allParts
                      : allParts
                          .where((p) => (p['name'] ?? '').toString().toLowerCase().contains(q))
                          .toList();
                  if (visible.isEmpty) return const Center(child: Text('Không tìm thấy linh kiện.'));
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final p = visible[i];
                      final id = p['id'] as String;
                      final already = alreadyIds.contains(id);
                      final qty = picked[id] ?? 0;
                      final pStock = p['quantity'] as int? ?? 0;
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: pStock <= 0 ? Colors.red.shade100 : Colors.blueGrey.shade100,
                          child: Icon(Icons.memory, size: 14, color: pStock <= 0 ? Colors.red.shade700 : Colors.black54),
                        ),
                        title: Text(p['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          'Tồn: $pStock · Nhập: ${_currency.format(p['unit_cost'] ?? 0)} · Thay: ${_currency.format(p['unit_price'] ?? 0)}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        trailing: already
                            ? const Text('Đã thêm', style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w600))
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.remove_circle_outline),
                                  onPressed: qty > 0 ? () => setSheet(() => picked[id] = qty - 1) : null,
                                ),
                                Text('$qty', style: const TextStyle(fontWeight: FontWeight.w600)),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => setSheet(() => picked[id] = qty + 1),
                                ),
                              ]),
                      );
                    },
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      final selected = <(Map<String, dynamic>, int)>[
                        for (final p in allParts)
                          if ((picked[p['id']] ?? 0) > 0) (p, picked[p['id']]!),
                      ];
                      Navigator.pop(ctx, selected);
                    },
                    child: Text('Thêm ${picked.values.where((v) => v > 0).length} linh kiện'),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _editSelectedPart(List<Map<String, dynamic>> rows) async {
    final selected = rows.where((p) => _selectedPartIds.contains(p['id'])).toList();
    if (selected.length != 1) return;
    await _showEditPartDialog(selected.first);
    if (mounted) setState(() => _selectedPartIds.clear());
  }

  Future<void> _confirmDeleteParts(List<Map<String, dynamic>> rows) async {
    final selected = rows.where((p) => _selectedPartIds.contains(p['id'])).toList();
    if (selected.isEmpty) return;
    final selectedIds = selected.map((p) => p['id'] as String).toList();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Xóa ${selected.length} linh kiện?'),
        content: Text(
          selected.map((p) => '${p['name'] ?? ''} (${p['quantity'] ?? 0})').join('\n'),
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // Kiểm tra linh kiện đang được dùng trong đơn sửa chưa hoàn thành.
    final activeNotices = <String>[];
    final finishedOrderIds = <String>{};
    try {
      final txs = await SupabaseService.client
          .from('inventory_transactions')
          .select('part_id, repair_order_id, repair_orders(id, code, status)')
          .inFilter('part_id', selectedIds)
          .eq('type', 'out')
          .not('repair_order_id', 'is', null);
      for (final t in txs as List) {
        final o = t['repair_orders'] as Map<String, dynamic>?;
        if (o == null) continue; // đơn đã bị xóa
        final status = o['status'] as String?;
        final pid = t['part_id'] as String;
        final name = selected.firstWhere((p) => p['id'] == pid)['name'] ?? 'Linh kiện';
        if (status == 'delivered' || status == 'cancelled') {
          finishedOrderIds.add(o['id'] as String);
        } else {
          activeNotices.add('• $name — đang dùng trong đơn ${o['code']}');
        }
      }
    } catch (_) {}

    if (activeNotices.isNotEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Không thể xóa linh kiện'),
          content: Text(
            'Các linh kiện sau đang được sử dụng trong đơn sửa chưa hoàn thành:\n\n'
            '${activeNotices.join('\n')}\n\n'
            'Vui lòng bỏ linh kiện ra khỏi đơn trước khi xóa.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
          ],
        ),
      );
      return;
    }

    // Các đơn đã xong vẫn còn công nợ: thông báo nhưng cho phép xóa.
    if (finishedOrderIds.isNotEmpty) {
      final debtOrderIds = <String>{};
      try {
        final tx = await SupabaseService.client
            .from('transactions')
            .select('repair_order_id')
            .inFilter('repair_order_id', finishedOrderIds.toList())
            .not('debt_id', 'is', null)
            .isFilter('deleted_at', null);
        for (final t in tx as List) {
          final oid = t['repair_order_id'] as String?;
          if (oid != null) debtOrderIds.add(oid);
        }
      } catch (_) {}
      if (debtOrderIds.isNotEmpty) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Linh kiện liên quan công nợ'),
            content: Text(
              'Các đơn sau đang có công nợ chưa tất toán:\n\n'
              '${debtOrderIds.join('\n')}\n\n'
              'Linh kiện vẫn có thể xóa (các phiếu thu chi/công nợ của đơn được giữ nguyên).',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Vẫn xóa'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
      }
    }

    try {
      final now = DateTime.now().toIso8601String();
      for (final p in selected) {
        await SupabaseService.client.from('inventory_parts').update({
          'deleted_at': now,
          'updated_at': now,
        }).eq('id', p['id']);
      }
      if (mounted) {
        setState(() {
          _locallyDeletedPartIds.addAll(selectedIds);
          _selectedPartIds.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.appBarLeading,
        title: _showSearch
            ? TextField(
                controller: _searchCtrl,                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Tìm theo tên, mã LK...',
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Kho linh kiện'),
        actions: [
          IconButton(
            icon: const Icon(Icons.compare_arrows),
            tooltip: 'Kiểm kho',
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _StockCountScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.percent),
            tooltip: 'Đổi giá hàng loạt',
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _BulkPriceUpdateScreen(),
            )),
          ),
          IconButton(
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) _searchCtrl.clear();
            }),
          ),
          const NotificationBell(),
          const SizedBox(width: 4),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _catStream,
        builder: (context, catSnap) {
          final catNames = <String, String>{
            for (final c in catSnap.data ?? []) c['id'] as String: (c['name'] ?? '') as String,
          };
          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _inStream,
            builder: (context, inSnap) {
              final lastInByPart = <String, Map<String, dynamic>>{};
              for (final t in inSnap.data ?? []) {
                final pid = t['part_id'];
                if (pid != null && !lastInByPart.containsKey(pid)) lastInByPart[pid] = t;
              }
              return RealtimeStreamView<List<Map<String, dynamic>>>(
                stream: _stream,
                builder: (context, allRows) {
                  var rows = allRows.where((r) {
                    if (r['deleted_at'] != null) return false;
                    if (_locallyDeletedPartIds.contains(r['id'])) return false;
                    return true;
                  }).toList();
                  final q = _searchCtrl.text.trim().toLowerCase();
                  if (q.isNotEmpty) {
                    final extraFields = ['barcode'];
                    rows = rows.where((p) {
                      final text = [
                        p['name'], p['sku'],
                        for (final f in extraFields) p[f],
                      ].join(' ').toLowerCase();
                      return text.contains(q);
                    }).toList();
                  }
                  final outCount = rows.where((p) => (p['quantity'] as int? ?? 0) <= 0).length;
                  final lowCount = rows.where((p) {
                    final qty = p['quantity'] as int? ?? 0;
                    final threshold = p['low_stock_threshold'] as int? ?? 3;
                    return qty > 0 && qty < threshold;
                  }).length;

                  if (rows.isEmpty) return const Center(child: Text('Kho trống.'));

                  return Column(
                    children: [
                      if (outCount + lowCount > 0)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          color: Colors.red.shade50,
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded, color: Colors.red.shade700, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${outCount > 0 && lowCount > 0 ? '$outCount hết, $lowCount sắp hết' : outCount > 0 ? '$outCount hết hàng' : '$lowCount sắp hết'} — cần nhập thêm',
                                  style: TextStyle(color: Colors.red.shade700, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_selectedPartIds.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          color: Colors.blue.shade50,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text('Đã chọn ${_selectedPartIds.length} linh kiện',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.blue.shade800)),
                              ),
                              if (_selectedPartIds.length == 1)
                                TextButton.icon(
                                  onPressed: () => _editSelectedPart(rows),
                                  icon: const Icon(Icons.edit, size: 16),
                                  label: const Text('Sửa'),
                                ),
                              TextButton.icon(
                                onPressed: () => _confirmDeleteParts(rows),
                                icon: const Icon(Icons.delete_outline, size: 16),
                                label: const Text('Xóa'),
                              ),
                              TextButton.icon(
                                onPressed: () => setState(() => _selectedPartIds.clear()),
                                icon: const Icon(Icons.close, size: 16),
                                label: const Text('Hủy chọn'),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _selectedPartIds.clear()),
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final p = rows[i];
                              final selected = _selectedPartIds.contains(p['id']);
                              final qty = p['quantity'] as int? ?? 0;
                              final threshold = p['low_stock_threshold'] as int? ?? 3;
                              final outOfStock = qty <= 0;
                              final low = !outOfStock && qty < threshold;
                              final warnColor = outOfStock ? Colors.red : Colors.orange;
                              final hasStock = qty > 0;
                              final price = p['unit_price'] as num? ?? 0;
                              final lastIn = lastInByPart[p['id']];
                              final createdRaw = lastIn?['created_at'];
                              String lastInText;
                              if (createdRaw == null) {
                                lastInText = hasStock ? '' : 'Chưa nhập';
                              } else {
                                try {
                                  lastInText = 'Nhập: ${DateFormat('dd/MM').format(DateTime.parse(createdRaw as String))}';
                                } catch (_) {
                                  lastInText = 'Đã nhập kho';
                                }
                              }

                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 3),
                                clipBehavior: Clip.antiAlias,
                                color: const Color(0xFFF1F5F9),
                                child: InkWell(
                                  onTap: () => _showPartDetailDialog(p, catNames),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: selected ? Colors.blue.shade50 : null,
                                      border: outOfStock
                                          ? const Border(left: BorderSide(color: Colors.red, width: 3))
                                          : low
                                              ? const Border(left: BorderSide(color: Colors.orange, width: 3))
                                              : null,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Row(
                                        children: [
                                          Tooltip(
                                            message: 'Chọn linh kiện',
                                            child: InkWell(
                                              customBorder: const CircleBorder(),
                                              onTap: () => setState(() {
                                                if (!_selectedPartIds.add(p['id'] as String)) {
                                                  _selectedPartIds.remove(p['id']);
                                                }
                                              }),
                                              child: CircleAvatar(
                                                radius: 14,
                                                backgroundColor: selected ? const Color(0xFF2563EB) : Colors.blueGrey.shade100,
                                                child: Icon(
                                                  selected ? Icons.check : Icons.memory,
                                                  size: 14,
                                                  color: selected ? Colors.white : Colors.black54,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            flex: 2,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  p['name'] ?? '',
                                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontWeight: hasStock ? FontWeight.w800 : FontWeight.w400,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  'Mã: ${p['sku'] ?? '-'} · ${catNames[p['category_id'] as String?] ?? 'Chưa phân loại'}',
                                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(fontSize: 10.5, color: Colors.black54),
                                                ),
                                                const SizedBox(height: 3),
                                                Row(
                                                  children: [
                                                    const Text('Thay: ', style: TextStyle(fontSize: 11, color: Colors.black54)),
                                                    Text(
                                                      _currency.format(price),
                                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1D4ED8)),
                                                    ),
                                                    if (outOfStock || low) ...[
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                        decoration: BoxDecoration(
                                                          color: warnColor,
                                                          borderRadius: BorderRadius.circular(8),
                                                        ),
                                                        child: Text(outOfStock ? 'Hết' : 'Sắp hết',
                                                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(width: 1, height: 36, color: Colors.black12),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            flex: 1,
                                            child: Column(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                Text(
                                                  'Tồn: $qty',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: (outOfStock || low) ? FontWeight.w800 : FontWeight.w500,
                                                    color: outOfStock
                                                        ? Colors.red
                                                        : low
                                                            ? Colors.orange.shade800
                                                            : Colors.black87,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  lastInText,
                                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(fontSize: 10, color: hasStock ? Colors.black54 : Colors.orange.shade800),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'add_part_fab',
            backgroundColor: Colors.blueGrey,
            onPressed: _showAddPartDialog,
            icon: const Icon(Icons.playlist_add),
            label: const Text('Thêm LK'),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'stock_in_fab',
            onPressed: _showStockInDialog,
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('Nhập kho'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Kiểm kho & Cân bằng
// =============================================================================
class _StockCountScreen extends StatefulWidget {
  const _StockCountScreen();

  @override
  State<_StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends State<_StockCountScreen> {
  final _counts = <String, TextEditingController>{};
  final _damaged = <String, TextEditingController>{};
  final _lost = <String, TextEditingController>{};
  final _notes = <String, TextEditingController>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _counts.values) { c.dispose(); }
    for (final c in _damaged.values) { c.dispose(); }
    for (final c in _lost.values) { c.dispose(); }
    for (final c in _notes.values) { c.dispose(); }
    super.dispose();
  }

  String? _storeId;

  Future<void> _confirmAdjust() async {
    final storeId = _storeId;
    if (storeId == null) return;

    final adjustments = <Map<String, dynamic>>[];
    for (final entry in _counts.entries) {
      final partId = entry.key;
      final actualQty = int.tryParse(entry.value.text.trim());
      if (actualQty == null) continue;
      final systemQty = _systemQtys[partId] ?? 0;
      final diff = actualQty - systemQty;
      if (diff == 0 && _damaged[partId]?.text.trim().isEmpty != false && _lost[partId]?.text.trim().isEmpty != false) continue;
      adjustments.add({
        'part_id': partId,
        'system_qty': systemQty,
        'actual_qty': actualQty,
        'diff_qty': diff,
        'damaged_qty': int.tryParse(_damaged[partId]?.text.trim() ?? '') ?? 0,
        'lost_qty': int.tryParse(_lost[partId]?.text.trim() ?? '') ?? 0,
        'note': _notes[partId]?.text.trim() ?? '',
      });
    }
    if (adjustments.isEmpty) {
      showToast(context, 'Không có thay đổi nào để ghi nhận');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận kiểm kho?'),
        content: Text('Có ${adjustments.length} linh kiện có chênh lệch. Hệ thống sẽ tự động cập nhật số lượng tồn kho và ghi nhận biên bản kiểm.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xác nhận')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      for (final adj in adjustments) {
        if (adj['diff_qty'] != 0) {
          // Cập nhật số lượng tồn
          await SupabaseService.client
              .from('inventory_parts')
              .update({'quantity': adj['actual_qty']})
              .eq('id', adj['part_id']);
          // Ghi giao dịch điều chỉnh
          await SupabaseService.client.from('inventory_transactions').insert({
            'store_id': storeId,
            'part_id': adj['part_id'],
            'type': 'adjust',
            'quantity': adj['diff_qty'].abs(),
            'note': 'Kiểm kho: chênh lệch ${adj['diff_qty'] > 0 ? '+' : ''}${adj['diff_qty']}',
            'created_by': SupabaseService.currentUser?.id ?? '',
          });
        }
        // Ghi nhận kiểm kho
        await SupabaseService.client.from('stock_counts').insert({
          'store_id': storeId,
          'counted_by': SupabaseService.currentUser?.id ?? '',
          'part_id': adj['part_id'],
          'system_qty': adj['system_qty'],
          'actual_qty': adj['actual_qty'],
          'diff_qty': adj['diff_qty'],
          'damaged_qty': adj['damaged_qty'],
          'lost_qty': adj['lost_qty'],
          'note': adj['note'],
        });
      }
      await AppLogger.instance.action(
        'Kiểm kho: điều chỉnh ${adjustments.length} linh kiện',
        category: 'kho',
        data: {'count': adjustments.length},
      );
      if (mounted) {
        showToast(context, 'Đã kiểm kho ${adjustments.length} linh kiện');
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Lỗi: ${friendlyError(e)}';
      });
    }
  }

  final Map<String, int> _systemQtys = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kiểm kho'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _confirmAdjust,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check, size: 18),
            label: const Text('Cân bằng'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: autoReconnectStream(
            () => SupabaseService.client
                .from('inventory_parts')
                .stream(primaryKey: ['id'])
                .order('name'),
            label: 'inventory_parts_dlg',
          ),
          builder: (context, rows) {
          final active = rows.where((r) => r['deleted_at'] == null).toList();
          _storeId ??= active.isNotEmpty ? active.first['store_id'] as String? : null;

          for (final p in active) {
            final id = p['id'] as String;
            _systemQtys[id] = p['quantity'] as int? ?? 0;
            _counts.putIfAbsent(id, () => TextEditingController(text: '${p['quantity'] ?? 0}'));
            _damaged.putIfAbsent(id, () => TextEditingController());
            _lost.putIfAbsent(id, () => TextEditingController());
            _notes.putIfAbsent(id, () => TextEditingController());
          }

          if (active.isEmpty) return const Center(child: Text('Kho trống.'));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Text('Nhập số lượng thực tế, hàng hư/mất và ghi chú.',
                  style: TextStyle(color: Colors.black54, fontSize: 12)),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 8),
              for (final p in active) ...[
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${p['name'] ?? ''} — ${p['sku'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _counts[p['id']]!,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'SL thực tế',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _damaged[p['id']]!,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Hư',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _lost[p['id']]!,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Mất',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _notes[p['id']]!,
                          decoration: const InputDecoration(
                            labelText: 'Ghi chú (tùy chọn)',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            border: OutlineInputBorder(),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
        ),
      ),
    );
  }
}

// =============================================================================
// Đổi giá hàng loạt
// =============================================================================
class _BulkPriceUpdateScreen extends StatefulWidget {
  const _BulkPriceUpdateScreen();

  @override
  State<_BulkPriceUpdateScreen> createState() => _BulkPriceUpdateScreenState();
}

class _BulkPriceUpdateScreenState extends State<_BulkPriceUpdateScreen> {
  String? _categoryId;
  final _percentCtrl = TextEditingController();
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _previewParts = [];

  @override
  void dispose() {
    _percentCtrl.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final percent = double.tryParse(_percentCtrl.text.trim());
    if (percent == null || percent == 0) {
      setState(() => _error = 'Nhập phần trăm thay đổi (vd: 10 cho tăng 10%, -5 cho giảm 5%)');
      return;
    }
    try {
      var rows = await SupabaseService.client
          .from('inventory_parts')
          .select('id, name, sku, unit_cost');
      final all = List<Map<String, dynamic>>.from(rows as List);
      var filtered = all.where((r) => r['deleted_at'] == null).toList();
      if (_categoryId != null) {
        filtered = filtered.where((r) => r['category_id'] == _categoryId).toList();
      }
      setState(() {
        _previewParts = filtered;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Lỗi: ${friendlyError(e)}');
    }
  }

  Future<void> _apply() async {
    final percent = double.tryParse(_percentCtrl.text.trim());
    if (percent == null || percent == 0 || _previewParts.isEmpty) return;

    final count = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận đổi giá?'),
        content: Text(
          'Cập nhật giá nhập cho ${_previewParts.length} linh kiện.\n'
          'Tỉ lệ: ${percent > 0 ? '+' : ''}$percent%',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 0), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 1), child: const Text('Áp dụng')),
        ],
      ),
    );
    if (count != 1) return;

    setState(() => _saving = true);
    try {
      for (final p in _previewParts) {
        final oldCost = (p['unit_cost'] as num?) ?? 0;
        await SupabaseService.client
            .from('inventory_parts')
            .update({
              'unit_cost': (oldCost * (1 + percent / 100)).round(),
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('id', p['id']);
      }
      if (mounted) {
        showToast(context, 'Đã cập nhật giá nhập cho ${_previewParts.length} linh kiện');
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Lỗi: ${friendlyError(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đổi giá hàng loạt')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          const Text('Chọn danh mục và nhập tỉ lệ % thay đổi giá.', style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 12),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: autoReconnectStream(() => SupabaseService.client.from('part_categories').stream(primaryKey: ['id']).order('name'), label: 'part_categories_filter'),
            builder: (context, snap) {
              final categories = snap.data ?? [];
              return DropdownButtonFormField<String>(
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: 'Danh mục (để trống = tất cả)'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('-- Tất cả danh mục --')),
                  for (final c in categories)
                    DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] ?? '')),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _percentCtrl,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            decoration: const InputDecoration(
              labelText: '% thay đổi',
              suffixText: '%',
              helperText: 'VD: 10 để tăng 10%, -5 để giảm 5%',
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: true,
            onChanged: null,
            title: const Text('Áp dụng cho giá nhập', style: TextStyle(fontSize: 13)),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _preview,
            icon: const Icon(Icons.preview, size: 18),
            label: const Text('Xem trước'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          if (_previewParts.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Xem trước thay đổi:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            for (final p in _previewParts) ...[
              Card(
                margin: const EdgeInsets.symmetric(vertical: 2),
                child: ListTile(
                  dense: true,
                  title: Text('${p['name'] ?? ''} — ${p['sku'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(_buildPricePreview(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _saving ? null : _apply,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: Text(_saving ? 'Đang lưu...' : 'Áp dụng cho ${_previewParts.length} linh kiện'),
            ),
          ],
        ],
        ),
      ),
    );
  }

  String _buildPricePreview(Map<String, dynamic> p) {
    final percent = double.tryParse(_percentCtrl.text.trim()) ?? 0;
    final old = (p['unit_cost'] as num?) ?? 0;
    final newVal = (old * (1 + percent / 100)).round();
    return 'Giá nhập: ${_currency.format(old)} → ${_currency.format(newVal)}';
  }
}

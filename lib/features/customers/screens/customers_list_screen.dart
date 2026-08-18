import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase_service.dart';
import '../../../core/app_logger.dart';
import '../../../core/app_toast.dart';
import '../../../core/error_utils.dart';
import '../../../widgets/notification_bell.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../finance/widgets/debt_dialogs.dart';

final _currency = NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0);
final _dateFmt = DateFormat('dd/MM/yyyy');

class CustomersListScreen extends StatefulWidget {
  const CustomersListScreen({super.key});

  @override
  State<CustomersListScreen> createState() => _CustomersListScreenState();
}

class _CustomersListScreenState extends State<CustomersListScreen> {
  late final Stream<List<Map<String, dynamic>>> _customersStream;
  late final Stream<List<Map<String, dynamic>>> _suppliersStream;
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  double _split = 0.5;
  final Set<String> _selectedCustomerIds = {};

  @override
  void initState() {
    super.initState();
    _customersStream = autoReconnectStream(
      () => SupabaseService.client
          .from('customers')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false),
      label: 'customers',
    );
    _suppliersStream = autoReconnectStream(
      () => SupabaseService.client
          .from('debts')
          .stream(primaryKey: ['id'])
          .order('contact_name'),
      label: 'suppliers',
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _showAddDialog({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final phoneCtrl = TextEditingController(text: existing?['phone'] ?? '');
    final addressCtrl = TextEditingController(text: existing?['address'] ?? '');
    final noteCtrl = TextEditingController(text: existing?['note'] ?? '');
    String customerType = existing?['customer_type'] ?? 'retail';
    bool saving = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: isEdit ? 'Sửa khách hàng' : 'Thêm khách hàng',
      contentBuilder: (ctx, setStateDialog) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Họ tên *')),
                const SizedBox(height: 8),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Số điện thoại'),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'retail', label: Text('Khách lẻ'), icon: Icon(Icons.person_outline, size: 16)),
                    ButtonSegment(value: 'wholesale', label: Text('Khách sỉ'), icon: Icon(Icons.groups_outlined, size: 16)),
                  ],
                  selected: {customerType},
                  onSelectionChanged: (s) => setStateDialog(() => customerType = s.first),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 8),
                TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Địa chỉ')),
                const SizedBox(height: 8),
                TextField(controller: noteCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Ghi chú')),
                if (error != null) ...[const SizedBox(height: 8), Text(error!, style: const TextStyle(color: Colors.red))],
              ],
            ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
              onCancel: saving ? null : () => Navigator.pop(ctx),
              isDirty: () => nameCtrl.text != (existing?['name'] ?? '') || phoneCtrl.text != (existing?['phone'] ?? '') || customerType != (existing?['customer_type'] ?? 'retail'),
              primaryButton: ElevatedButton(
                onPressed: saving ? null : () async {
                  if (nameCtrl.text.trim().isEmpty) { setStateDialog(() => error = 'Vui lòng nhập họ tên.'); return; }
                  setStateDialog(() { saving = true; error = null; });
                  try {
                    final storeId = (await SupabaseService.client
                        .from('profiles').select('store_id')
                        .eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
                    final newName = nameCtrl.text.trim();
                    final newPhone = phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim();

                    // Check merge when editing
                    if (isEdit) {
                      final oldName = (existing['name'] ?? '').toString();
                      final oldPhone = (existing['phone'] ?? '').toString();
                      final nameChanged = newName != oldName;
                      final phoneChanged = newPhone != oldPhone;

                      if (nameChanged || phoneChanged) {
                        // Find existing customer with same name or phone
                        var q = SupabaseService.client.from('customers')
                            .select('id, name, phone')
                            .eq('store_id', storeId)
                            .neq('id', existing['id']);
                        if (newName.isNotEmpty) q = q.eq('name', newName);
                        final matches = await q;
                        final matchList = (matches as List).where((m) {
                          if (phoneChanged && newPhone != null) return m['phone'] == newPhone;
                          return true;
                        }).toList();

                        if (matchList.isNotEmpty) {
                          final match = matchList.first;
                          final mergeName = match['name'] ?? '';
                          setStateDialog(() { saving = false; });
                          final doMerge = await showConfirmDialog(
                            context: ctx,
                            title: 'Gộp khách hàng?',
                            message: 'Tên hoặc SĐT trùng với "$mergeName". Gộp tất cả đơn sửa chữa về khách này?',
                            confirmLabel: 'Gộp',
                            danger: false,
                          );
                          if (!doMerge) { setStateDialog(() { saving = true; }); return; }
                          setStateDialog(() { saving = true; error = null; });

                          // Merge: reassign repair_orders to target customer
                          await SupabaseService.client.from('repair_orders')
                              .update({'customer_id': match['id']})
                              .eq('customer_id', existing['id']);
                          // Delete old customer
                          await SupabaseService.client.from('customers')
                              .update({'deleted_at': DateTime.now().toIso8601String()})
                              .eq('id', existing['id']);
                          await AppLogger.instance.action(
                            'Gộp khách hàng "$oldName" vào "$mergeName"',
                            category: 'khach_hang',
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          return;
                        }
                      }
                    }

                    // Check duplicate when adding
                    if (!isEdit) {
                      final existingByName = await SupabaseService.client.from('customers')
                          .select('id')
                          .eq('store_id', storeId)
                          .eq('name', newName)
                          .maybeSingle();
                      if (existingByName != null) {
                        setStateDialog(() { saving = false; error = 'Khách hàng "$newName" đã tồn tại. Hãy sửa từ danh sách.'; });
                        return;
                      }
                    }

                    final payload = {
                      'store_id': storeId,
                      'name': newName,
                      'phone': newPhone,
                      'customer_type': customerType,
                      'address': addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),
                      'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                    };
                    if (isEdit) {
                      payload.remove('store_id');
                      await SupabaseService.client.from('customers').update(payload).eq('id', existing['id']);
                    } else {
                      await SupabaseService.client.from('customers').insert(payload);
                    }
                    await AppLogger.instance.action(
                      '${isEdit ? 'Sửa' : 'Thêm'} khách hàng "$newName"',
                      category: 'khach_hang',
                      data: {'customer_type': customerType},
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (e) { setStateDialog(() { saving = false; error = 'Lỗi: ${friendlyError(e)}'; }); }
                },
                child: saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
                    : Text(isEdit ? 'Lưu' : 'Thêm'),
              ),
            ),
    );
  }

  void _addSupplier() {
    showAddDebtDialog(context, initialType: 'supplier', title: 'Thêm nhà cung cấp', showTypeSelector: false, showAmount: false);
  }

  Future<void> _showCustomerDetailDialog(Map<String, dynamic> c) async {
    final name = (c['name'] ?? '').toString();
    final isWholesale = c['customer_type'] == 'wholesale';
    final phone = (c['phone'] ?? '').toString();
    final color = isWholesale ? Colors.indigo : Colors.green;
    final icon = isWholesale ? Icons.groups : Icons.person;

    // Load repair orders + debt
    num totalSpent = 0;
    int orderCount = 0;
    List<Map<String, dynamic>> repairOrders = [];
    num debtAmount = 0;
    try {
      final storeId = (await SupabaseService.client.from('profiles')
          .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
      // Repair orders
      final orders = await SupabaseService.client
          .from('repair_orders')
          .select('id, code, device_model, issue_description, final_cost, status, received_at, customer_id')
          .eq('store_id', storeId)
          .eq('customer_id', c['id'])
          .order('received_at', ascending: false);
      repairOrders = List<Map<String, dynamic>>.from(orders);
      orderCount = repairOrders.length;
      for (final o in repairOrders) {
        if (o['status'] == 'delivered') totalSpent += (o['final_cost'] as num?) ?? 0;
      }
      // Debt
      final debts = await SupabaseService.client
          .from('debts')
          .select('total_debt')
          .eq('store_id', storeId)
          .eq('contact_name', name)
          .eq('type', 'customer');
      for (final d in (debts as List)) {
        debtAmount += (d['total_debt'] as num?) ?? 0;
      }
    } catch (_) {}

    if (!mounted) return;

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.1),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(isWholesale ? 'Khách sỉ' : 'Khách lẻ', style: TextStyle(fontSize: 11, color: color)),
          ])),
          IconButton(icon: const Icon(Icons.edit, size: 18), tooltip: 'Sửa', onPressed: () => Navigator.pop(ctx, 'edit')),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _StatItem(label: 'Phiếu sửa', value: '$orderCount', color: color),
                _StatItem(label: 'Đã chi', value: _currency.format(totalSpent), color: Colors.green),
                if (debtAmount > 0) _StatItem(label: 'Nợ', value: _currency.format(debtAmount), color: Colors.red),
              ]),
            ),
            const SizedBox(height: 12),
            if (repairOrders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('Chưa có lịch sử sửa chữa.', style: TextStyle(color: Colors.black45, fontSize: 12))),
              )
            else ...[
              Text('Lịch sử sửa chữa', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: repairOrders.length,
                  itemBuilder: (_, i) {
                    final o = repairOrders[i];
                    final cost = (o['final_cost'] as num?) ?? 0;
                    final device = o['device_model'] ?? '';
                    final fault = o['issue_description'] ?? '';
                    final status = o['status'] ?? '';
                    final rawDate = o['received_at'];
                    final date = rawDate != null ? DateTime.tryParse(rawDate.toString()) : null;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(o['code'] ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                          if (cost > 0) Text(_currency.format(cost), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green)),
                        ]),
                        Row(children: [
                          Expanded(
                            child: Text(
                              [device, fault].where((s) => (s ?? '').isNotEmpty).join(' · '),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ),
                          if (date != null) Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(_dateFmt.format(date), style: const TextStyle(fontSize: 10, color: Colors.black38)),
                          ),
                        ]),
                      ]),
                    );
                  },
                ),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Xóa', style: TextStyle(color: Colors.red))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _showAddDialog(existing: c);
    } else if (action == 'delete') {
      await _deleteCustomer(c, orderCount: orderCount);
    }
  }

  Future<void> _deleteCustomer(Map<String, dynamic> c, {int orderCount = 0}) async {
    if (orderCount > 0) {
      if (mounted) showToast(context, 'Không thể xóa khách hàng có phát sinh sửa chữa.', error: true);
      return;
    }
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Xóa khách hàng?',
      message: 'Khách hàng "${c['name']}" sẽ được chuyển vào thùng rác.',
      confirmLabel: 'Xóa',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await SupabaseService.client.from('customers').update({
        'deleted_at': DateTime.now().toIso8601String(),
      }).eq('id', c['id']);
      await AppLogger.instance.action('Xóa khách hàng "${c['name']}"', category: 'khach_hang');
      if (mounted) {
        showToast(context, 'Đã xóa khách hàng.');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: ${friendlyError(e)}', error: true);
      }
    }
  }

  /// Gộp các khách hàng được chọn: lấy tên khách đầu tiên làm tên chung,
  /// cập nhật customer_id trên repair_orders, soft-delete các khách bị gộp.
  Future<void> _mergeSelectedCustomers() async {
    if (_selectedCustomerIds.length < 2) return;
    try {
      final storeId = (await SupabaseService.client
              .from('profiles')
              .select('store_id')
              .eq('id', SupabaseService.currentUser?.id ?? '')
              .single())['store_id'];

      // Tải toàn bộ khách được chọn
      final allCustomers = <Map<String, dynamic>>[];
      for (final id in _selectedCustomerIds) {
        final c = await SupabaseService.client
            .from('customers')
            .select('id, name, phone')
            .eq('id', id)
            .maybeSingle();
        if (c != null) allCustomers.add(c as Map<String, dynamic>);
      }
      if (allCustomers.length < 2) {
        if (mounted) showToast(context, 'Không tải đủ khách để gộp.', error: true);
        return;
      }

      // Khách đầu tiên = tên gộp
      final target = allCustomers.first;
      final targetName = (target['name'] ?? '').toString();
      final targetId = target['id'] as String;
      final toMerge = allCustomers.sublist(1);

      // Hộp thoại xác nhận
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Gộp khách hàng'),
          content: Text(
            'Gộp ${toMerge.length + 1} khách thành "$targetName"?\n'
            '${toMerge.map((c) => '• ${c["name"]}').join("\n")}\n\n'
            'Tất cả đơn sửa sẽ chuyển sang khách "$targetName".',
            maxLines: 10,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Gộp')),
          ],
        ),
      );
      if (confirm != true) return;

      // Chuyển repair_orders sang target
      for (final c in toMerge) {
        final oldId = c['id'] as String;
        await SupabaseService.client
            .from('repair_orders')
            .update({'customer_id': targetId})
            .eq('store_id', storeId)
            .eq('customer_id', oldId);
      }

      // Soft-delete các khách bị gộp
      for (final c in toMerge) {
        await SupabaseService.client
            .from('customers')
            .update({'deleted_at': DateTime.now().toIso8601String(), 'name': '${c['name']} (gộp → $targetName)'})
            .eq('id', c['id']);
      }

      if (mounted) {
        showToast(context, 'Đã gộp ${toMerge.length + 1} khách thành "$targetName".');
        setState(() => _selectedCustomerIds.clear());
      }
    } catch (e) {
      if (mounted) showToast(context, 'Lỗi gộp khách: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _showSupplierDetailDialog(Map<String, dynamic> d) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final name = (d['contact_name'] ?? '').toString();
        final phone = (d['contact_phone'] ?? '').toString();
        final addr = (d['contact_address'] ?? '').toString();
        final note = (d['note'] ?? '').toString();
        return AlertDialog(
          title: const Text('Nhà cung cấp'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(radius: 22, backgroundColor: Colors.red.shade50, child: const Icon(Icons.business_outlined, color: Colors.red)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ]),
              const Divider(height: 24),
              if (phone.isNotEmpty) _DetailRow(icon: Icons.phone, label: 'Số điện thoại', value: phone),
              if (addr.isNotEmpty) _DetailRow(icon: Icons.location_on, label: 'Địa chỉ', value: addr),
              if (note.isNotEmpty) _DetailRow(icon: Icons.notes, label: 'Ghi chú', value: note),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'tx'), child: const Text('Phát sinh')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
          ],
        );
      },
    );
    if (!mounted) return;
    if (action == 'tx') showAddDebtTxDialog(context, d);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _showSearch
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.black87, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Tìm theo tên, SĐT...',
                  hintStyle: TextStyle(color: Colors.black38),
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Khách hàng & NCC'),
        actions: [
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
      body: SafeArea(
        top: false,
        child: RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: _customersStream,
          builder: (context, allCustomers) {
            final customers = allCustomers.where((r) => r['deleted_at'] == null).toList();
            final q = _searchCtrl.text.trim().toLowerCase();
            final matchedCustomers = customers.where((c) {
              if (q.isEmpty) return true;
              return (c['name'] ?? '').toString().toLowerCase().contains(q) ||
                     (c['phone'] ?? '').toString().toLowerCase().contains(q);
            }).toList();
            return RealtimeStreamView<List<Map<String, dynamic>>>(
              stream: _suppliersStream,
              builder: (context, allSuppliers) {
                final suppliers = allSuppliers.where((d) => d['type'] == 'supplier').toList();
                final matchedSuppliers = suppliers.where((d) {
                  if (q.isEmpty) return true;
                  return (d['contact_name'] ?? '').toString().toLowerCase().contains(q) ||
                         (d['contact_phone'] ?? '').toString().toLowerCase().contains(q);
                }).toList();
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final android = Platform.isAndroid;
                    final dividerWidth = android ? 14.0 : 1.0;
                    final split = _split.clamp(0.15, 0.85);
                    final leftWidth = constraints.maxWidth * split;
                    final rightWidth = constraints.maxWidth - leftWidth - dividerWidth;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: leftWidth,
                          child: _buildCustomersColumn(matchedCustomers, customers.length),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: android
                              ? (d) => setState(() {
                                    _split = (_split + d.delta.dx / constraints.maxWidth).clamp(0.15, 0.85);
                                  })
                              : null,
                          child: Container(
                            width: dividerWidth,
                            color: Colors.transparent,
                            alignment: Alignment.center,
                            child: Container(
                              width: android ? 3 : 1,
                              height: double.infinity,
                              color: Colors.grey.shade300,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: rightWidth,
                          child: _buildSuppliersColumn(matchedSuppliers, suppliers),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildCustomersColumn(List<Map<String, dynamic>> rows, int totalCount) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Row(children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('Khách hàng ($totalCount)',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Thêm khách hàng',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.person_add_alt_1, size: 20),
              onPressed: () => _showAddDialog(),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        if (_selectedCustomerIds.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF3B82F6).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 18, color: Color(0xFF3B82F6)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Đã chọn ${_selectedCustomerIds.length} khách',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF3B82F6)),
                  ),
                ),
                if (_selectedCustomerIds.length >= 2)
                  TextButton.icon(
                    icon: const Icon(Icons.merge, size: 16),
                    label: const Text('Gộp', style: TextStyle(fontSize: 13)),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF3B82F6)),
                    onPressed: _mergeSelectedCustomers,
                  ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.black54),
                  onPressed: () => setState(() => _selectedCustomerIds.clear()),
                  child: const Text('Bỏ chọn', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        if (_selectedCustomerIds.isNotEmpty) const SizedBox(height: 6),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Chưa có khách hàng.', style: TextStyle(color: Colors.black45)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _showAddDialog(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Thêm khách hàng'),
                    ),
                  ]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final c = rows[i];
                    final isWholesale = c['customer_type'] == 'wholesale';
                    final name = (c['name'] ?? '').toString();
                    final phone = (c['phone'] ?? '').toString();
                    final color = isWholesale ? const Color(0xFF1E3A5F) : const Color(0xFF16A34A);
                    final bgColor = isWholesale ? const Color(0xFFD6E4F0) : const Color(0xFFECFDF5);
                    final iconData = isWholesale ? Icons.groups_rounded : Icons.person_rounded;

                    return FutureBuilder<Map<String, num>>(
                      future: _loadCustomerStats(c['id'], name),
                      builder: (ctx, snap) {
                        final stats = snap.data;
                        final spent = stats?['spent'] ?? 0;
                        final debt = stats?['debt'] ?? 0;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: _selectedCustomerIds.contains(c['id'])
                              ? const Color(0xFFDBEAFE)
                              : bgColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: _selectedCustomerIds.contains(c['id'])
                                ? const BorderSide(color: Color(0xFF3B82F6), width: 2)
                                : BorderSide.none,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _showCustomerDetailDialog(c),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    setState(() {
                                      final id = c['id'] as String;
                                      if (_selectedCustomerIds.contains(id)) {
                                        _selectedCustomerIds.remove(id);
                                      } else {
                                        _selectedCustomerIds.add(id);
                                      }
                                    });
                                  },
                                  child: CircleAvatar(
                                    radius: 20,
                                    backgroundColor: _selectedCustomerIds.contains(c['id'])
                                        ? const Color(0xFF3B82F6)
                                        : color.withValues(alpha: 0.15),
                                    child: _selectedCustomerIds.contains(c['id'])
                                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                                        : Icon(iconData, color: color, size: 20),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: color))),
                                      if (phone.isNotEmpty) Text(phone, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                    ]),
                                    const SizedBox(height: 4),
                                    Row(children: [
                                      Text('Đã chi: ', style: TextStyle(fontSize: 11, color: color)),
                                      Text(_currency.format(spent), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                                      if (debt > 0) ...[
                                        const SizedBox(width: 12),
                                        const Text('Nợ: ', style: TextStyle(fontSize: 11, color: Colors.red)),
                                        Text(_currency.format(debt), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.red)),
                                      ],
                                    ]),
                                  ]),
                                ),
                                IconButton(
                                  icon: Icon(Icons.edit, size: 16, color: color),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _showAddDialog(existing: c),
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<Map<String, num>> _loadCustomerStats(String customerId, String name) async {
    try {
      final storeId = (await SupabaseService.client.from('profiles')
          .select('store_id').eq('id', SupabaseService.currentUser?.id ?? '').single())['store_id'];
      final orders = await SupabaseService.client
          .from('repair_orders')
          .select('final_cost, status')
          .eq('store_id', storeId)
          .eq('customer_id', customerId);
      num spent = 0;
      for (final o in (orders as List)) {
        if (o['status'] == 'delivered') spent += (o['final_cost'] as num?) ?? 0;
      }
      num debt = 0;
      final debts = await SupabaseService.client
          .from('debts')
          .select('total_debt')
          .eq('store_id', storeId)
          .eq('contact_name', name)
          .eq('type', 'customer');
      for (final d in (debts as List)) {
        debt += (d['total_debt'] as num?) ?? 0;
      }
      return {'spent': spent, 'debt': debt};
    } catch (_) {
      return {'spent': 0, 'debt': 0};
    }
  }

  Widget _buildSuppliersColumn(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> all) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 14, 4),
          child: Row(children: [
            const Icon(Icons.business_outlined, size: 18, color: Colors.red),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('Nhà cung cấp (${all.length})',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Thêm nhà cung cấp',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_business_outlined, size: 20),
              onPressed: _addSupplier,
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Chưa có nhà cung cấp.', style: TextStyle(color: Colors.black45)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _addSupplier,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Thêm nhà cung cấp'),
                    ),
                  ]),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final d = rows[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                        leading: const Icon(Icons.business_outlined, color: Colors.red, size: 20),
                        title: Text(d['contact_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text('${d['contact_phone'] ?? ''} · ${d['note'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                        trailing: IconButton(
                          icon: const Icon(Icons.add, size: 18),
                          tooltip: 'Phát sinh',
                          onPressed: () => showAddDebtTxDialog(context, d),
                        ),
                        onTap: () => _showSupplierDetailDialog(d),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.black54),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
              const SizedBox(height: 1),
              Text(value, style: const TextStyle(fontSize: 14)),
            ]),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatItem({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7))),
    ]);
  }
}

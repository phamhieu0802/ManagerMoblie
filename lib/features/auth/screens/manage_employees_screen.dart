import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/app_toast.dart';
import '../../../core/supabase_service.dart';
import '../../../models/profile.dart';
import '../../../widgets/realtime_stream_view.dart';
import '../../../widgets/dialog_action_row.dart';
import '../../../widgets/adaptive_form_dialog.dart';
import '../../../widgets/anchor_dropdown.dart';

/// Sinh mật khẩu tạm thời ngẫu nhiên an toàn (10 ký tự chữ + số), không dựa
/// trên tên/vai trò/ngày để tránh bị đoán.
String generateTempPassword(String fullName, UserRole role) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  final rng = Random.secure();
  return List.generate(10, (_) => chars[rng.nextInt(chars.length)]).join();
}

class ManageEmployeesScreen extends StatefulWidget {
  const ManageEmployeesScreen({super.key});

  @override
  State<ManageEmployeesScreen> createState() => _ManageEmployeesScreenState();
}

class _ManageEmployeesScreenState extends State<ManageEmployeesScreen> {
  late final Stream<List<Map<String, dynamic>>> _profilesStream;
  final _addFabKey = GlobalKey();
  String? _cachedStoreId;
  final String? _currentUserId = SupabaseService.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _profilesStream = autoReconnectStream(
      () => SupabaseService.client
          .from('profiles')
          .stream(primaryKey: ['id'])
          .order('created_at'),
      label: 'profiles',
    );
    _loadStoreId();
  }

  Future<void> _loadStoreId() async {
    final uid = SupabaseService.currentUser?.id;
    if (uid == null) return;
    try {
      final p = await SupabaseService.client
          .from('profiles')
          .select('store_id')
          .eq('id', uid)
          .single();
      if (mounted) setState(() => _cachedStoreId = p['store_id'] as String?);
    } catch (_) {}
  }

  Future<void> _showAddOptions() async {
    final anchor = _addFabKey.currentContext;
    if (anchor == null) return;
    String? choice;
    try {
      choice = await showAnchorDropdownPanel<String>(
        anchorContext: anchor,
        width: 300,
        estimatedHeight: 140,
        builder: (ctx, close) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.g_mobiledata_rounded, size: 32),
              title: const Text('Mời qua email Google'),
              subtitle: const Text('Gửi email mời, nhân viên tự đăng nhập bằng Google'),
              onTap: () => close('google'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Tạo tài khoản nội bộ'),
              subtitle: const Text('Đặt sẵn tên đăng nhập + mật khẩu tạm thời'),
              onTap: () => close('internal'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Lỗi bất ngờ khi đóng menu (VD: OverlayEntry đã bị remove) — bỏ qua để
      // không làm chết luồng mở dialog chọn tùy chọn.
    }
    if (!mounted || choice == null) return;
    if (choice == 'google') {
      await _showInviteGoogleDialog();
    } else {
      await _showAddInternalDialog();
    }
  }

  Future<void> _showInviteGoogleDialog() async {
    final emailCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    UserRole role = UserRole.technician;
    bool sending = false;
    String? error;

    await showAdaptiveFormDialog(
      context: context,
      title: 'Mời nhân viên qua Google',
      contentBuilder: (ctx, setStateDialog) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Họ tên')),
                const SizedBox(height: 8),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email Gmail của nhân viên',
                    helperText: 'Hệ thống sẽ gửi email mời xác nhận tới địa chỉ này',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<UserRole>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Vai trò'),
                  items: const [
                    DropdownMenuItem(value: UserRole.receptionist, child: Text('Lễ tân')),
                    DropdownMenuItem(value: UserRole.technician, child: Text('Kỹ thuật viên')),
                  ],
                  onChanged: (v) => setStateDialog(() => role = v ?? UserRole.technician),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
              onCancel: sending ? null : () => Navigator.pop(ctx),
              isDirty: () => nameCtrl.text.trim().isNotEmpty || emailCtrl.text.trim().isNotEmpty,
              primaryButton: ElevatedButton(
                onPressed: sending
                    ? null
                    : () async {
                        if (nameCtrl.text.trim().isEmpty || emailCtrl.text.trim().isEmpty) {
                          setStateDialog(() => error = 'Vui lòng nhập đủ họ tên và email.');
                          return;
                        }
                        setStateDialog(() {
                          sending = true;
                          error = null;
                        });
                        try {
                          await SupabaseService.client.functions.invoke(
                            'invite-employee-google',
                            body: {
                              'email': emailCtrl.text.trim(),
                              'full_name': nameCtrl.text.trim(),
                              'role': role.name,
                            },
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            showToast(context, 'Đã gửi email mời tới ${emailCtrl.text.trim()}');
                          }
                        } catch (e) {
                          setStateDialog(() {
                            sending = false;
                            error = 'Lỗi: $e';
                          });
                        }
                      },
                child: sending
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)),
                      )
                    : const Text('Gửi lời mời'),
              ),
            ),
    );
  }

  Future<void> _showAddInternalDialog() async {
    final usernameCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    UserRole role = UserRole.technician;
    bool saving = false;
    String? error;

    void regeneratePassword() => passCtrl.text = generateTempPassword(nameCtrl.text, role);

    await showAdaptiveFormDialog(
      context: context,
      title: 'Tạo tài khoản nội bộ',
      contentBuilder: (ctx, setStateDialog) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Họ tên'),
                  onChanged: (_) => setStateDialog(regeneratePassword),
                ),
                const SizedBox(height: 8),
                TextField(controller: usernameCtrl, decoration: const InputDecoration(labelText: 'Tên đăng nhập')),
                const SizedBox(height: 8),
                TextField(
                  controller: passCtrl,
                  decoration: InputDecoration(
                    labelText: 'Mật khẩu tạm thời',
                    helperText: 'Tự sinh ngẫu nhiên — có thể sửa lại',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: 'Sinh lại',
                      onPressed: () => setStateDialog(regeneratePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<UserRole>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Vai trò'),
                  items: const [
                    DropdownMenuItem(value: UserRole.receptionist, child: Text('Lễ tân')),
                    DropdownMenuItem(value: UserRole.technician, child: Text('Kỹ thuật viên')),
                  ],
                  onChanged: (v) => setStateDialog(() {
                    role = v ?? UserRole.technician;
                    regeneratePassword();
                  }),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
              onCancel: saving ? null : () => Navigator.pop(ctx),
              isDirty: () =>
                  nameCtrl.text.trim().isNotEmpty ||
                  usernameCtrl.text.trim().isNotEmpty ||
                  passCtrl.text.trim().isNotEmpty,
              primaryButton: ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (nameCtrl.text.trim().isEmpty || usernameCtrl.text.trim().isEmpty) {
                          setStateDialog(() => error = 'Vui lòng nhập đủ họ tên và tên đăng nhập.');
                          return;
                        }
                        // Username dùng để tạo email nội bộ (username.storeCode@employee.local)
                        // nên chỉ cho chữ thường, số, dấu gạch dưới — tránh email sai/trùng.
                        if (!RegExp(r'^[a-z0-9_]+$').hasMatch(usernameCtrl.text.trim())) {
                          setStateDialog(() => error = 'Tên đăng nhập chỉ gồm chữ thường, số và gạch dưới (_).');
                          return;
                        }
                        setStateDialog(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          // Gọi Edge Function create-employee (đã deploy trên Supabase) để tạo
                          // tài khoản nhân viên một cách an toàn (dùng service role phía server).
                          await SupabaseService.client.functions.invoke(
                            'create-employee',
                            body: {
                              'username': usernameCtrl.text.trim(),
                              'password': passCtrl.text,
                              'full_name': nameCtrl.text.trim(),
                              'role': role.name,
                            },
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            showToast(context, 'Đã tạo tài khoản. Mật khẩu tạm: ${passCtrl.text}');
                          }
                        } catch (e) {
                          setStateDialog(() {
                            saving = false;
                            error = 'Lỗi: $e';
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)))
                    : const Text('Tạo tài khoản'),
              ),
            ),
    );
  }

  String _commissionSuffix(Profile p) {
    if (p.commissionType == 'profit_pct') {
      if (p.commissionRate == null || p.commissionRate! <= 0) return '';
      return ' · Hoa hồng ${p.commissionRate!.toStringAsFixed(0)}% lợi nhuận/đơn';
    }
    if (p.commissionAmount == null || p.commissionAmount! <= 0) return '';
    return ' · Tiền công ${NumberFormat.currency(locale: 'vi_VN', symbol: 'đ', decimalDigits: 0).format(p.commissionAmount)}/đơn';
  }

  Future<void> _confirmDelete(Profile p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa nhân viên?'),
        content: Text('${p.fullName} sẽ bị vô hiệu hóa và không thể đăng nhập.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SupabaseService.client.functions.invoke(
        'update-employee',
        body: {'employee_id': p.id, 'is_active': false},
      );
      if (mounted) {
        showToast(context, 'Đã xóa ${p.fullName}');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Lỗi: $e', error: true);
      }
    }
  }

  Future<void> _showEditCommission(Profile p) async {
    // Cơ chế tính lương được chọn TRƯỚC, sau đó mới hiện ô nhập giá trị tương ứng.
    // 'labor_fixed' -> nhập SỐ TIỀN trên 1 hóa đơn; 'profit_pct' -> nhập % lợi nhuận.
    String? mech = p.commissionType;
    if (mech != 'labor_fixed' && mech != 'profit_pct') mech = null;
    final amountCtrl = TextEditingController(
      text: (mech == 'labor_fixed' && p.commissionAmount != null && p.commissionAmount! > 0)
          ? p.commissionAmount!.toStringAsFixed(0)
          : '',
    );
    final pctCtrl = TextEditingController(
      text: (mech == 'profit_pct' && p.commissionRate != null && p.commissionRate! > 0)
          ? p.commissionRate!.toStringAsFixed(0)
          : '',
    );
    await showAdaptiveFormDialog<bool>(
      context: context,
      title: 'Hoa hồng — ${p.fullName}',
      contentBuilder: (ctx, setStateDialog) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Cơ chế tính lương', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: 'labor_fixed', label: Text('Tiền công / đơn')),
              ButtonSegment(value: 'profit_pct', label: Text('% lợi nhuận')),
            ],
            selected: mech == null ? const <String>{} : {mech!},
            onSelectionChanged: (s) => setStateDialog(() => mech = s.first),
          ),
          const SizedBox(height: 4),
          const Text(
            '• Tiền công: nhận cố định trên mỗi hóa đơn đã trả máy\n• % lợi nhuận: nhận theo doanh thu trừ chi phí linh kiện của 1 đơn',
            style: TextStyle(color: Colors.black45, fontSize: 11),
          ),
          if (mech == 'labor_fixed') ...[
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Số tiền / 1 hóa đơn',
                helperText: 'Nhập số tiền nhận trên 1 đơn, để trống nếu không có hoa hồng',
                suffixText: 'đ',
              ),
            ),
          ],
          if (mech == 'profit_pct') ...[
            const SizedBox(height: 12),
            TextField(
              controller: pctCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '% hoa hồng',
                helperText: 'Nhập số phần trăm (0–100) theo lợi nhuận 1 đơn',
                suffixText: '%',
              ),
            ),
          ],
        ],
      ),
      actionsBuilder: (ctx, setStateDialog) => DialogActionRow(
        onCancel: () => Navigator.pop(ctx),
        isDirty: () => true,
        primaryButton: ElevatedButton(
          onPressed: () async {
            if (mech == null) {
              showToast(ctx, 'Vui lòng chọn cơ chế tính lương', error: true);
              return;
            }
            if (mech == 'labor_fixed') {
              final text = amountCtrl.text.trim();
              final amount = text.isEmpty ? null : double.tryParse(text);
              if (text.isNotEmpty && amount == null) {
                showToast(ctx, 'Vui lòng nhập số tiền hợp lệ', error: true);
                return;
              }
              try {
                await SupabaseService.client.functions.invoke(
                  'update-employee',
                  body: {
                    'employee_id': p.id,
                    'commission_type': 'labor_fixed',
                    'commission_amount': amount,
                    'commission_rate': null,
                  },
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) {
                  showToast(ctx, 'Lỗi: $e', error: true);
                }
              }
              return;
            }
            final text = pctCtrl.text.trim();
            final rate = text.isEmpty ? null : double.tryParse(text);
            if (text.isNotEmpty && rate == null) {
              showToast(ctx, 'Vui lòng nhập số hợp lệ', error: true);
              return;
            }
            if (rate != null && (rate < 0 || rate > 100)) {
              showToast(ctx, 'Phần trăm phải từ 0 đến 100', error: true);
              return;
            }
            try {
              await SupabaseService.client.functions.invoke(
                'update-employee',
                body: {
                  'employee_id': p.id,
                  'commission_type': 'profit_pct',
                  'commission_rate': rate,
                  'commission_amount': null,
                },
              );
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) {
                showToast(ctx, 'Lỗi: $e', error: true);
              }
            }
          },
          child: const Text('Lưu'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nhân viên')),
      body: SafeArea(
        top: false,
        child: RealtimeStreamView<List<Map<String, dynamic>>>(
          stream: _profilesStream,
          builder: (context, profileRows) {
          final storeId = _cachedStoreId;
          if (storeId == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final employees = profileRows
              .where((r) => r['store_id'] == storeId && r['is_active'] != false)
              .toList();

          if (employees.isEmpty) {
            return const Center(child: Text('Chưa có nhân viên nào.'));
          }

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final row in employees)
                Builder(builder: (context) {
                  final p = Profile.fromMap(row);
                  final isSelf = p.id == _currentUserId;
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Icon(
                          p.role == UserRole.admin
                              ? Icons.admin_panel_settings
                              : p.role == UserRole.receptionist ? Icons.support_agent : Icons.build,
                        ),
                      ),
                      title: Text(p.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${roleLabel(p.role)}${_commissionSuffix(p)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isSelf)
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: 'Xóa nhân viên',
                              onPressed: () => _confirmDelete(p),
                            ),
                          Icon(
                            isSelf ? Icons.person : Icons.check_circle,
                            color: isSelf ? Colors.blue : (p.isActive ? Colors.green : Colors.grey),
                          ),
                        ],
                      ),
                      onTap: () => _showEditCommission(p),
                    ),
                  );
                }),
            ],
          );
        },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: _addFabKey,
        heroTag: 'employees_fab',
        onPressed: _showAddOptions,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Thêm nhân viên'),
      ),
    );
  }
}

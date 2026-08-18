import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:postgrest/postgrest.dart';
import '../../../core/app_toast.dart';
import '../../../core/supabase_service.dart';
import '../controllers/auth_controller.dart';

/// Bỏ dấu tiếng Việt để dùng cho mã cửa hàng (chỉ còn a-z0-9).
String _slugifyVietnamese(String input) {
  const withDiacritics =
      'àáảãạăằắẳẵặâầấẩẫậđèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵ';
  const withoutDiacritics =
      'aaaaaaaaaaaaaaaaadeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyy';

  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final idx = withDiacritics.indexOf(ch);
    buffer.write(idx == -1 ? ch : withoutDiacritics[idx]);
  }
  return buffer.toString().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Tự sinh mã cửa hàng đề xuất từ tên cửa hàng + số điện thoại.
/// VD: "Hiếu Smartphone" + "0768477499" -> "HIEUSMARTPHONE7499"
String suggestStoreCode(String name, String phone) {
  final namePart = _slugifyVietnamese(name);
  final digitsOnly = phone.replaceAll(RegExp(r'[^0-9]'), '');
  final phonePart = digitsOnly.length >= 4
      ? digitsOnly.substring(digitsOnly.length - 4)
      : digitsOnly;

  final trimmedName = namePart.length > 20 ? namePart.substring(0, 20) : namePart;
  final code = '$trimmedName$phonePart';
  return code.toUpperCase();
}

class StoreRegisterScreen extends ConsumerStatefulWidget {
  const StoreRegisterScreen({super.key});

  @override
  ConsumerState<StoreRegisterScreen> createState() => _StoreRegisterScreenState();
}

class _StoreRegisterScreenState extends ConsumerState<StoreRegisterScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  /// true nếu người dùng đã tự tay sửa mã cửa hàng -> ngừng tự sinh lại.
  bool _codeEditedByUser = false;

  /// Chặn bấm nhiều lần trong lúc đang xử lý (kể cả trước khi setState kịp
  /// vô hiệu hoá nút) — đây là nguyên nhân từng khiến 1 lượt tạo cửa hàng
  /// bị bấm nhiều lần và sinh ra nhiều dòng trùng trong bảng stores.
  bool _submitting = false;

  void _regenerateCodeIfNeeded() {
    if (_codeEditedByUser) return;
    final suggested = suggestStoreCode(_nameCtrl.text.trim(), _phoneCtrl.text.trim());
    _codeCtrl.text = suggested;
  }

  /// Thêm hậu tố ngẫu nhiên 2 ký tự khi mã bị trùng, để tự thử lại mà không
  /// cần người dùng tự nghĩ mã khác.
  String _withRandomSuffix(String code) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random();
    final suffix = List.generate(2, (_) => chars[rnd.nextInt(chars.length)]).join();
    return '$code$suffix';
  }

  bool _isDuplicateStoreCodeError(Object e) {
    return e is PostgrestException &&
        e.code == '23505' &&
        (e.message.contains('store_code') || e.message.contains('stores_store_code_key'));
  }

  Future<void> _create() async {
    if (_submitting) return;
    if (_nameCtrl.text.trim().isEmpty || _codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Vui lòng nhập tên và mã cửa hàng.');
      return;
    }
    _submitting = true;
    setState(() {
      _loading = true;
      _error = null;
    });

    final uid = SupabaseService.currentUser!.id;
    var code = _codeCtrl.text.trim().toUpperCase();
    const maxAttempts = 5;

    try {
      Map<String, dynamic>? storeRes;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          storeRes = await SupabaseService.client
              .from('stores')
              .insert({
                'name': _nameCtrl.text.trim(),
                'store_code': code,
                'address': _addressCtrl.text.trim(),
                'phone': _phoneCtrl.text.trim(),
                'owner_id': uid,
              })
              .select()
              .single();
          break;
        } catch (e) {
          // Chỉ tự thử lại khi lỗi là do trùng mã cửa hàng; các lỗi khác thì báo luôn.
          if (_isDuplicateStoreCodeError(e) && attempt < maxAttempts) {
            code = _withRandomSuffix(_codeCtrl.text.trim().toUpperCase());
            continue;
          }
          rethrow;
        }
      }

      if (storeRes == null) {
        throw Exception('Không tạo được mã cửa hàng không trùng sau $maxAttempts lần thử.');
      }

      // Cập nhật lại mã cuối cùng đã dùng để người dùng thấy đúng mã thật sự được lưu.
      if (mounted) _codeCtrl.text = code;

      // Gán profile hiện tại (đã được tạo tự động với role=admin) vào store vừa tạo
      await SupabaseService.client
          .from('profiles')
          .update({'store_id': storeRes['id']}).eq('id', uid);

      // Việc update store_id ở trên là 1 thao tác database bình thường,
      // KHÔNG phát sinh sự kiện auth nên GoRouter sẽ không tự biết để
      // chuyển trang. Phải tự tải lại profile rồi tự điều hướng.
      await ref.read(currentProfileProvider.notifier).load();

      if (mounted) {
        showToast(context, 'Tạo cửa hàng thành công!');
        context.go('/home');
      }
    } catch (e) {
      final msg = _isDuplicateStoreCodeError(e)
          ? 'Mã cửa hàng "$code" đã tồn tại. Vui lòng sửa lại mã khác.'
          : 'Không tạo được cửa hàng: $e';
      setState(() => _error = msg);
    } finally {
      _submitting = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tạo cửa hàng của bạn')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.storefront_rounded, size: 64, color: Color(0xFF2563EB)),
                  const SizedBox(height: 8),
                  const Text(
                    'Đây là lần đầu bạn đăng nhập.\nHãy tạo hồ sơ cửa hàng để bắt đầu.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _nameCtrl,
                    onChanged: (_) => setState(_regenerateCodeIfNeeded),
                    decoration: const InputDecoration(labelText: 'Tên cửa hàng *', prefixIcon: Icon(Icons.store)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => _codeEditedByUser = true,
                    decoration: const InputDecoration(
                      labelText: 'Mã cửa hàng *',
                      helperText: 'Tự sinh từ tên + SĐT — có thể sửa lại. Nhân viên dùng mã này để đăng nhập.',
                      prefixIcon: Icon(Icons.tag),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _addressCtrl,
                    decoration: const InputDecoration(labelText: 'Địa chỉ', prefixIcon: Icon(Icons.place_outlined)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => setState(_regenerateCodeIfNeeded),
                    decoration: const InputDecoration(labelText: 'Số điện thoại', prefixIcon: Icon(Icons.phone_outlined)),
                  ),
                  const SizedBox(height: 20),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _create,
                      child: _loading
                          ? const SizedBox(
                              width: 22, height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Tạo cửa hàng'),
                    ),
                  ),
                  TextButton(
                    onPressed: () => AuthController.signOut(),
                    child: const Text('Đăng xuất'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

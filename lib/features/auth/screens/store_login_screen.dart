import 'package:flutter/material.dart';
import '../../../core/app_toast.dart';
import '../controllers/auth_controller.dart';

class StoreLoginScreen extends StatefulWidget {
  const StoreLoginScreen({super.key});

  @override
  State<StoreLoginScreen> createState() => _StoreLoginScreenState();
}

class _StoreLoginScreenState extends State<StoreLoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  String? _validateEmailPassword() {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty) return 'Vui lòng nhập email.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Email không đúng định dạng.';
    }
    if (pass.isEmpty) return 'Vui lòng nhập mật khẩu.';
    if (pass.length < 6) return 'Mật khẩu phải có ít nhất 6 ký tự.';
    return null;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
      // Điều hướng theo trạng thái đăng nhập được xử lý tự động bởi
      // GoRouter's redirect (xem lib/routing/app_router.dart), lắng nghe authStateChanges.
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('invalid_credentials') ||
          msg.contains('Invalid login credentials')) {
        setState(() {
          _error =
              'Email hoặc mật khẩu không đúng, hoặc tài khoản chưa xác thực email.';
        });
      } else if (msg.contains('bad_oauth_state') ||
          msg.contains('OAuth state not found or expired')) {
        setState(() {
          _error =
              'Phiên đăng nhập Google đã hết hạn. Vui lòng bấm đăng nhập Google lại và hoàn tất trong một lần.';
        });
      } else {
        setState(() => _error = 'Đăng nhập thất bại: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runEmailAction(Future<void> Function() action) async {
    final validationError = _validateEmailPassword();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    await _run(action);
  }

  Future<void> _signUpWithEmail() async {
    final validationError = _validateEmailPassword();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final needsEmailConfirm = await AuthController.signUpStoreWithEmail(
        _emailCtrl.text.trim(),
        _passCtrl.text,
      );
      if (!mounted) return;
      showToast(
        context,
        needsEmailConfirm
            ? 'Tạo tài khoản thành công. Vui lòng xác thực email trước khi đăng nhập.'
            : 'Tạo tài khoản thành công. Bạn có thể đăng nhập ngay.',
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('over_email_send_rate_limit') ||
          msg.contains('email rate limit exceeded')) {
        setState(() {
          _error =
              'Bạn thao tác tạo tài khoản quá nhanh nên bị giới hạn gửi email xác thực. Vui lòng chờ vài phút rồi thử lại, hoặc đăng nhập nếu tài khoản đã tồn tại.';
        });
      } else {
        setState(() => _error = 'Tạo tài khoản thất bại: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đăng nhập Cửa hàng')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.storefront_rounded, size: 64, color: Color(0xFF2563EB)),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _loading ? null : () => _run(AuthController.signInWithGoogle),
                    icon: const Icon(Icons.g_mobiledata_rounded, size: 30),
                    label: const Text('Đăng nhập với Google'),
                  ),
                  const SizedBox(height: 24),
                  const Row(children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('hoặc dùng email', style: TextStyle(color: Colors.black45)),
                    ),
                    Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: Colors.black87),
                    cursorColor: const Color(0xFF2563EB),
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      labelStyle: TextStyle(color: Colors.black87),
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.black87),
                    cursorColor: const Color(0xFF2563EB),
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu',
                      labelStyle: TextStyle(color: Colors.black87),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loading
                              ? null
                              : _signUpWithEmail,
                          child: const Text('Tạo tài khoản'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _loading
                              ? null
                              : () => _runEmailAction(() => AuthController.signInStoreWithEmail(
                                    _emailCtrl.text.trim(),
                                    _passCtrl.text,
                                  )),
                          child: _loading
                              ? const SizedBox(
                                  width: 22, height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Đăng nhập'),
                        ),
                      ),
                    ],
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

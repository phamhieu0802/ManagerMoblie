import 'package:flutter/material.dart';
import '../controllers/auth_controller.dart';

class EmployeeLoginScreen extends StatefulWidget {
  const EmployeeLoginScreen({super.key});

  @override
  State<EmployeeLoginScreen> createState() => _EmployeeLoginScreenState();
}

class _EmployeeLoginScreenState extends State<EmployeeLoginScreen> {
  final _storeCodeCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _googleLoading = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthController.signInEmployee(
        storeCode: _storeCodeCtrl.text.trim(),
        username: _usernameCtrl.text.trim(),
        password: _passCtrl.text,
      );
    } catch (e) {
      setState(() => _error = 'Sai mã cửa hàng, tài khoản hoặc mật khẩu.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitGoogle() async {
    if (_storeCodeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Vui lòng nhập mã cửa hàng trước khi đăng nhập bằng Google.');
      return;
    }
    setState(() {
      _googleLoading = true;
      _error = null;
    });
    try {
      await AuthController.signInWithGoogle(
        isEmployee: true,
        expectedStoreCode: _storeCodeCtrl.text.trim(),
      );
    } catch (e) {
      setState(() => _error = e is EmployeeStoreMismatchException ? e.message : 'Đăng nhập Google thất bại: $e');
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đăng nhập Nhân viên')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.badge_rounded, size: 64, color: Color(0xFF16A34A)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _storeCodeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(color: Colors.black87),
                    cursorColor: const Color(0xFF2563EB),
                    decoration: const InputDecoration(
                      labelText: 'Mã cửa hàng',
                      labelStyle: TextStyle(color: Colors.black87),
                      prefixIcon: Icon(Icons.storefront_outlined),
                      helperText: 'Do quản trị viên cung cấp — cần nhập trước khi đăng nhập',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _googleLoading ? null : _submitGoogle,
                      icon: _googleLoading
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.g_mobiledata_rounded, size: 26),
                      label: const Text('Đăng nhập với Google'),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('hoặc dùng tài khoản nội bộ', style: TextStyle(color: Colors.black54)),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                  ),
                  TextField(
                    controller: _usernameCtrl,
                    style: const TextStyle(color: Colors.black87),
                    cursorColor: const Color(0xFF2563EB),
                    decoration: const InputDecoration(
                      labelText: 'Tên đăng nhập',
                      labelStyle: TextStyle(color: Colors.black87),
                      prefixIcon: Icon(Icons.person_outline),
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
                      child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                    ),
                  ElevatedButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Đăng nhập'),
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

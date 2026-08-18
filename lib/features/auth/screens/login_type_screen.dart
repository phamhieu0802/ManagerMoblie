import 'package:flutter/material.dart';
import 'store_login_screen.dart';
import 'employee_login_screen.dart';

class LoginTypeScreen extends StatelessWidget {
  const LoginTypeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.phone_android_rounded, size: 84, color: Color(0xFF2563EB)),
                  const SizedBox(height: 12),
                  const Text(
                    'Manager MSR',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF111827),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Chọn cách bạn muốn đăng nhập',
                    style: TextStyle(fontSize: 17, color: Color(0xFF4B5563)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  _LoginTypeCard(
                    icon: Icons.storefront_rounded,
                    title: 'Cửa hàng',
                    subtitle: 'Dành cho chủ cửa hàng: tạo cửa hàng, quản lý nhân viên',
                    color: const Color(0xFF2563EB),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const StoreLoginScreen()),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _LoginTypeCard(
                    icon: Icons.badge_rounded,
                    title: 'Nhân viên',
                    subtitle: 'Dành cho lễ tân / kỹ thuật viên đã được cấp tài khoản',
                    color: const Color(0xFF16A34A),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const EmployeeLoginScreen()),
                    ),
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

class _LoginTypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _LoginTypeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 36, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    )),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Color(0xFF4B5563), fontSize: 14)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 28, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_service.dart';
import 'controllers/auth_controller.dart';

/// Sau khi đăng nhập thành công: tải profile, thoát màn push, vào home.
Future<void> completeLoginNavigation(BuildContext context, WidgetRef ref) async {
  if (SupabaseService.currentUser == null) return;

  await ref.read(currentProfileProvider.notifier).load();
  if (!context.mounted) return;

  Navigator.of(context).popUntil((route) => route.isFirst);
  if (!context.mounted) return;

  context.go('/home');
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/supabase_service.dart';
import '../features/auth/controllers/auth_controller.dart';
import '../features/auth/screens/login_type_screen.dart';
import '../features/auth/screens/store_register_screen.dart';
import '../features/home/screens/admin_home_screen.dart';
import '../features/home/screens/receptionist_home_screen.dart';
import '../features/home/screens/technician_home_screen.dart';
import '../models/profile.dart';

Future<Map<String, dynamic>?> _loadOrBootstrapProfile() async {
  final user = SupabaseService.currentUser;
  if (user == null) return null;

  var profileRow = await SupabaseService.client
      .from('profiles')
      .select()
      .eq('id', user.id)
      .maybeSingle();

  if (profileRow != null) return profileRow;

  final metadata = user.userMetadata ?? <String, dynamic>{};
  final guessedName =
      (metadata['full_name'] as String?) ??
      (metadata['name'] as String?) ??
      user.email?.split('@').first ??
      'Chủ cửa hàng';

  await SupabaseService.client.from('profiles').upsert({
    'id': user.id,
    'full_name': guessedName,
    'role': 'admin',
    'is_active': true,
  });

  profileRow = await SupabaseService.client
      .from('profiles')
      .select()
      .eq('id', user.id)
      .maybeSingle();
  return profileRow;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: _AuthRefreshNotifier(),
    redirect: (context, state) async {
      try {
        final loggedIn = SupabaseService.currentUser != null;
        final loggingIn = state.matchedLocation == '/login';

        if (!loggedIn) return loggingIn ? null : '/login';

        // Đã đăng nhập -> tải profile để biết đã có store_id chưa, và role gì
        final profileRow = await _loadOrBootstrapProfile();

        if (profileRow == null) return '/login';

        final profile = Profile.fromMap(profileRow);

        if (profile.storeId == null && profile.role == UserRole.admin) {
          return state.matchedLocation == '/create-store' ? null : '/create-store';
        }

        if (loggingIn || state.matchedLocation == '/create-store') {
          return '/home';
        }
        return null;
      } catch (e, st) {
        // Tránh vòng lặp/treo nếu truy vấn profile lỗi do mạng hoặc session hỏng.
        // In lỗi ra console để debug (chạy `flutter run -d windows` để xem log này).
        // ignore: avoid_print
        print('[app_router] Lỗi khi tải profile sau đăng nhập: $e\n$st');
        return '/login';
      }
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginTypeScreen()),
      GoRoute(path: '/create-store', builder: (context, state) => const StoreRegisterScreen()),
      GoRoute(path: '/home', builder: (context, state) => const _HomeRouterScreen()),
    ],
  );
});

/// Chuyển hướng tới đúng màn hình trang chủ theo vai trò của người dùng.
class _HomeRouterScreen extends ConsumerWidget {
  const _HomeRouterScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(currentProfileProvider);

    return profileAsync.when(
      data: (profile) {
        if (profile == null) return const LoginTypeScreen();
        switch (profile.role) {
          case UserRole.admin:
            return const AdminHomeScreen();
          case UserRole.receptionist:
            return const ReceptionistHomeScreen();
          case UserRole.technician:
            return const TechnicianHomeScreen();
        }
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => Scaffold(body: Center(child: Text('Lỗi: $e'))),
    );
  }
}

/// Cầu nối giữa Supabase authStateChanges và GoRouter (để tự redirect khi login/logout)
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier() {
    SupabaseService.auth.onAuthStateChange.listen((_) => notifyListeners());
  }
}

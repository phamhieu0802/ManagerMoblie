import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/app_config.dart';
import '../../../core/desktop_oauth.dart';
import '../../../core/supabase_service.dart';
import '../../../models/profile.dart';

/// Ném ra khi nhân viên đăng nhập Google nhưng tài khoản Google đó
/// chưa được mời vào đúng cửa hàng có mã đã nhập.
class EmployeeStoreMismatchException implements Exception {
  final String message;
  const EmployeeStoreMismatchException(this.message);
  @override
  String toString() => message;
}

/// Provider expose profile hiện tại (null nếu chưa đăng nhập)
final currentProfileProvider = StateNotifierProvider<ProfileController, AsyncValue<Profile?>>(
  (ref) => ProfileController()..load(),
);

class ProfileController extends StateNotifier<AsyncValue<Profile?>> {
  ProfileController() : super(const AsyncValue.loading());

  Future<void> load() async {
    final user = SupabaseService.currentUser;
    if (user == null) {
      state = const AsyncValue.data(null);
      return;
    }
    try {
      final res = await SupabaseService.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      state = AsyncValue.data(res == null ? null : Profile.fromMap(res));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  void clear() => state = const AsyncValue.data(null);
}

class AuthController {
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: AppConfig.googleWebClientId,
    scopes: const ['email', 'profile'],
  );

  /// Đăng nhập bằng Google thông qua Supabase OAuth.
  /// - Android: dùng native account picker (không mở web)
  /// - Desktop/Web: dùng Supabase OAuth + deep link callback
  ///
  /// [isEmployee] + [expectedStoreCode]: dùng khi đăng nhập với tư cách nhân
  /// viên (không phải chủ cửa hàng) — sau khi đăng nhập Google thành công,
  /// sẽ kiểm tra tài khoản đó có đúng là nhân viên đã được mời vào cửa hàng
  /// có mã này không. Nếu sai/chưa được mời -> tự đăng xuất và báo lỗi rõ ràng.
  static Future<void> signInWithGoogle({
    bool isEmployee = false,
    String? expectedStoreCode,
  }) async {
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (isAndroid) {
      try {
        final googleUser = await _googleSignIn.signIn();
        if (googleUser == null) return;
        final googleAuth = await googleUser.authentication;
        final idToken = googleAuth.idToken;
        final accessToken = googleAuth.accessToken;
        if (idToken == null) {
          throw Exception('Không lấy được Google idToken. Kiểm tra Web Client ID.');
        }
        await SupabaseService.auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: accessToken,
        );
        if (isEmployee) await _verifyEmployeeStoreOrSignOut(expectedStoreCode);
        return;
      } on PlatformException catch (e) {
        if ((e.code == 'sign_in_failed' || e.code == '10') &&
            (e.message?.contains('12500') ?? false)) {
          throw Exception(
            'Google Sign-In Android lỗi 12500. Kiểm tra SHA-1 debug keystore khớp Google Cloud '
            '(chạy: cd android && gradlew signingReport) và thêm Android Client ID vào Supabase Google provider.',
          );
        }
        rethrow;
      }
    }

    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);

    if (isDesktop) {
      await DesktopOAuth.signInWithGoogle(SupabaseService.auth);
      if (isEmployee) await _verifyEmployeeStoreOrSignOut(expectedStoreCode);
      return;
    }

    // Lưu ý: trên web, signInWithOAuth điều hướng cả trang nên phần xác minh
    // nhân viên (nếu cần) không thể await ngay tại đây — lưu mã cửa hàng để
    // listenAuthChanges xác minh lại sau khi quay về app.
    _pendingEmployeeStoreCode = isEmployee ? expectedStoreCode?.trim().toUpperCase() : null;

    await SupabaseService.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: AppConfig.oauthRedirectUri,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
  }

  /// Mã cửa hàng kỳ vọng khi đăng nhập Google với tư cách nhân viên trên web
  /// (vì web bị điều hướng cả trang nên phải xác minh lại sau khi quay về).
  static String? _pendingEmployeeStoreCode;

  /// Kiểm tra sau khi đăng nhập Google với tư cách nhân viên: profile hiện tại
  /// phải có store_id trỏ đúng tới cửa hàng có mã [expectedStoreCode].
  /// Nếu không khớp -> đăng xuất ngay và ném lỗi để UI hiển thị.
  static Future<void> _verifyEmployeeStoreOrSignOut(String? expectedStoreCode) async {
    final code = expectedStoreCode?.trim().toUpperCase();
    if (code == null || code.isEmpty) {
      await signOut();
      throw const EmployeeStoreMismatchException('Vui lòng nhập mã cửa hàng trước khi đăng nhập Google.');
    }

    final user = SupabaseService.currentUser;
    if (user == null) {
      throw const EmployeeStoreMismatchException('Đăng nhập Google thất bại.');
    }

    try {
      final profileRow = await SupabaseService.client
          .from('profiles')
          .select('store_id, role')
          .eq('id', user.id)
          .maybeSingle();

      final storeId = profileRow?['store_id'] as String?;
      if (storeId == null) {
        await signOut();
        throw const EmployeeStoreMismatchException(
          'Tài khoản Google này chưa được mời làm nhân viên cửa hàng nào. '
          'Hãy liên hệ quản trị viên để được mời qua email.',
        );
      }

      final storeRow = await SupabaseService.client
          .from('stores')
          .select('store_code')
          .eq('id', storeId)
          .maybeSingle();

      final actualCode = (storeRow?['store_code'] as String?)?.toUpperCase();
      if (actualCode != code) {
        await signOut();
        throw EmployeeStoreMismatchException(
          'Tài khoản Google này không thuộc cửa hàng có mã "$code". '
          'Vui lòng kiểm tra lại mã cửa hàng.',
        );
      }

      // Đánh dấu lời mời đã được chấp nhận (best-effort, không chặn luồng nếu lỗi).
      try {
        await SupabaseService.client
            .from('employee_invites')
            .update({'status': 'accepted', 'accepted_at': DateTime.now().toIso8601String()})
            .eq('store_id', storeId)
            .eq('email', (user.email ?? '').toLowerCase());
      } catch (_) {}
    } on EmployeeStoreMismatchException {
      rethrow;
    } catch (e) {
      await signOut();
      throw EmployeeStoreMismatchException('Không xác minh được tài khoản nhân viên: $e');
    }
  }

  /// Đăng nhập cửa hàng bằng email/mật khẩu (phương án thay thế nếu không dùng Google)
  static Future<void> signInStoreWithEmail(String email, String password) async {
    await SupabaseService.auth.signInWithPassword(email: email, password: password);
  }

  /// Trả về true nếu cần xác thực email trước khi đăng nhập.
  static Future<bool> signUpStoreWithEmail(String email, String password) async {
    final res = await SupabaseService.auth.signUp(email: email, password: password);
    return res.session == null;
  }

  /// Đăng nhập nhân viên: nhập mã cửa hàng + username + mật khẩu.
  /// Email nội bộ được tạo theo quy ước: <username>.<storeCode>@employee.local
  /// (phải khớp với cách tạo tài khoản trong Edge Function create-employee).
  static Future<void> signInEmployee({
    required String storeCode,
    required String username,
    required String password,
  }) async {
    final internalEmail = '$username.$storeCode@employee.local';
    await SupabaseService.auth.signInWithPassword(
      email: internalEmail,
      password: password,
    );
  }

  /// Reload profile sau khi OAuth/deep link hoàn tất.
  static void listenAuthChanges(WidgetRef ref) {
    SupabaseService.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.tokenRefreshed) {
        // Đẩy access token mới vào Realtime để các channel không bị hết hạn.
        SupabaseService.refreshRealtimeAuth();
      }
      if (data.event == AuthChangeEvent.signedIn ||
          data.event == AuthChangeEvent.tokenRefreshed) {
        // Web: nhân viên đăng nhập Google cần xác minh mã cửa hàng sau khi
        // quay về từ trang OAuth (không thể await ngay lúc điều hướng).
        if (_pendingEmployeeStoreCode != null) {
          final code = _pendingEmployeeStoreCode;
          _pendingEmployeeStoreCode = null;
          if (code != null) {
            _verifyEmployeeStoreOrSignOut(code).then((_) {
              ref.read(currentProfileProvider.notifier).load();
            }).catchError((Object e) {
              // _verifyEmployeeStoreOrSignOut đã tự signOut khi không khớp.
            });
            return;
          }
        }
        ref.read(currentProfileProvider.notifier).load();
      }
      if (data.event == AuthChangeEvent.signedOut) {
        _pendingEmployeeStoreCode = null;
        ref.read(currentProfileProvider.notifier).clear();
      }
    });
  }

  static Future<void> signOut() async {
    await SupabaseService.auth.signOut();
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}

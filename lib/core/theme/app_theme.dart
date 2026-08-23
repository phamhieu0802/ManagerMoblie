import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const primaryColor = Color(0xFF2563EB);
  static const successColor = Color(0xFF16A34A);
  static const warningColor = Color(0xFFF59E0B);
  static const dangerColor = Color(0xFFDC2626);

  static ThemeData light() {
    const textPrimary = Color(0xFF111827);
    const textSecondary = Color(0xFF4B5563);

    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: primaryColor,
      brightness: Brightness.light,
    );

    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      colorScheme: base.colorScheme.copyWith(
        onSurface: textPrimary,
        onPrimaryContainer: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFFF5F7FA),
        foregroundColor: textPrimary,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      iconTheme: const IconThemeData(color: textPrimary),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: const BorderSide(color: Color(0xFFD5DBE3)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: const TextStyle(color: textSecondary),
        labelStyle: const TextStyle(color: textPrimary, fontWeight: FontWeight.w500),
        floatingLabelStyle: const TextStyle(color: primaryColor, fontWeight: FontWeight.w600),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD5DBE3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryColor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dangerColor),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: dangerColor, width: 1.5),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD5DBE3)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}

/// Màu theo trạng thái đơn sửa chữa - dùng cho badge/chip để nhìn phát biết ngay
class StatusColors {
  static const Map<String, Color> map = {
    'received': Color(0xFF64748B),
    'diagnosing': Color(0xFF0EA5E9),
    'waiting_parts': Color(0xFFF59E0B),
    'repairing': Color(0xFF6366F1),
    'repaired': Color(0xFF16A34A),
    'delivered': Color(0xFF14B8A6),
    'cancelled': Color(0xFFDC2626),
  };

  static const Map<String, String> label = {
    'received': 'Tiếp nhận',
    'diagnosing': 'Đang kiểm tra',
    'waiting_parts': 'Chờ linh kiện',
    'repairing': 'Đang sửa',
    'repaired': 'Đã sửa xong',
    'delivered': 'Đã trả máy',
    'cancelled': 'Khách không sửa',
  };
}

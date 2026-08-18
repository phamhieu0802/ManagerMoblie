import 'package:flutter_test/flutter_test.dart';
import 'package:repair_shop_app/features/auth/screens/login_type_screen.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('Login type screen renders main options', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LoginTypeScreen(),
      ),
    );

    expect(find.text('Quản Lý Sửa Chữa'), findsOneWidget);
    expect(find.text('Cửa hàng'), findsOneWidget);
    expect(find.text('Nhân viên'), findsOneWidget);
  });
}

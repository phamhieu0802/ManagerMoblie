import 'package:flutter/material.dart';
import 'salary_screen.dart';

/// Màn Báo cáo S1A (doanh thu đã trả máy) — tách riêng khỏi Thu chi.
class ReportScreen extends StatelessWidget {
  final Widget? appBarLeading;
  const ReportScreen({super.key, this.appBarLeading});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBarLeading,
        title: const Text('Báo cáo'),
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: ReportSection(),
      ),
    );
  }
}

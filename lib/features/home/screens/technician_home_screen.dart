import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/app_shell.dart';
import '../../repair_orders/screens/repair_orders_list_screen.dart';
import '../../dashboard/screens/dashboard_screen.dart';
import '../../finance/screens/salary_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../auth/controllers/auth_controller.dart';

class TechnicianHomeScreen extends ConsumerStatefulWidget {
  const TechnicianHomeScreen({super.key});

  @override
  ConsumerState<TechnicianHomeScreen> createState() => _TechnicianHomeScreenState();
}

class _TechnicianHomeScreenState extends ConsumerState<TechnicianHomeScreen> {
  Key _refreshKey = UniqueKey();

  void _refreshApp() => setState(() => _refreshKey = UniqueKey());

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(currentProfileProvider).value;
    final technicianId = profile?.id;
    return AppShell(
      key: _refreshKey,
      title: 'KTV',
      onTitleTap: _refreshApp,
      tabs: [
        ShellTab(
          label: 'Đơn sửa',
          icon: Icons.build_outlined,
          selectedIcon: Icons.build,
          builder: (leading) =>
              RepairOrdersListScreen(technicianId: technicianId, appBarLeading: leading),
        ),
        ShellTab(
          label: 'Dashboard',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          builder: (leading) =>
              DashboardScreen(technicianId: technicianId, appBarLeading: leading),
        ),
        ShellTab(
          label: 'Bảng lương',
          icon: Icons.paid_outlined,
          selectedIcon: Icons.paid,
          builder: (leading) => Scaffold(
            appBar: AppBar(
              leading: leading,
              title: const Text('Bảng lương'),
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [SalaryHistorySection(employeeId: technicianId)],
            ),
          ),
        ),
      ],
      pushItems: [
        ShellPushItem(
          label: 'Cài đặt',
          icon: Icons.settings_outlined,
          builder: (_) => const SettingsScreen(),
        ),
      ],
    );
  }
}

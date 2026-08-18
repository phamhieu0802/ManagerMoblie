import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import '../../repair_orders/screens/repair_orders_list_screen.dart';
import '../../dashboard/screens/dashboard_screen.dart';
import '../../inventory/screens/inventory_list_screen.dart';
import '../../finance/screens/finance_screen.dart';
import '../../finance/screens/salary_screen.dart';
import '../../finance/screens/report_screen.dart';
import '../../customers/screens/customers_list_screen.dart';
import '../../auth/screens/manage_employees_screen.dart';
import '../../trash/screens/trash_screen.dart';
import '../../settings/screens/settings_screen.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  Key _refreshKey = UniqueKey();

  void _refreshApp() => setState(() => _refreshKey = UniqueKey());

  @override
  Widget build(BuildContext context) {
    return AppShell(
      key: _refreshKey,
      title: 'Quản lý cửa hàng',
      onTitleTap: _refreshApp,
      tabs: [
        ShellTab(
          label: 'Đơn sửa chữa',
          icon: Icons.build_outlined,
          selectedIcon: Icons.build,
          builder: (leading) => RepairOrdersListScreen(appBarLeading: leading),
        ),
        ShellTab(
          label: 'Dashboard',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          builder: (leading) => DashboardScreen(appBarLeading: leading),
        ),
        ShellTab(
          label: 'Kho',
          icon: Icons.inventory_2_outlined,
          selectedIcon: Icons.inventory_2,
          builder: (leading) => InventoryListScreen(appBarLeading: leading),
        ),
        ShellTab(
          label: 'Thu chi',
          icon: Icons.payments_outlined,
          selectedIcon: Icons.payments,
          builder: (leading) => FinanceScreen(appBarLeading: leading),
        ),
        ShellTab(
          label: 'Lương KTV',
          icon: Icons.paid_outlined,
          selectedIcon: Icons.paid,
          builder: (leading) => SalaryScreen(appBarLeading: leading),
        ),
        ShellTab(
          label: 'Báo cáo',
          icon: Icons.insert_chart_outlined,
          selectedIcon: Icons.insert_chart,
          builder: (leading) => ReportScreen(appBarLeading: leading),
        ),
      ],
      pushItems: [
        ShellPushItem(
          label: 'Khách hàng & NCC',
          icon: Icons.people_outline,
          builder: (_) => const CustomersListScreen(),
        ),
        ShellPushItem(
          label: 'Nhân viên',
          icon: Icons.badge_outlined,
          builder: (_) => const ManageEmployeesScreen(),
        ),
        ShellPushItem(
          label: 'Thùng rác',
          icon: Icons.delete_outline,
          builder: (_) => const TrashScreen(),
        ),
        ShellPushItem(
          label: 'Cài đặt',
          icon: Icons.settings_outlined,
          builder: (_) => const SettingsScreen(),
        ),
      ],
    );
  }
}

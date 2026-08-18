import '../models/profile.dart';

enum AppFeature {
  manageEmployees,
  storeSettings,
  viewFinance,
  manageInventory,
  receiveOrders,
  collectPayment,
  printInvoice,
  viewDashboard,
  viewOrders,
  viewCustomers,
  viewTrash,
  assignTechnician,
  changeOrderStatus,
  manageStoreInfo,
  viewPersonalRevenue,
  discordWebhook,
  bankAccounts,
  printerSettings,
  appLogs,
}

class Permissions {
  final UserRole role;

  const Permissions(this.role);

  bool can(AppFeature feature) {
    switch (role) {
      case UserRole.admin:
        return true;
      case UserRole.receptionist:
        switch (feature) {
          case AppFeature.receiveOrders:
          case AppFeature.collectPayment:
          case AppFeature.printInvoice:
          case AppFeature.manageInventory:
          case AppFeature.viewOrders:
          case AppFeature.viewCustomers:
          case AppFeature.viewDashboard:
          case AppFeature.viewFinance:
            return true;
          default:
            return false;
        }
      case UserRole.technician:
        switch (feature) {
          case AppFeature.viewOrders:
          case AppFeature.viewDashboard:
          case AppFeature.viewPersonalRevenue:
          case AppFeature.changeOrderStatus:
            return true;
          default:
            return false;
        }
    }
  }

  String get label => roleLabel(role);
}

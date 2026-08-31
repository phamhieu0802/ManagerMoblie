import 'package:flutter/material.dart';

const String kAppName = 'Manager MSR';
const String kAppVersion = 'v2.1.7';

/// Trang thông tin ứng dụng: phiên bản, tính năng và hướng dẫn sử dụng.
class AppInfoScreen extends StatelessWidget {
  const AppInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thông tin ứng dụng')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: const [
            _AppHeader(),
            SizedBox(height: 12),
            _SectionCard(title: 'Tính năng', child: _FeaturesSection()),
            SizedBox(height: 12),
            _SectionCard(title: 'Hướng dẫn sử dụng', child: _GuideSection()),
            SizedBox(height: 12),
            _SectionCard(title: 'Vai trò & phân quyền', child: _RolesSection()),
            SizedBox(height: 12),
            _SectionCard(title: 'Thông tin cửa hàng', child: _StoreHelpSection()),
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Icon(Icons.build_circle, size: 56, color: Colors.white),
          const SizedBox(height: 8),
          Text(kAppName,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Phiên bản $kAppVersion',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14)),
          const SizedBox(height: 8),
          Text(
            'Phần mềm quản lý cửa hàng sửa chữa điện thoại — đơn hàng, kho linh kiện, tài chính, công nợ, lương & hoa hồng, nhân viên và in hóa đơn.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            'Flutter · Supabase · Realtime · Firebase Cloud Messaging',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  const _FeatureItem({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF1D4ED8)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeaturesSection extends StatelessWidget {
  const _FeaturesSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        _FeatureItem(icon: Icons.dashboard_outlined, title: 'Dashboard tổng quan', desc: 'Biểu đồ thu/chi theo tháng, bảng tổng hợp ngày/tháng, lọc theo nhân viên.' ),
        _FeatureItem(icon: Icons.receipt_long_outlined, title: 'Đơn sửa chữa', desc: 'Tạo/sửa đơn realtime, chọn linh kiện, chụp ảnh, trạng thái nhanh, thanh toán, in hóa đơn, xóa mềm & khôi phục từ thùng rác.' ),
        _FeatureItem(icon: Icons.people_outline, title: 'Khách hàng', desc: 'Danh sách khách, phân loại lẻ/sỉ, gộp thẻ, đa chọn, lịch sử giao dịch.' ),
        _FeatureItem(icon: Icons.inventory_2_outlined, title: 'Kho linh kiện', desc: 'Quản lý tồn kho, barcode, giá sỉ/lẻ, kiểm kho, tự động trừ kho khi xuất.' ),
        _FeatureItem(icon: Icons.account_balance_wallet_outlined, title: 'Tài chính', desc: 'Thu/chi/lãi, lọc thời gian, công nợ (khách hàng & NCC), trả lương & hoa hồng KTV.' ),
        _FeatureItem(icon: Icons.supervisor_account_outlined, title: 'Quản lý nhân viên', desc: '3 vai trò Admin/Lễ tân/KTV, hoa hồng theo %, khóa/mở tài khoản.' ),
        _FeatureItem(icon: Icons.print_outlined, title: 'In hóa đơn', desc: 'Máy in nhiệt qua Bluetooth (Android) hoặc TCP/IP (Windows); header/footer tùy chỉnh.' ),
        _FeatureItem(icon: Icons.qr_code_2_outlined, title: 'Mã QR bảo hành', desc: 'Tự sinh mã QR cho từng đơn, kèm thông tin bảo hành.' ),
        _FeatureItem(icon: Icons.notifications_active_outlined, title: 'Thông báo', desc: 'Push notification qua Firebase + Discord webhook khi có đơn mới hoặc đổi trạng thái.' ),
        _FeatureItem(icon: Icons.cloud_upload_outlined, title: 'Sao lưu & khôi phục', desc: 'Sao lưu lên đám mây, tải về máy, tự động hằng ngày; khôi phục atomic trong 1 giao dịch.' ),
        _FeatureItem(icon: Icons.verified_user_outlined, title: 'Bảo mật', desc: 'Đăng nhập Google hoặc mã cửa hàng + username, phân quyền theo vai trò (RLS).' ),
      ],
    );
  }
}

class _GuideItem extends StatelessWidget {
  final String step;
  final String text;
  const _GuideItem({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: const Color(0xFF1D4ED8),
            child: Text(step,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.35)),
          ),
        ],
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  const _GuideSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text('Bắt đầu', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        SizedBox(height: 8),
        _GuideItem(step: '1', text: 'Chủ cửa hàng đăng nhập bằng Google → lần đầu tạo cửa hàng → nhận mã cửa hàng.'),
        _GuideItem(step: '2', text: 'Vào tab Nhân viên → Thêm nhân viên (chọn vai trò Lễ tân/KTV, đặt username + mật khẩu).'),
        _GuideItem(step: '3', text: 'Nhân viên đăng nhập bằng: mã cửa hàng + username + mật khẩu.'),
        SizedBox(height: 10),
        Text('Vận hành hàng ngày', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        SizedBox(height: 8),
        _GuideItem(step: '1', text: 'Tạo đơn sửa chữa: chọn khách hàng, loại máy, mô tả lỗi, linh kiện, chụp ảnh.'),
        _GuideItem(step: '2', text: 'Theo dõi trạng thái: tiếp nhận → đang sửa → xong → đã trả máy. Bấm vào đơn để mở chi tiết; bấm icon để chọn nhiều đơn.'),
        _GuideItem(step: '3', text: 'Khi trả máy: chọn hình thức thanh toán (tiền mặt/chuyển khoản/ghi nợ), doanh thu tự động cập nhật.'),
        _GuideItem(step: '4', text: 'Kho: nhập linh kiện, khi xuất dùng tự động trừ tồn kho; kiểm kho định kỳ.'),
        _GuideItem(step: '5', text: 'Tài chính: theo dõi thu/chi, công nợ, trả lương & hoa hồng theo % của từng KTV.'),
        _GuideItem(step: '6', text: 'In hóa đơn: chọn đơn → In → chọn máy in (Bluetooth/TCP) → In ngay.'),
      ],
    );
  }
}

class _RolesSection extends StatelessWidget {
  const _RolesSection();

  @override
  Widget build(BuildContext context) {
    Widget row(String role, String colorText, String perms) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(role,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                      color: switch (role) {
                        'Admin' => const Color(0xFFDC2626),
                        'Lễ tân' => const Color(0xFF16A34A),
                        _ => const Color(0xFF2563EB),
                      })),
            ),
            Expanded(child: Text(perms, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.35))),
          ],
        ),
      );
    }

    return Column(
      children: [
        row('Admin', '', 'Toàn quyền: quản lý nhân viên, lương & hoa hồng, cài đặt cửa hàng, máy in, Discord, thùng rác.'),
        row('Lễ tân', '', 'Đơn sửa chữa, khách hàng, kho, thu chi, in hóa đơn. Cập nhật trạng thái bị giới hạn.'),
        row('KTV', '', 'Dashboard, đơn được giao cho mình, cập nhật trạng thái sửa chữa.'),
      ],
    );
  }
}

class _StoreHelpSection extends StatelessWidget {
  const _StoreHelpSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StoreHelpTile(icon: Icons.storefront_outlined, title: 'Thông tin cửa hàng',
            desc: 'Tên, địa chỉ, số điện thoại, mã số thuế — hiển thị trên hóa đơn.'),
        _StoreHelpTile(icon: Icons.account_balance_outlined, title: 'Thông tin ngân hàng',
            desc: 'Nhập ngân hàng, số tài khoản, chi nhánh để in trên hóa đơn chuyển khoản.'),
        _StoreHelpTile(icon: Icons.print_outlined, title: 'Cấu hình máy in',
            desc: 'Android dùng Bluetooth; Windows dùng TCP/IP (IP:Port). Bấm "Kiểm tra kết nối" để thử.'),
        _StoreHelpTile(icon: Icons.webhook_outlined, title: 'Discord webhook',
            desc: 'Dán Webhook URL để nhận thông báo đơn mới/đổi trạng thái; liên kết Discord ID để được mention.'),
        _StoreHelpTile(icon: Icons.palette_outlined, title: 'Giao diện in',
            desc: 'Chỉnh dòng chạy đầu và cuối mỗi hóa đơn (ví dụ: "Cảm ơn quý khách!").'),
        _StoreHelpTile(icon: Icons.lock_reset, title: 'Đổi mật khẩu',
            desc: 'Đổi mật khẩu đăng nhập của tài khoản hiện tại.'),
      ],
    );
  }
}

class _StoreHelpTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  const _StoreHelpTile({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

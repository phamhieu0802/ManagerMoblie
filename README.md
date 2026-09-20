# Manager MSR — Ứng Dụng Quản Lý Cửa Hàng Sửa Chữa Điện Thoại

Flutter (Android + Windows + Linux) + Supabase (Auth, DB realtime, Storage) + Firebase Cloud Messaging.

**Manager MSR · v2.1.11**

## Tính năng đã hoàn thiện

- **Auth 3 vai trò**: Admin (toàn quyền), Lễ tân (đơn, khách, kho, thu chi, in), KTV (đơn được giao + dashboard)
- **Dashboard**: tổng quan doanh thu, đơn đang làm, đơn quá hạn, lọc theo KTV
- **Quản lý nhân viên**: thêm/xóa, set % hoa hồng, khóa/mở tài khoản, mật khẩu tạm an toàn, validate username
- **Đơn sửa chữa**: tạo/sửa realtime, chọn linh kiện, chụp ảnh, cập nhật trạng thái nhanh, thanh toán khi lập phiếu (tiền mặt/chuyển khoản), in hóa đơn, xóa mềm
- **Danh sách đơn thông minh**: bấm vào đơn = mở bảng sửa đơn, bấm icon = chọn nhiều đơn, bấm vào phần giá = popup sửa giá nhanh (đơn đang tiếp nhận/sửa)
- **Trạng thái giá theo màu**: đỏ = hủy, cam = đã trả máy nhưng ghi nợ, xanh = đã thu đủ tiền
- **Hạch toán tự động**: doanh thu + công nợ + trừ kho tự động khi trả máy, đảo ngược chính xác khi hủy/đổi trạng thái (idempotent, atomic)
- **Khách hàng**: CRUD, phân loại lẻ/sỉ
- **Kho linh kiện**: quản lý tồn kho, barcode/IMEI, nhãn hiệu, giá sỉ/lẻ, kiểm kho, cập nhật giá Bulk, trừ kho atomic chống âm
- **Tài chính**: 4 tab — Tổng quan (thu/chi/lãi), Giao dịch, Công nợ (khách hàng & nhà cung cấp), Lương & hoa hồng (trả lương atomic, chặn vượt dư nợ). Danh mục thu/chi có nút "+" thêm nhanh ngay trong popup, ô nhập tiền tự định dạng nghìn
- **Xem đơn từ màn hình thu chi**: bấm vào giao dịch gắn đơn sửa chữa → xem đơn (chế độ chỉ đọc), bấm "Đi tới đơn" để chuyển sang tab Đơn sửa chữa
- **Realtime tự phục hồi**: tự kết nối lại khi socket rớt; ép reset hoàn toàn nếu rớt quá nhiều
- **Cài đặt**: thông tin cửa hàng, ngân hàng (tên/STK/chi nhánh), in hóa đơn (header/footer), máy in (Bluetooth Android / TCP Windows), Discord webhook, liên kết Discord ID cá nhân
- **Thông tin ứng dụng**: trang trong app hiển thị phiên bản, tính năng và hướng dẫn sử dụng
- **Sao lưu & khôi phục**: xuất toàn bộ dữ liệu cửa hàng ra file JSON (lưu máy) hoặc đẩy lên đám mây (Supabase Storage, giữ tối đa 20 bản); bật tự động sao lưu hằng ngày; khôi phục từ file hoặc từ đám mây — chạy atomic trong 1 transaction (chỉ admin)
- **Làm sạch cửa hàng**: xóa toàn bộ dữ liệu nghiệp vụ của cửa hàng trong 1 transaction (chỉ admin, phải gõ XÓA SẠCH để xác nhận); không xóa tài khoản, thông tin cửa hàng và file backup
- **Discord webhook**: tự động thông báo đơn mới + đổi trạng thái, mention KTV bằng Discord ID
- **Mã QR bảo hành**: tự động sinh QR khi tạo đơn
- **Thùng rác**: khôi phục đơn bị xóa
- **Bảo mật RLS**: policy cập nhật profile cho chính mình, unique trả lương, kiểm tra cửa hàng khi sửa nhân viên
- **Windows nâng cao**: tự khởi động cùng Windows (registry), ghi nhớ kích thước/vị trí cửa sổ

## Cấu trúc thư mục

```
lib/
├── core/           # Config, Supabase, Firebase, theme, permissions, printer, Discord, photo upload, window/startup services
├── models/         # Profile, Store, RepairOrder
├── features/
│   ├── auth/       # Login (Google + employee code), đăng ký cửa hàng, quản lý nhân viên
│   ├── home/       # Trang chủ theo vai trò (admin/lễ tân/KTV)
│   ├── dashboard/  # Dashboard tổng quan
│   ├── repair_orders/ # Danh sách đơn sửa chữa (realtime)
│   ├── customers/  # Danh sách khách hàng
│   ├── inventory/  # Kho linh kiện
│   ├── finance/    # Thu chi (xem đơn từ giao dịch)
│   ├── settings/   # Cài đặt cửa hàng, in ấn, Discord, Thông tin ứng dụng
│   └── trash/      # Thùng rác
├── routing/        # GoRouter + phân quyền theo vai trò
├── widgets/        # StatusChip, RealtimeStreamView, NotificationBell, ...
└── main.dart
```

## Cài đặt & Chạy

Xem file `HUONGDAN.md` trong thư mục dự án (Android + Windows) và `HUONGDAN_LINUX.md` (build & chạy trên Linux).

# Hướng Dẫn Cài Đặt & Sử Dụng

**Manager MSR · v2.1.0** — Phần mềm quản lý cửa hàng sửa chữa điện thoại (Android + Windows).

## 0. Xem hướng dẫn ngay trong app

Mở **Cài đặt → Thông tin ứng dụng** để xem phiên bản, danh sách tính năng, hướng dẫn sử dụng và bảng phân quyền vai trò ngay trên điện thoại/máy tính, không cần tài liệu.

## 1. Yêu cầu hệ thống

- **Flutter SDK** 3.24+ (stable channel)
- **Dart SDK** 3.5+
- **Android Studio** (để build APK) hoặc **Visual Studio 2022** (cho Windows)
- **Supabase** project: `rsjonbpkocfylnpdvach` (đã tạo sẵn)
- **Firebase** project: `repairmobileapp` (cho push notification)

---

## 2. Tạo project Flutter & copy code

```bash
flutter create --org com.phonerepair repair_shop_app
cd repair_shop_app
# Copy tất cả code từ source vào project này
flutter pub get
```

Bật nền tảng Windows (nếu chạy trên Windows):
```bash
flutter config --enable-windows-desktop
flutter create --platforms=windows .
```

### Cấu hình build Android

Trong `android/app/build.gradle`, đảm bảo:
```gradle
defaultConfig {
    applicationId "com.phonerepair.phone_repair_shop"
    minSdk 23           // Firebase Messaging yêu cầu
    targetSdk 34
}
```

---

## 3. Supabase

### 3.1. Chạy schema

Vào **Supabase Dashboard → SQL Editor**, chạy file `database/schema_full.sql`.

File này chứa toàn bộ schema hoàn chỉnh (bảng, RLS, functions, triggers, storage, realtime) đã được gộp từ tất cả migrations. Chỉ cần chạy **1 lần duy nhất** — đã bao gồm tất cả các patch.

**Lưu ý**: File idempotent (có `IF NOT EXISTS` / `DROP IF EXISTS`) nên có thể chạy lại an toàn nếu bị lỗi giữa chừng.

Sau khi chạy xong, **kiểm tra Realtime** đã bật cho các bảng chưa. Vào **Supabase Dashboard → Database → Replication**, đảm bảo publication `supabase_realtime` có tick tất cả bảng.

### 3.2. Deploy Edge Functions

```bash
# Đăng nhập Supabase
supabase login
supabase link --project-ref rsjonbpkocfylnpdvach

# Deploy functions
supabase functions deploy create-employee
supabase functions deploy send-push
supabase functions deploy update-employee
```

Set secrets cho Edge Functions:
```bash
supabase secrets set FCM_PROJECT_ID=repairmobileapp
supabase secrets set FCM_SERVICE_ACCOUNT_JSON='{...nội dung service-account.json...}'
```

### 3.3. Tạo Database Webhook

Trong Supabase Dashboard → **Database → Webhooks**:
- Tên: `send-push-on-notification`
- Bảng: `notifications`
- Sự kiện: `Insert`
- Loại: `HTTP Request`
- URL: `https://rsjonbpkocfylnpdvach.supabase.co/functions/v1/send-push`
- Headers: `Authorization: Bearer <service_role_key>`

Hoặc chạy file `create_webhook_via_sql.sql` (đã có sẵn key service_role).

### 3.4. Authentication

Trong **Supabase Dashboard → Authentication → Providers**:
- **Google**: bật ON, điền Web Client ID và Android Client ID (lấy từ Google Cloud Console)
- **URL Configuration**: redirect `io.supabase.flutter://login-callback/`

### 3.5. Storage

Tạo bucket `repair-photos` (public: **OFF**, chỉ user trong cửa hàng mới xem được). Các file SQL patch đã có RLS policy cho storage objects.

---

## 4. Firebase (Push Notification)

1. **Firebase Console → Project settings → General → Your apps → Add app → Android**
   - Package name: `com.phonerepair.phone_repair_shop`
   - Tải file `google-services.json` và copy vào `android/app/`
2. **Service Accounts** → Generate new private key → lưu JSON, dùng cho `FCM_SERVICE_ACCOUNT_JSON` ở bước 3.2
3. **Lưu ý**: Windows không hỗ trợ FCM, app tự động bỏ qua. Trên Windows, thông báo hiển thị trong app qua Realtime.

---

## 5. Google Cloud Console

### Web Client ID
`673017899305-52iugltftlg8b2kt7cimketm1heg31u2.apps.googleusercontent.com`

### Android Client ID
`673017899305-iam9d16goiikfqqbprkl9ds5lhup3tgf.apps.googleusercontent.com`

### Authorized redirect URIs (cho OAuth)
- `https://rsjonbpkocfylnpdvach.supabase.co/auth/v1/callback`
- `io.supabase.flutter://login-callback/`

Khi build **release**, thêm SHA-1 của keystore release vào Android Client ID.

---

## 6. Chạy thử

```bash
# Android
flutter run

# Windows
flutter run -d windows
```

### Tài khoản mẫu
- **Admin**: đăng nhập bằng Google → tự động tạo cửa hàng
- **Nhân viên**: Admin vào tab Nhân viên → Thêm nhân viên → dùng mã cửa hàng + username + mật khẩu để đăng nhập

---

## 7. Cấu hình sau khi chạy

### 7.1. Cài đặt Discord Webhook

1. Mở **Cài đặt → Discord Webhook**
2. Nhập Webhook URL từ Discord (Server Settings → Integrations → Webhooks)
3. Nhấn **Lưu**
4. Mỗi nhân viên có thể liên kết Discord ID cá nhân để được mention khi có đơn mới

### 7.2. Cài đặt máy in

1. Mở **Cài đặt → Cài đặt máy in**
2. Chọn loại kết nối:
   - **Android**: Bluetooth (nhập địa chỉ Bluetooth của máy in nhiệt)
   - **Windows**: TCP/IP (nhập `IP:Port`, ví dụ `192.168.1.100:9100`)
3. Bấm **Kiểm tra kết nối** để xác minh — gửi lệnh ESC/POS init + in hóa đơn mẫu + cắt giấy
4. Trong màn hình danh sách đơn, chọn đơn → bấm nút In → **In ngay** để in trực tiếp

### 7.3. Windows — tính năng đặc thù

- **OAuth Google**: dùng localhost HTTP server + trình duyệt, không cần custom URL scheme
- **Thông báo toast**: hiển thị notification qua `flutter_local_notifications` (Supabase Realtime → Windows toast)
- **In ấn ESC/POS**: gửi lệnh init printer + UTF-8 + cắt giấy qua TCP/IP
- **Tự động hồi sinh Realtime**: định kỳ kiểm tra kết nối và tự kết nối lại nếu socket bị rớt
- **Đăng ký OAuth protocol**: tự động tạo registry key `io.supabase.flutter://` khi khởi động

### 7.4. Danh sách đơn sửa chữa — mẹo dùng nhanh

- **Bấm vào đơn** → mở bảng sửa đơn (chi tiết, trạng thái, linh kiện, ảnh).
- **Bấm vào icon** (đầu dòng) → chọn / bỏ chọn nhiều đơn để làm việc hàng loạt (thay trạng thái, in, xóa).
- **Bấm vào phần giá tiền** (với đơn đang **Tiếp nhận** hoặc **Đang sửa**) → popup sửa giá nhanh, ô nhập có viền cam nổi bật kèm giá hiện tại.
- **Màu giá tiền** báo trạng thái:
  - **Đỏ** — đơn bị hủy.
  - **Xanh** — đã trả máy và thu đủ tiền.
  - **Cam** — đã trả máy nhưng **ghi nợ** (chưa thu được tiền) — cần theo dõi thu nợ.
  - **Xám** — đơn chưa trả máy.

### 7.5. Sao lưu & khôi phục dữ liệu (Admin)

Vào **Cài đặt → Sao lưu & khôi phục**:

- **Sao lưu lên đám mây**: đẩy toàn bộ dữ liệu (khách hàng, đơn, kho, thu chi, công nợ, lương, QR...) thành 1 file JSON lên Supabase Storage. App tự giữ **tối đa 20 bản** gần nhất, tự xóa bản cũ.
- **Tải file về máy**: trên Windows mở hộp thoại chọn nơi lưu; trên Android lưu vào thư mục Documents của app.
- **Tự động sao lưu hằng ngày**: bật công tắc → mỗi ngày mở app 1 lần là tự đẩy bản sao mới lên đám mây (nếu đã qua 24h so với lần trước).
- **Khôi phục**: chọn backup từ file hoặc từ danh sách đám mây → xác nhận → dữ liệu hiện tại được thay thế bằng dữ liệu trong backup. Toàn bộ quá trình chạy **trong 1 giao dịch**: nếu lỗi giữa chừng thì không ảnh hưởng dữ liệu hiện có.
  - Lưu ý: file backup **chỉ khôi phục được cho đúng cửa hàng** (khớp mã cửa hàng), tránh ghi nhầm.
  - Không khôi phục tài khoản đăng nhập (profiles) — nhân viên vẫn đăng nhập bằng tài khoản riêng.

- **Làm sạch cửa hàng** (mục cuối màn hình): xóa **toàn bộ** dữ liệu nghiệp vụ của cửa hàng (đơn, khách hàng, kho, thu chi, công nợ, lương, QR, ảnh sửa máy...). Chỉ admin mới làm được; phải gõ chính xác **XÓA SẠCH** để xác nhận.
  - ⚠️ **Không thể hoàn tác** — chỉ làm khi thật sự muốn bắt đầu lại từ đầu.
  - KHÔNG xóa tài khoản đăng nhập, thông tin cửa hàng và các file backup — vẫn đăng nhập và khôi phục lại được nếu đã có bản sao.

### 7.6. Thông tin chuyển khoản

Vào **Cài đặt → Thông tin ngân hàng** để nhập tên ngân hàng, số tài khoản, chi nhánh — hiển thị trên hóa đơn in.

### 7.7. Header/Footer hóa đơn

Vào **Cài đặt → Giao diện in** để nhập dòng chạy đầu và cuối mỗi hóa đơn (ví dụ: "Cảm ơn quý khách!").

---

## 8. Phân quyền chi tiết

| Tính năng | Admin | Lễ tân | KTV |
|-----------|-------|--------|-----|
| Dashboard tổng quan | ✔ | ✔ | ✔ |
| Đơn sửa chữa (tất cả) | ✔ | ✔ | ✘ |
| Đơn được giao | ✔ | ✔ | ✔ |
| Tạo / sửa đơn | ✔ | ✔ | ✘ |
| Cập nhật trạng thái | ✔ | hạn chế | ✔ |
| Gán KTV | ✔ | ✘ | ✘ |
| Khách hàng | ✔ | ✔ | ✘ |
| Kho linh kiện | ✔ | ✔ | ✘ |
| Thu chi | ✔ | ✔ | ✘ |
| Lương & hoa hồng | ✔ | ✘ | ✘ |
| Quản lý nhân viên | ✔ | ✘ | ✘ |
| Cài đặt cửa hàng | ✔ | ✘ | ✘ |
| Discord webhook | ✔ | ✘ | ✘ |
| Cấu hình máy in | ✔ | ✘ | ✘ |
| Thùng rác | ✔ | ✘ | ✘ |

---

## 9. Cấu trúc database chính

| Bảng | Mục đích |
|------|----------|
| `stores` | Cửa hàng (tên, mã, địa chỉ, bank info, webhook, printer) |
| `profiles` | Người dùng (vai trò, username, hoaồng, Discord ID) |
| `customers` | Khách hàng (lẻ/sỉ, xoá mềm) |
| `repair_orders` | Đơn sửa chữa (realtime, soft delete) |
| `repair_order_status_history` | Lịch sử trạng thái đơn |
| `part_categories` | Phân loại linh kiện |
| `inventory_parts` | Linh kiện (barcode, IMEI, tồn kho, NCC) |
| `inventory_transactions` | Giao dịch kho (nhập/xuất/điều chỉnh) |
| `stock_counts` | Lịch sử kiểm kho |
| `cash_accounts` | Tài khoản tiền mặt/chuyển khoản |
| `transactions` | Giao dịch thu/chi |
| `debts` | Công nợ |
| `debt_transactions` | Chi tiết công nợ |
| `salary_payments` | Trả lương & hoa hồng |
| `notifications` | Thông báo push (DB Webhook → Edge Function → FCM) |
| `qr_codes` | Mã QR bảo hành |
| `employee_invites` | Mời nhân viên |
| `app_logs` | Nhật ký hoạt động |
| Storage bucket `backups` | File backup JSON (tự động + thủ công) |
| Storage bucket `repair-photos` | Ảnh sửa máy |
| RPC `restore_store_data` | Khôi phục dữ liệu cửa hàng từ backup (atomic) |
| RPC `clear_store_data` | Xóa toàn bộ dữ liệu nghiệp vụ (Admin) |
| RPC `decrement_stock` | Tự động trừ tồn kho nguyên tử |

---

## 10. Luồng đăng nhập

1. Mở app → chọn **Cửa hàng** hoặc **Nhân viên**
2. **Cửa hàng**: đăng nhập Google → lần đầu → tạo cửa hàng → nhận mã cửa hàng
3. **Admin** vào tab Nhân viên → Thêm nhân viên → nhập username/mật khẩu/vai trò
4. **Nhân viên** đăng nhập bằng: mã cửa hàng + username + mật khẩu
5. App tự chuyển tới trang chủ phù hợp với vai trò

---

## 11. FAQ / Xử lý sự cố

**Q**: Mất kết nối Realtime, dữ liệu không cập nhật tự động?
**R**: Vào **Supabase Dashboard → Database → Replication** kiểm tra publication `supabase_realtime` đã có đủ bảng chưa. Chạy lại file `database/schema_full.sql`.

**Q**: Đăng nhập Google báo lỗi?
**R**: Kiểm tra Web Client ID trong `lib/core/app_config.dart` khớp với Google Cloud Console. Thêm SHA-1 release nếu build bản release.

**Q**: In hóa đơn không ra?
**R**: Kiểm tra địa chỉ máy in (Bluetooth / TCP). Trên Windows thử dùng `telnet IP PORT` để kiểm tra kết nối TCP.

**Q**: Discord không thông báo?
**R**: Vào **Cài đặt → Discord Webhook** kiểm tra URL. Webhook URL phải bắt đầu bằng `https://discord.com/api/webhooks/`. Kiểm tra Discord ID cá nhân đã nhập chính xác (lấy từ Discord: User Settings → Advanced → Developer Mode → chuột phải tên → Copy ID).

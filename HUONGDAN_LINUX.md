# Hướng dẫn build & chạy app trên Linux / Ubuntu

Hướng dẫn này dành cho việc chạy **Manager MSR** (app quản lý cửa hàng sửa chữa điện thoại) trên máy tính **Linux (Ubuntu)** dưới dạng ứng dụng **desktop**.

> ⚠️ Lưu ý quan trọng: App được phát triển/build chủ yếu trên **Windows**. File build Linux **không thể tạo trên Windows** (cần trình biên dịch + thư viện GTK của Linux). Bạn phải chạy lệnh build trên **máy/máy ảo Ubuntu** — làm theo hướng dẫn bên dưới.

---

## 1. Chuẩn bị (làm 1 lần trên máy Ubuntu)

### 1.1 Cài đặt các gói hệ thống cần thiết

Mở Terminal và chạy:

```bash
sudo apt update
sudo apt install -y \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev \
  libstdc++-12-dev \
  git \
  curl \
  unzip
```

> Nếu máy dùng Ubuntu 22.04 trở lên, `libstdc++-12-dev` có sẵn. Nếu báo không tìm thấy, có thể bỏ dòng đó hoặc cài thêm `build-essential`.

### 1.2 Cài đặt Flutter SDK (nếu chưa có)

Kiểm tra đã có Flutter chưa:

```bash
flutter --version
```

Nếu chưa có, cài theo hướng dẫn chính thức:

```bash
# Tải Flutter ổn định (thay {version} bằng bản mới nhất, ví dụ 3.x.x):
cd ~
git clone https://github.com/flutter/flutter.git -b stable
# Thêm flutter vào PATH (thêm vào ~/.bashrc hoặc ~/.profile):
export PATH="$PATH:$HOME/flutter/bin"
# Áp dụng lại
source ~/.bashrc
flutter --version
```

Sau đó bật hỗ trợ desktop Linux:

```bash
flutter config --enable-linux-desktop
```

---

## 2. Lấy mã nguồn

### Cách A — Clone từ GitHub

```bash
git clone https://github.com/phamhieu0802/ManagerMoblie.git
cd ManagerMoblie
```

### Cách B — Copy từ máy Windows

Nếu bạn có code đang nằm trên máy Windows, hãy copy cả thư mục dự án (ví dụ `repair_shop_app`) sang máy Ubuntu bằng USB / network / cloud, rồi:

```bash
cd repair_shop_app
```

> Bắt buộc phải có đủ thư mục `linux/` (đã có sẵn trong repo) — chứa cấu hình build cho Linux.

---

## 3. Build ứng dụng

### Cài thư viện Dart

```bash
flutter pub get
```

### Build bản Release

```bash
flutter build linux --release
```

Khi thành công, file chạy nằm trong:

```
build/linux/x64/release/bundle/
```

---

## 4. Chạy ứng dụng

### Cách 1 — Chạy trực tiếp từ thư mục build

```bash
./build/linux/x64/release/bundle/repair_shop_app
```

### Cách 2 — Tạo file chạy nhanh (desktop launcher)

```bash
# Tạo file .desktop để có thể bấm mở từ menu ứng dụng
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/manager_msr.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Manager MSR
Comment=App quản lý cửa hàng sửa chữa điện thoại
Exec=/ĐƯỜNG_DẪN/build/linux/x64/release/bundle/repair_shop_app
Path=/ĐƯỜNG_DẪN/build/linux/x64/release/bundle
Terminal=false
Categories=Office;Utility;
EOF
```

Thay `ĐƯỜNG_DẪN` bằng đường dẫn thật tới thư mục dự án.

### Cách 3 — Chạy ở chế độ Debug (phát triển)

```bash
flutter run -d linux
```

---

## 5. Đóng gói thành file .deb (để cài đặt dễ dàng)

Nếu muốn tạo file cài đặt `.deb` để phân phối/install:

```bash
# Tạo cấu trúc gói
rm -rf packaging && mkdir -p packaging/DEBIAN packaging/opt/manager_msr
cp -r build/linux/x64/release/bundle/* packaging/opt/manager_msr/

# Tạo file control
cat > packaging/DEBIAN/control << 'EOF'
Package: manager-msr
Version: 2.1.7
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Pham Hieu <you@example.com>
Description: App quản lý cửa hàng sửa chữa điện thoại
Depends: libgtk-3-0, libsecret-1-0
EOF

# Đóng gói
dpkg-deb --build packaging
```

Kết quả là file `packaging.deb`. Cài bằng:

```bash
sudo dpkg -i packaging.deb   # hoặc: sudo apt install ./packaging.deb
```

---

## 6. Những tính năng KHÔNG hoạt động trên Linux

Do plugin phụ thuộc nền tảng, một số tính năng **sẽ không hoạt động trên Linux**:

| Tính năng | Trạng thái |
|-----------|------------|
| In qua **máy in Bluetooth / BLE** | ❌ Không hỗ trợ (plugin `flutter_blue_plus` không có bản Linux) |
| **Windows printer** (in tài liệu qua máy in mặc định) | ⚠️ Dùng thư viện `printing` — hoạt động nếu hệ có CUPS cài sẵn |
| Yêu cầu cấp quyền (permission) | ⚠️ Trên Linux thường không cần |
| Đăng nhập **Google** | ⚠️ Có thể không hoạt động nếu thiếu plugin Google Sign-In cho Linux |
| Tự động cập nhật (auto-update, kiểm tra bản mới từ GitHub) | ⚠️ Kiểm tra bản mới hoạt động, nhưng tải về/áp dụng bản cập nhật thiết kế cho Windows |

**Đề xuất:** Với máy dùng Ubuntu, hãy dùng **máy in nhiệt/giấy qua Windows printer** hoặc chọn `Tự kết nối` cổng khác phù hợp, hoặc in gián tiếp.

---

## 7. Khắc phục sự cố thường gặp

| Lỗi | Cách khắc phục |
|-----|----------------|
| `CMake Error ... Could NOT find PkgConfig` | Chạy lại bước cài: `sudo apt install -y pkg-config cmake ninja-build` |
| `libgtk-3-dev` thiếu | `sudo apt install -y libgtk-3-dev` |
| `MissingPluginException: Bluetooth` khi mở cài đặt máy in | Là tính năng BLE không hỗ trợ trên Linux (xem mục 6) |
| `fatal error: 'sys/...' not found` | Cài thêm: `sudo apt install -y build-essential libstdc++-12-dev` |
| Lỗi `flutter: command not found` | Chưa thêm Flutter vào PATH — chạy lại `export PATH="$PATH:$HOME/flutter/bin"` |
| App chạy nhưng không kết nối được server | Kiểm tra mạng + cấu hình Supabase (cần kết nối internet tới backend) |

---

## 8. Phiên bản hiện tại

- App version hiện tại: **2.1.7**
- Repo: https://github.com/phamhieu0802/ManagerMoblie

Nếu bạn cần cài đặt phiên bản Windows hoặc Android, xem thêm [HUONGDAN.md](./HUONGDAN.md).

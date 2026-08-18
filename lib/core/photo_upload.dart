import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Lỗi do người dùng chưa cấp quyền camera / thư viện ảnh (Android).
class PhotoPermissionException implements Exception {
  final String message;
  const PhotoPermissionException(this.message);

  @override
  String toString() => message;
}

/// Chụp ảnh (camera thật trên Android; trên Windows desktop image_picker
/// CHƯA hỗ trợ mở camera trực tiếp — theo tài liệu chính thức plugin, nên
/// sẽ tự động chuyển sang mở hộp chọn file ảnh có sẵn thay thế) rồi tự
/// resize về kích thước HD (cạnh dài nhất tối đa 1280px) và nén JPEG chất
/// lượng 85 để tiết kiệm dung lượng lưu trữ.
Future<Uint8List?> captureAndResizePhoto() async {
  final picker = ImagePicker();
  final supportsCamera = await picker.supportsImageSource(ImageSource.camera);
  XFile? file;
  try {
    file = await picker.pickImage(
      source: supportsCamera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 90,
    );
  } on PlatformException catch (e) {
    // Android: người dùng chối quyền camera/thư viện → báo lỗi rõ ràng thay vì
    // hiện lỗi thô không giải thích.
    final denied = e.code == 'camera_access_denied' ||
        e.code == 'photo_access_denied' ||
        e.code == 'access_denied' ||
        e.code == 'permission_denied';
    if (denied) {
      throw const PhotoPermissionException(
        'Chưa cấp quyền truy cập camera/thư viện. Vào Cài đặt để bật quyền.',
      );
    }
    rethrow;
  }
  if (file == null) return null;

  final bytes = await file.readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  const maxDimension = 1280; // HD
  var resized = decoded;
  if (decoded.width > maxDimension || decoded.height > maxDimension) {
    resized = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxDimension)
        : img.copyResize(decoded, height: maxDimension);
  }
  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}

/// Upload bytes ảnh lên Supabase Storage bucket "repair-photos" tại đường
/// dẫn {storeId}/{orderId}/{fileName}, trả về path đã lưu (dùng để tạo lại
/// signed URL khi cần hiển thị).
Future<String> uploadRepairPhoto({
  required String storeId,
  required String orderId,
  required String fileName,
  required Uint8List bytes,
}) async {
  final path = '$storeId/$orderId/$fileName';
  await SupabaseService.client.storage.from('repair-photos').uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
  return path;
}

/// Tạo signed URL tạm thời (bucket ở chế độ private) để hiển thị lại ảnh.
Future<String?> getRepairPhotoUrl(String path) async {
  try {
    return await SupabaseService.client.storage.from('repair-photos').createSignedUrl(path, 3600);
  } catch (_) {
    return null;
  }
}

/// Upload 1 file ảnh của cửa hàng (VD: mã QR chuyển khoản) lên bucket
/// "repair-photos" tại {storeId}/{fileName}, trả về path đã lưu.
Future<String> uploadStoreFile({
  required String storeId,
  required String fileName,
  required Uint8List bytes,
}) async {
  final path = '$storeId/$fileName';
  await SupabaseService.client.storage
      .from('repair-photos')
      .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
  return path;
}

/// Tải xuống file ảnh của cửa hàng (VD: mã QR để in lên phiếu).
Future<Uint8List?> downloadStoreFile(String path) async {
  try {
    return await SupabaseService.client.storage.from('repair-photos').download(path);
  } catch (_) {
    return null;
  }
}

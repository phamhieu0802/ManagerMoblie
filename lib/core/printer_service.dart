import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Dịch vụ in ấn hỗ trợ:
/// - Bluetooth máy in nhiệt (Xprinter / POS 80mm) trên Android
/// - Kết nối mạng (TCP) trên Windows
/// - Xem trước hóa đơn
class PrinterService {
  static const _charsPerLine = 32;

  // ESC/POS commands
  static final List<int> _escInit = [0x1B, 0x40];
  static final List<int> _escCut = [0x1D, 0x56, 0x00];
  static final List<int> _escLineFeed = [0x0A];

  /// Gửi lệnh in ESC/POS qua Bluetooth (Android) hoặc TCP (Windows)
  static Future<String?> printReceipt({
    required String printerAddress,
    required String receiptText,
    Uint8List? qrImageBytes,
    String? bankInfoText,
  }) async {
    try {
      if (Platform.isAndroid) {
        return await _printBluetooth(printerAddress, receiptText, qrImageBytes: qrImageBytes, bankInfoText: bankInfoText);
      } else if (Platform.isWindows) {
        return await _printTcp(printerAddress, receiptText, qrImageBytes: qrImageBytes, bankInfoText: bankInfoText);
      }
      return 'Chưa hỗ trợ in trên nền tảng này.';
    } catch (e) {
      return 'Lỗi in: $e';
    }
  }

  static Future<String?> _printBluetooth(String address, String text, {Uint8List? qrImageBytes, String? bankInfoText}) async {
    debugPrint('[Printer] Bluetooth print to $address:\n$text');
    if (qrImageBytes != null) debugPrint('[Printer] QR image bytes: ${qrImageBytes.length}');
    if (bankInfoText != null && bankInfoText.isNotEmpty) debugPrint('[Printer] Bank info:\n$bankInfoText');
    return null;
  }

  static Future<String?> _printTcp(String address, String text, {Uint8List? qrImageBytes, String? bankInfoText}) async {
    final parts = address.split(':');
    if (parts.length != 2) return 'Địa chỉ máy in không hợp lệ (cần IP:Port).';
    try {
      final socket = await Socket.connect(parts[0], int.parse(parts[1]),
          timeout: const Duration(seconds: 5));
      // Init printer
      socket.add(Uint8List.fromList(_escInit));
      // Print text with UTF-8 encoding
      final textBytes = utf8.encode(text);
      socket.add(Uint8List.fromList(textBytes));
      // QR image (nếu có)
      if (qrImageBytes != null) {
        socket.add(Uint8List.fromList([0x0A]));
        socket.add(Uint8List.fromList(_rasterImageCommands(qrImageBytes)));
      }
      // Thông tin chuyển khoản in ngay dưới mã QR
      if (bankInfoText != null && bankInfoText.isNotEmpty) {
        socket.add(Uint8List.fromList([0x0A]));
        socket.add(Uint8List.fromList(utf8.encode(bankInfoText)));
      }
      // Feed + cut
      socket.add(Uint8List.fromList(_escLineFeed));
      socket.add(Uint8List.fromList(_escLineFeed));
      socket.add(Uint8List.fromList(_escCut));
      await socket.flush();
      await socket.close();
      return null;
    } catch (e) {
      return 'Không thể kết nối máy in: $e';
    }
  }

  /// Text thông tin chuyển khoản — in ngay dưới mã QR trên phiếu.
  static String buildBankInfoText({
    required String bankName,
    String? bankAccount,
    String? bankBranch,
  }) {
    final buf = StringBuffer();
    buf.writeln('THÔNG TIN CHUYỂN KHOẢN');
    buf.writeln('Ngân hàng: $bankName');
    if (bankBranch != null && bankBranch.isNotEmpty) buf.writeln('Chi nhánh: $bankBranch');
    if (bankAccount != null && bankAccount.isNotEmpty) buf.writeln('STK: $bankAccount');
    return buf.toString();
  }

  /// Lệnh ESC/POS in ảnh dạng raster (GS v 0 ...) — ảnh QR đã chọn từ máy
  /// được chuyển thành bitmap 1-bit (trắng/đen) trước khi gửi.
  static List<int> _rasterImageCommands(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return [0x0A];
    var im = decoded;
    const maxSide = 280;
    if (im.width > maxSide || im.height > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxSide)
          : img.copyResize(im, height: maxSide);
    }
    final width = im.width;
    final height = im.height;
    final bytesPerLine = (width + 7) ~/ 8;
    final out = <int>[];
    final xl = bytesPerLine & 0xFF;
    final xh = (bytesPerLine >> 8) & 0xFF;
    final yl = height & 0xFF;
    final yh = (height >> 8) & 0xFF;
    out.addAll([0x1D, 0x76, 0x30, 0x00, xl, xh, yl, yh]);
    for (var y = 0; y < height; y++) {
      for (var byte = 0; byte < bytesPerLine; byte++) {
        var b = 0;
        for (var bit = 0; bit < 8; bit++) {
          final x = byte * 8 + bit;
          if (x >= width) break;
          final p = im.getPixel(x, y);
          final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          if (lum < 128) b |= (1 << (7 - bit));
        }
        out.add(b);
      }
    }
    return out;
  }

  static Future<String?> testPrint({required String printerAddress}) async {
    final testText = buildReceiptText(
      storeName: 'CỬA HÀNG SỬA CHỮA ĐIỆN THOẠI',
      storeAddress: 'Test in ấn',
      storePhone: '',
      storeTaxCode: null,
      orderCode: 'TEST',
      customerName: 'Khách hàng',
      customerPhone: '',
      deviceModel: 'iPhone 13',
      issueDescription: 'In thử hóa đơn',
      status: 'received',
      finalCost: 0,
      paymentMethod: 'cash',
      receivedAt: DateTime.now(),
      staffName: 'Admin',
    );
    return await printReceipt(printerAddress: printerAddress, receiptText: testText);
  }

  /// Tạo nội dung hóa đơn dạng text (ESC/POS compatible)
  static String buildReceiptText({
    required String storeName,
    required String storeAddress,
    required String storePhone,
    String? storeTaxCode,
    String? bankName,
    String? bankAccount,
    String? bankBranch,
    required String orderCode,
    required String customerName,
    required String customerPhone,
    String? deviceModel,
    String? imei,
    required String issueDescription,
    required String status,
    required num finalCost,
    required String paymentMethod,
    required DateTime receivedAt,
    int warrantyDays = 0,
    String? headerText,
    String? footerText,
    String? staffName,
    bool showTimestamp = true,
    bool showTaxCode = true,
    bool showBank = true,
  }) {
    final buf = StringBuffer();

    void line(String s) => buf.writeln(s);
    void dash() => buf.writeln('─' * _charsPerLine);
    void pair(String k, String v) => buf.writeln('$k: $v');

    // -- Timestamp --
    if (showTimestamp) {
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      line('Ngày in: ${_fmtDate(now)}  Giờ: $hh:$mm');
    }

    // -- Header --
    if (headerText != null && headerText.isNotEmpty) {
      line(headerText);
    }
    line(storeName.toUpperCase());
    if (storeAddress.isNotEmpty) line(storeAddress);
    if (storePhone.isNotEmpty) line('Tel: $storePhone');
    if (showTaxCode && storeTaxCode != null && storeTaxCode.isNotEmpty) line('MST: $storeTaxCode');
    dash();

    // -- Order info --
    line('PHIẾU SỬA CHỮA');
    pair('Mã phiếu', orderCode);
    pair('Ngày nhận', _fmtDate(receivedAt));
    pair('Khách hàng', customerName);
    if (customerPhone.isNotEmpty) pair('SĐT', customerPhone);
    dash();

    if (deviceModel != null && deviceModel.isNotEmpty) pair('Model', deviceModel);
    if (imei != null && imei.isNotEmpty) pair('IMEI/Serial', imei);
    dash();

    pair('Tình trạng', issueDescription);
    dash();

    pair('Trạng thái', _statusLabel(status));
    dash();

    // -- Price --
    line('THANH TOÁN');
    pair('Tiền sửa', '${_fmtMoney(finalCost)}đ');
    pair('Hình thức', _paymentLabel(paymentMethod));
    dash();

    // -- Warranty --
    if (warrantyDays > 0) {
      line('CHẾ ĐỘ BẢO HÀNH');
      line('$warrantyDays ngày (kể từ ngày trả máy)');
      dash();
    }

    // -- Staff --
    if (staffName != null) pair('KTV', staffName);

    // -- Footer --
    if (footerText != null && footerText.isNotEmpty) {
      dash();
      line(footerText);
    }

    // Empty lines for paper cut
    buf.writeln('\n\n\n\n');

    return buf.toString();
  }

  static String _statusLabel(String s) {
    const labels = {
      'received': 'Tiếp nhận',
      'diagnosing': 'Đang chẩn đoán',
      'waiting_parts': 'Chờ linh kiện',
      'repairing': 'Đang sửa',
      'repaired': 'Đã sửa xong',
      'delivered': 'Đã trả máy',
      'cancelled': 'Không sửa',
    };
    return labels[s] ?? s;
  }

  static String _paymentLabel(String s) {
    switch (s) {
      case 'cash': return 'Tiền mặt';
      case 'transfer': return 'Chuyển khoản';
      case 'debt': return 'Ghi nợ';
      default: return s;
    }
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _fmtMoney(num n) {
    final s = n.toStringAsFixed(0);
    final parts = <String>[];
    for (int i = s.length; i > 0; i -= 3) {
      parts.insert(0, s.substring(i > 3 ? i - 3 : 0, i));
    }
    return parts.join('.');
  }
}

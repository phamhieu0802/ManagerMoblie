import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'printer_config_service.dart';
import 'bluetooth_printer_service.dart';
import 'windows_printer_service.dart';
import 'laser_receipt_builder.dart';
import '../models/store.dart';
import '../models/repair_order.dart';
import 'app_logger.dart';

/// Dịch vụ in ấn hỗ trợ:
/// - Máy in nhiệt: Bluetooth (Android) / TCP IP:Port / USB RAW (Windows)
/// - Máy in laser: PDF A5 qua hệ thống Windows
class PrinterService {
  static const _charsPerLine = 32;

  // ESC/POS commands
  static final List<int> _escInit = [0x1B, 0x40];
  static final List<int> _escCut = [0x1D, 0x56, 0x00];
  static final List<int> _escLineFeed = [0x0A];

  /// In phiếu — tự detect loại máy in từ PrinterConfig đã lưu.
  static Future<String?> printReceipt({
    required String printerAddress,
    required String receiptText,
    Uint8List? qrImageBytes,
    String? bankInfoText,
    PrinterType printerType = PrinterType.thermal,
  }) async {
    try {
      if (printerType == PrinterType.laser) {
        return 'Laser PDF phải dùng printLaserPdf()';
      }
      // Nhiệt: Android → Bluetooth, Windows → TCP hoặc USB RAW
      if (Platform.isAndroid) {
        return await _printBluetooth(printerAddress, receiptText,
            qrImageBytes: qrImageBytes, bankInfoText: bankInfoText);
      } else if (Platform.isWindows) {
        if (printerAddress.contains(':') && int.tryParse(printerAddress.split(':').last) != null) {
          return await _printTcp(printerAddress, receiptText,
              qrImageBytes: qrImageBytes, bankInfoText: bankInfoText);
        } else {
          return await _printUsbRaw(printerAddress, receiptText,
              qrImageBytes: qrImageBytes, bankInfoText: bankInfoText);
        }
      }
      return 'Chưa hỗ trợ in trên nền tảng này.';
    } catch (e) {
      return 'Lỗi in: $e';
    }
  }

  /// In PDF laser — Windows dùng hệ thống in, Android dùng BLE/TCP.
  static Future<String?> printLaserPdf({
    required Store store,
    required RepairOrder order,
    String? staffName,
    String? headerText,
    String? footerText,
    bool showTimestamp = true,
    bool showTaxCode = true,
    bool showBank = true,
  }) async {
    try {
      final pdfBytes = await LaserReceiptBuilder.buildPdf(
        store: store,
        order: order,
        staffName: staffName,
        headerText: headerText,
        footerText: footerText,
        showTimestamp: showTimestamp,
        showTaxCode: showTaxCode,
        showBank: showBank,
      );

      final config = await PrinterConfigService.load();
      if (config == null || config.address.isEmpty) {
        return 'Chưa cấu hình máy in laser.';
      }

      // Windows: dùng hệ thống in
      if (Platform.isWindows) {
        await Printing.layoutPdf(
          onLayout: (format) async => pdfBytes,
          name: 'Phiếu ${order.code}',
          usePrinterSettings: true,
        );
        return null;
      }

      // Android: gửi PDF qua BLE hoặc TCP
      if (Platform.isAndroid) {
        if (config.isTcp) {
          return await _printLaserTcp(config.address, pdfBytes);
        } else {
          return await _printLaserBle(config.address, pdfBytes);
        }
      }

      return 'Chưa hỗ trợ in laser trên nền tảng này.';
    } catch (e) {
      AppLogger.instance.warning('printLaserPdf error: $e', category: 'printer');
      return 'Lỗi in PDF: $e';
    }
  }

  /// In PDF laser qua TCP/IP (Android).
  static Future<String?> _printLaserTcp(String address, List<int> pdfBytes) async {
    final parts = address.split(':');
    if (parts.length != 2) return 'Địa chỉ máy in không hợp lệ (cần IP:Port).';
    try {
      final socket = await Socket.connect(parts[0], int.parse(parts[1]),
          timeout: const Duration(seconds: 10));
      socket.add(pdfBytes);
      await socket.flush();
      await socket.close();
      return null;
    } catch (e) {
      return 'Không thể kết nối máy in laser: $e';
    }
  }

  /// In PDF laser qua BLE (Android).
  static Future<String?> _printLaserBle(String deviceId, List<int> pdfBytes) async {
    final connErr = await BluetoothPrinterService.reconnect(deviceId);
    if (connErr != null) return connErr;

    // Gửi PDF bytes theo chunks (BLE MTU limit)
    const chunkSize = 180;
    for (var i = 0; i < pdfBytes.length; i += chunkSize) {
      final end = (i + chunkSize < pdfBytes.length) ? i + chunkSize : pdfBytes.length;
      final chunk = pdfBytes.sublist(i, end);
      final err = await BluetoothPrinterService.printData(Uint8List.fromList(chunk));
      if (err != null) return err;
    }
    return null;
  }

  /// In qua Bluetooth (Android) — máy in nhiệt.
  static Future<String?> _printBluetooth(String address, String text,
      {Uint8List? qrImageBytes, String? bankInfoText}) async {
    // Kết nối lại nếu chưa kết nối
    final connErr = await BluetoothPrinterService.reconnect(address);
    if (connErr != null) return connErr;

    // Gửi ESC/POS init
    final initErr = await BluetoothPrinterService.printData(Uint8List.fromList(_escInit));
    if (initErr != null) return initErr;

    // Gửi text
    final textBytes = Uint8List.fromList(utf8.encode(text));
    final textErr = await BluetoothPrinterService.printData(textBytes);
    if (textErr != null) return textErr;

    // QR image
    if (qrImageBytes != null) {
      await BluetoothPrinterService.printData(Uint8List.fromList([0x0A]));
      await BluetoothPrinterService.printData(Uint8List.fromList(_rasterImageCommands(qrImageBytes)));
    }

    // Bank info
    if (bankInfoText != null && bankInfoText.isNotEmpty) {
      await BluetoothPrinterService.printData(Uint8List.fromList([0x0A]));
      await BluetoothPrinterService.printData(Uint8List.fromList(utf8.encode(bankInfoText)));
    }

    // Feed + cut
    await BluetoothPrinterService.printData(Uint8List.fromList(_escLineFeed));
    await BluetoothPrinterService.printData(Uint8List.fromList(_escLineFeed));
    await BluetoothPrinterService.printData(Uint8List.fromList(_escCut));

    return null;
  }

  /// In qua TCP/IP (Windows) — máy in nhiệt mạng.
  static Future<String?> _printTcp(String address, String text,
      {Uint8List? qrImageBytes, String? bankInfoText}) async {
    final parts = address.split(':');
    if (parts.length != 2) return 'Địa chỉ máy in không hợp lệ (cần IP:Port).';
    try {
      final socket = await Socket.connect(parts[0], int.parse(parts[1]),
          timeout: const Duration(seconds: 5));
      socket.add(Uint8List.fromList(_escInit));
      final textBytes = utf8.encode(text);
      socket.add(Uint8List.fromList(textBytes));
      if (qrImageBytes != null) {
        socket.add(Uint8List.fromList([0x0A]));
        socket.add(Uint8List.fromList(_rasterImageCommands(qrImageBytes)));
      }
      if (bankInfoText != null && bankInfoText.isNotEmpty) {
        socket.add(Uint8List.fromList([0x0A]));
        socket.add(Uint8List.fromList(utf8.encode(bankInfoText)));
      }
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

  /// In qua USB RAW (Windows) — máy in nhiệt USB chọn từ danh sách.
  static Future<String?> _printUsbRaw(String printerName, String text,
      {Uint8List? qrImageBytes, String? bankInfoText}) async {
    // Build toàn bộ ESC/POS data thành 1 buffer
    final buf = BytesBuilder();
    buf.add(Uint8List.fromList(_escInit));
    buf.add(Uint8List.fromList(utf8.encode(text)));
    if (qrImageBytes != null) {
      buf.add(Uint8List.fromList([0x0A]));
      buf.add(Uint8List.fromList(_rasterImageCommands(qrImageBytes)));
    }
    if (bankInfoText != null && bankInfoText.isNotEmpty) {
      buf.add(Uint8List.fromList([0x0A]));
      buf.add(Uint8List.fromList(utf8.encode(bankInfoText)));
    }
    buf.add(Uint8List.fromList(_escLineFeed));
    buf.add(Uint8List.fromList(_escLineFeed));
    buf.add(Uint8List.fromList(_escCut));

    return await WindowsPrinterService.printRaw(printerName, buf.toBytes());
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

  /// In test — gửi phiếu mẫu theo loại máy in hiện tại.
  static Future<String?> testPrint({required String printerAddress, PrinterType printerType = PrinterType.thermal}) async {
    if (printerType == PrinterType.laser) {
      return 'Vui lòng dùng nút In mẫu PDF để kiểm tra máy in laser.';
    }
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
    return await printReceipt(printerAddress: printerAddress, receiptText: testText, printerType: printerType);
  }

  /// Tạo nội dung hóa đơn dạng text (ESC/POS compatible) — máy in nhiệt.
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

    if (showTimestamp) {
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      line('Ngày in: ${_fmtDate(now)}  Giờ: $hh:$mm');
    }
    if (headerText != null && headerText.isNotEmpty) line(headerText);
    line(storeName.toUpperCase());
    if (storeAddress.isNotEmpty) line(storeAddress);
    if (storePhone.isNotEmpty) line('Tel: $storePhone');
    if (showTaxCode && storeTaxCode != null && storeTaxCode.isNotEmpty) line('MST: $storeTaxCode');
    dash();

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

    line('THANH TOÁN');
    pair('Tiền sửa', '${_fmtMoney(finalCost)}đ');
    pair('Hình thức', _paymentLabel(paymentMethod));
    dash();

    if (warrantyDays > 0) {
      line('CHẾ ĐỘ BẢO HÀNH');
      line('$warrantyDays ngày (kể từ ngày trả máy)');
      dash();
    }

    if (staffName != null) pair('KTV', staffName);

    if (footerText != null && footerText.isNotEmpty) {
      dash();
      line(footerText);
    }

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

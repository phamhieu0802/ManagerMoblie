import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';

/// Dịch vụ máy in Windows: liệt kê máy in, mở cài đặt, in RAW qua PowerShell.
class WindowsPrinterService {
  WindowsPrinterService._();

  /// Liệt kê tất cả máy in đã cài trên Windows qua PowerShell.
  static Future<List<String>> getInstalledPrinters() async {
    if (!Platform.isWindows) return [];
    return compute(_enumPrintersIsolate, null);
  }

  /// Lấy tên máy in mặc định hiện tại.
  static Future<String?> getDefaultPrinter() async {
    if (!Platform.isWindows) return null;
    return compute(_getDefaultPrinterIsolate, null);
  }

  /// Mở Windows Settings > Printers & scanners.
  static Future<void> openPrinterSettings() async {
    try {
      await Process.run('cmd', ['/c', 'start', 'ms-settings:printers']);
    } catch (e) {
      AppLogger.instance.warning('openPrinterSettings error: $e', category: 'printer');
    }
  }

  /// Gửi dữ liệu thô (RAW) tới máy in Windows theo tên.
  static Future<String?> printRaw(String printerName, List<int> data) async {
    if (!Platform.isWindows) return 'Chỉ hỗ trợ in trên Windows.';
    return compute(_printRawIsolate, _PrintRawArgs(printerName, data));
  }

  // ─── Isolate functions ───

  static List<String> _enumPrintersIsolate(_) {
    try {
      final result = Process.runSync('powershell', [
        '-NoProfile', '-Command',
        '(Get-CimInstance -ClassName Win32_Printer).Name'
      ]);
      final output = result.stdout.toString().trim();
      if (output.isEmpty) return [];
      return output.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } catch (e) {
      AppLogger.instance.warning('EnumPrinters PowerShell error: $e', category: 'printer');
      return [];
    }
  }

  static String? _getDefaultPrinterIsolate(_) {
    try {
      final result = Process.runSync('powershell', [
        '-NoProfile', '-Command',
        '(Get-CimInstance -ClassName Win32_Printer | Where-Object {$_.Default}).Name'
      ]);
      final output = result.stdout.toString().trim();
      return output.isEmpty ? null : output;
    } catch (_) {
      return null;
    }
  }

  static String? _printRawIsolate(_PrintRawArgs args) {
    try {
      // Tạo file temp rồi in qua SumatraPDF hoặc PowerShell
      // Cách đơn giản nhất: dùng `Out-Printer` hoặc `sc print`
      final tempDir = Directory.systemTemp.createTempSync('msr_print_');
      final tempFile = File('${tempDir.path}\\print_job.raw');
      tempFile.writeAsBytesSync(args.data);

      // PowerShell: in file raw qua printer
      final result = Process.runSync('powershell', [
        '-NoProfile', '-Command',
        r'''
$printer = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Name -like ''' + args.printerName + r''' }
if ($printer) {
    $printer.Print()
} else {
    Write-Error "Printer not found"
}
''',
      ]);

      try { tempFile.deleteSync(); } catch (_) {}
      try { tempDir.deleteSync(); } catch (_) {}

      if (result.exitCode != 0) {
        final err = result.stderr.toString().trim();
        if (err.isNotEmpty) return 'Lỗi in: $err';
      }
      return null;
    } catch (e) {
      return 'Lỗi in USB: $e';
    }
  }
}

class _PrintRawArgs {
  final String printerName;
  final List<int> data;
  _PrintRawArgs(this.printerName, this.data);
}

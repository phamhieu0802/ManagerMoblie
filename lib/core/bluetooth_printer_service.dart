import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app_logger.dart';

/// Dịch vụ BLE (Bluetooth Low Energy) cho máy in nhiệt.
/// Hầu hết máy in POS nhiệt hiện nay hỗ trợ BLE.
class BluetoothPrinterService {
  BluetoothPrinterService._();

  static BluetoothDevice? _connectedDevice;
  static BluetoothCharacteristic? _txCharacteristic;
  static bool _isConnecting = false;

  /// UUID của ESC/POS BLE service và characteristics (phổ biến nhất)
  static final _escPosServiceUuid = Guid('000018f0-0000-1000-8000-00805f9b34fb');
  static final _txCharUuid = Guid('00002af1-0000-1000-8000-00805f9b34fb');

  /// UUID phụ (một số máy in dùng service khác)
  static final _altServiceUuid = Guid('0000fee7-0000-1000-8000-00805f9b34fb');
  static final _altTxCharUuid = Guid('0000fec8-0000-1000-8000-00805f9b34fb');

  /// UUID Service UUIDs phổ biến cho máy in BLE
  static final _genericServiceUuid = Guid('0000ffe0-0000-1000-8000-00805f9b34fb');
  static final _genericTxCharUuid = Guid('0000ffe1-0000-1000-8000-00805f9b34fb');

  /// Kiểm tra + xin cấp quyền Bluetooth + Vị trí (Android 12+ cần BT scan/connect).
  static Future<bool> requestPermission() async {
    if (Platform.isWindows) return true; // Windows không cần permission_handler cho BLE

    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final location = await Permission.locationWhenInUse.request();
    final granted = scan.isGranted && connect.isGranted && location.isGranted;
    if (!granted) {
      AppLogger.instance.warning(
        'Bluetooth permission denied: scan=$scan, connect=$connect, location=$location',
        category: 'bluetooth',
      );
    }
    return granted;
  }

  /// Bật Bluetooth adapter nếu cần.
  static Future<bool> enableBluetooth() async {
    try {
      if (await FlutterBluePlus.isSupported == false) return false;
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState == BluetoothAdapterState.on) return true;

      await FlutterBluePlus.turnOn();
      await Future.delayed(const Duration(seconds: 1));
      final newState = await FlutterBluePlus.adapterState.first;
      return newState == BluetoothAdapterState.on;
    } catch (e) {
      AppLogger.instance.warning('enableBluetooth error: $e', category: 'bluetooth');
      return false;
    }
  }

  /// Quét thiết bị BLE nearby trong `duration` giây.
  static Future<List<ScanResult>> scanDevices({Duration duration = const Duration(seconds: 6)}) async {
    try {
      // Start scan and wait for results
      final completer = Completer<List<ScanResult>>();
      final List<ScanResult> allResults = [];
      final sub = FlutterBluePlus.onScanResults.listen((results) {
        allResults.clear();
        allResults.addAll(results);
      });

      await FlutterBluePlus.startScan(timeout: duration);

      // Đợi thêm 1s để lấy kết quả cuối
      await Future.delayed(const Duration(seconds: 1));
      await sub.cancel();

      return allResults.where((r) => r.advertisementData.advName.isNotEmpty).toList();
    } catch (e) {
      AppLogger.instance.warning('scanDevices error: $e', category: 'bluetooth');
      return [];
    }
  }

  /// Lấy danh sách thiết bị đã kết nối.
  static Future<List<BluetoothDevice>> getConnectedDevices() async {
    try {
      return FlutterBluePlus.connectedDevices;
    } catch (e) {
      return [];
    }
  }

  /// Kết nối tới máy in BLE theo device và tìm TX characteristic để ghi dữ liệu ESC/POS.
  /// Trả null nếu thành công, thông báo lỗi nếu thất bại.
  static Future<String?> connectAndValidate(BluetoothDevice device) async {
    if (_isConnecting) return 'Đang kết nối, vui lòng đợi...';
    _isConnecting = true;
    try {
      await disconnect();

      AppLogger.instance.info('Đang kết nối BLE: ${device.advName} (${device.remoteId})', category: 'bluetooth');
      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevice = device;

      // Đợi services được discover
      List<BluetoothService> services;
      try {
        services = await device.discoverServices(timeout: 8);
      } catch (_) {
        services = await device.discoverServices();
      }

      // Tìm ESC/POS TX characteristic (thử nhiều UUID phổ biến)
      _txCharacteristic = _findTxCharacteristic(services);
      if (_txCharacteristic == null) {
        await disconnect();
        return 'Không tìm thấy đặc tính in (TX) trên máy in này.\nMáy in có thể không hỗ trợ ESC/POS BLE.';
      }

      // Gửi ESC/POS init để verify
      final initCmd = Uint8List.fromList([0x1B, 0x40]); // ESC @
      await _txCharacteristic!.write(initCmd, withoutResponse: true);

      AppLogger.instance.info('Kết nối BLE thành công: ${device.advName}', category: 'bluetooth');
      return null; // OK
    } catch (e) {
      AppLogger.instance.warning('connectAndValidate BLE error: $e', category: 'bluetooth');
      await disconnect();
      return 'Lỗi kết nối BLE: $e';
    } finally {
      _isConnecting = false;
    }
  }

  /// Tìm TX characteristic trong các service phổ biến của máy in ESC/POS.
  static BluetoothCharacteristic? _findTxCharacteristic(List<BluetoothService> services) {
    for (final service in services) {
      // Match ESC/POS service UUID
      if (service.uuid == _escPosServiceUuid || service.uuid == _altServiceUuid ||
          service.uuid == _genericServiceUuid) {
        for (final char in service.characteristics) {
          if (char.uuid == _txCharUuid || char.uuid == _altTxCharUuid ||
              char.uuid == _genericTxCharUuid) {
            return char;
          }
        }
      }
    }
    // Fallback: tìm bất kỳ characteristic nào hỗ trợ write
    for (final service in services) {
      for (final char in service.characteristics) {
        if (char.properties.write || char.properties.writeWithoutResponse) {
          return char;
        }
      }
    }
    return null;
  }

  /// Gửi dữ liệu in qua BLE.
  static Future<String?> printData(Uint8List data) async {
    if (_txCharacteristic == null || _connectedDevice == null) {
      return 'Chưa kết nối máy in BLE.';
    }
    try {
      // Gửi data theo chunks (BLE MTU thường ~20-512 bytes)
      const chunkSize = 180;
      for (var i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);
        await _txCharacteristic!.write(chunk, withoutResponse: true);
      }
      return null;
    } catch (e) {
      return 'Lỗi gửi dữ liệu in BLE: $e';
    }
  }

  /// Đóng kết nối BLE.
  static Future<void> disconnect() async {
    try {
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
    } catch (_) {}
    _txCharacteristic = null;
    _connectedDevice = null;
  }

  /// Đang kết nối không?
  static bool get isConnected => _connectedDevice?.isConnected ?? false;

  /// Kết nối lại theo device ID (remoteId string). Dùng khi in từ printer_service.
  static Future<String?> reconnect(String deviceId) async {
    if (isConnected) return null;

    // Thử tìm trong danh sách đã kết nối
    final connected = await getConnectedDevices();
    for (final dev in connected) {
      if (dev.remoteId.str == deviceId) {
        return await connectAndValidate(dev);
      }
    }

    // Không tìm thấy → scan nhanh rồi connect
    final results = await scanDevices(duration: const Duration(seconds: 4));
    for (final r in results) {
      if (r.device.remoteId.str == deviceId) {
        return await connectAndValidate(r.device);
      }
    }

    return 'Không tìm thấy máy in BLE ($deviceId). Hãy bật máy in và thử lại.';
  }

  /// Lấy remoteId string từ device (dùng làm address lưu config).
  static String getDeviceId(BluetoothDevice device) => device.remoteId.str;
}

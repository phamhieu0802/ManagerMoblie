import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loại máy in: 'thermal' (nhiệt/Bluetooth/USB) hoặc 'laser' (A5).
enum PrinterType { thermal, laser }

/// Cấu hình máy in lưu cục bộ trên thiết bị (SharedPreferences),
/// KHÔNG lưu vào Supabase — mỗi thiết bị tự cấu hình riêng.
class PrinterConfig {
  final PrinterType type;
  final String address;
  final String? name;

  const PrinterConfig({required this.type, required this.address, this.name});

  bool get isThermal => type == PrinterType.thermal;
  bool get isLaser => type == PrinterType.laser;

  /// Địa chỉ có phải dạng IP:Port (TCP) không.
  bool get isTcp => address.contains(':') && int.tryParse(address.split(':').last) != null;

  PrinterConfig copyWith({PrinterType? type, String? address, String? name}) =>
      PrinterConfig(type: type ?? this.type, address: address ?? this.address, name: name ?? this.name);

  Map<String, dynamic> toMap() => {'type': type.name, 'address': address, if (name != null) 'name': name};

  factory PrinterConfig.fromMap(Map<String, dynamic> m) => PrinterConfig(
        type: m['type'] == 'laser' ? PrinterType.laser : PrinterType.thermal,
        address: m['address'] as String? ?? '',
        name: m['name'] as String?,
      );
}

class PrinterConfigService {
  PrinterConfigService._();

  static const _keyType = 'printer_config_type';
  static const _keyAddress = 'printer_config_address';
  static const _keyName = 'printer_config_name';

  /// Lưu cấu hình máy in.
  static Future<void> save(PrinterConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyType, config.type.name);
    await prefs.setString(_keyAddress, config.address);
    if (config.name != null) {
      await prefs.setString(_keyName, config.name!);
    } else {
      await prefs.remove(_keyName);
    }
  }

  /// Đọc cấu hình máy in đã lưu. Trả null nếu chưa cấu hình.
  static Future<PrinterConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final typeStr = prefs.getString(_keyType);
    final address = prefs.getString(_keyAddress);
    if (typeStr == null || address == null || address.isEmpty) return null;
    return PrinterConfig(
      type: typeStr == 'laser' ? PrinterType.laser : PrinterType.thermal,
      address: address,
      name: prefs.getString(_keyName),
    );
  }

  /// Xóa cấu hình máy in.
  static Future<void> delete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyType);
    await prefs.remove(_keyAddress);
    await prefs.remove(_keyName);
  }

  /// Có cấu hình máy in chưa?
  static Future<bool> isConfigured() async {
    final config = await load();
    return config != null && config.address.isNotEmpty;
  }
}

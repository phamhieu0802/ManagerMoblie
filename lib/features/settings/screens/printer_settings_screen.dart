import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../../core/app_toast.dart';
import '../../../core/printer_config_service.dart';
import '../../../core/bluetooth_printer_service.dart';
import '../../../core/windows_printer_service.dart';
import '../../../core/printer_service.dart';
import '../../../models/store.dart';
import '../controllers/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Màn hình cài đặt máy in mới: chọn loại (Nhiệt/Laser), tự kết nối, lưu cấu hình cục bộ.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  final Store store;
  const PrinterSettingsScreen({super.key, required this.store});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  PrinterConfig? _config;
  bool _loading = true;
  bool _scanning = false;
  List<ScanResult> _btDevices = [];
  PrinterType _selectedType = PrinterType.thermal;

  // Print content settings (shared)
  late final TextEditingController _headerCtrl;
  late final TextEditingController _footerCtrl;
  late bool _showTimestamp;
  late bool _showTaxCode;
  late bool _showBank;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _headerCtrl = TextEditingController(text: widget.store.printHeader ?? '');
    _footerCtrl = TextEditingController(text: widget.store.printFooter ?? '');
    _showTimestamp = widget.store.printShowTimestamp;
    _showTaxCode = widget.store.printShowTaxCode;
    _showBank = widget.store.printShowBank;
    _loadConfig();
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await PrinterConfigService.load();
    if (mounted) setState(() {
      _config = config;
      _selectedType = config?.type ?? PrinterType.thermal;
      _loading = false;
    });
  }

  Future<void> _saveConfig(PrinterConfig config) async {
    await PrinterConfigService.save(config);
    if (mounted) setState(() => _config = config);
    if (mounted) showToast(context, 'Đã lưu cấu hình máy in.');
  }

  Future<void> _deleteConfig() async {
    await PrinterConfigService.delete();
    if (mounted) setState(() => _config = null);
    if (mounted) showToast(context, 'Đã xóa cấu hình máy in.');
  }

  // ─── Android: BLE scan ───

  Future<void> _startBtScan() async {
    final hasPermission = await BluetoothPrinterService.requestPermission();
    if (!hasPermission) {
      if (mounted) showToast(context, 'Cần cấp quyền Bluetooth và Vị trí.', error: true);
      return;
    }
    final enabled = await BluetoothPrinterService.enableBluetooth();
    if (!enabled) {
      if (mounted) showToast(context, 'Vui lòng bật Bluetooth.', error: true);
      return;
    }

    if (mounted) setState(() => _scanning = true);

    // Quét 6 giây
    final results = await BluetoothPrinterService.scanDevices(duration: const Duration(seconds: 6));
    if (mounted) {
      setState(() { _btDevices = results; _scanning = false; });
    }

    if (!mounted) return;
    final picked = await _showBluetoothPickerDialog(results);
    if (picked != null) {
      await _connectBtPrinter(picked);
    }
  }

  Future<BluetoothDevice?> _showBluetoothPickerDialog(List<ScanResult> results) async {
    return showDialog<BluetoothDevice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chọn máy in BLE'),
        content: SizedBox(
          width: 360,
          height: 400,
          child: results.isEmpty
              ? const Center(child: Text(
                  'Không tìm thấy thiết bị nào.\n\n'
                  'Hãy bật máy in và đảm bảo:\n'
                  '• Máy in hỗ trợ BLE\n'
                  '• Đã bật Bluetooth\n'
                  '• Máy in ở gần điện thoại',
                  textAlign: TextAlign.center,
                ))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (ctx, i) {
                    final r = results[i];
                    final name = r.advertisementData.advName;
                    final id = r.device.remoteId.str;
                    final rssi = r.rssi;
                    return ListTile(
                      leading: const Icon(Icons.bluetooth, color: Colors.blue),
                      title: Text(name.isNotEmpty ? name : 'Máy in không tên', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$id · ${rssi}dBm', style: const TextStyle(fontSize: 12)),
                      onTap: () => Navigator.pop(ctx, r.device),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
        ],
      ),
    );
  }

  Future<void> _connectBtPrinter(BluetoothDevice device) async {
    final deviceId = device.remoteId.str;
    final deviceName = device.advName.isNotEmpty ? device.advName : deviceId;
    showToast(context, 'Đang kết nối $deviceName...');
    final err = await BluetoothPrinterService.connectAndValidate(device);
    if (!mounted) return;
    if (err != null) {
      showToast(context, 'Lỗi: $err', error: true);
    } else {
      await _saveConfig(PrinterConfig(
        type: _selectedType,
        address: deviceId,
        name: deviceName,
      ));
    }
  }

  // ─── Windows: printer picker ───

  Future<void> _pickWindowsPrinter() async {
    if (Platform.isWindows) {
      await WindowsPrinterService.openPrinterSettings();
      if (mounted) showToast(context, 'Chọn máy in trong Windows, sau đó quay lại bấm "Làm mới".');
    }
  }

  Future<void> _refreshWindowsPrinters() async {
    final printers = await WindowsPrinterService.getInstalledPrinters();
    if (!mounted) return;
    final picked = await _showWindowsPrinterDialog(printers);
    if (picked != null) {
      await _saveConfig(PrinterConfig(
        type: _selectedType,
        address: picked,
        name: picked,
      ));
    }
  }

  Future<String?> _showWindowsPrinterDialog(List<String> printers) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chọn máy in'),
        content: SizedBox(
          width: 380,
          height: 350,
          child: printers.isEmpty
              ? const Center(child: Text('Không tìm thấy máy in nào.\nHãy cài đặt máy in trong Windows trước.'))
              : ListView.builder(
                  itemCount: printers.length,
                  itemBuilder: (ctx, i) => ListTile(
                    leading: const Icon(Icons.print, color: Colors.blue),
                    title: Text(printers[i]),
                    onTap: () => Navigator.pop(ctx, printers[i]),
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
        ],
      ),
    );
  }

  // ─── Windows TCP input ───

  Future<void> _pickTcpPrinter() async {
    final ctrl = TextEditingController(text: _config?.address ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Máy in TCP/IP'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'IP:Port',
            hintText: '192.168.1.100:9100',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Lưu')),
        ],
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      await _saveConfig(PrinterConfig(type: _selectedType, address: picked, name: picked));
    }
  }

  // ─── Preview ───

  void _showPreview() {
    final s = widget.store;
    final preview = PrinterService.buildReceiptText(
      storeName: s.name, storeAddress: s.address ?? '', storePhone: s.phone ?? '',
      storeTaxCode: s.taxCode, bankName: s.bankName, bankAccount: s.bankAccount, bankBranch: s.bankBranch,
      orderCode: 'HD-0001', customerName: 'Nguyễn Văn A', customerPhone: '0901234567',
      deviceModel: 'iPhone 13', imei: '123456789012345', issueDescription: 'Thay màn hình cảm ứng',
      status: 'delivered', finalCost: 450000, paymentMethod: 'cash', receivedAt: DateTime.now(),
      warrantyDays: 90, headerText: _headerCtrl.text.trim().isEmpty ? null : _headerCtrl.text.trim(),
      footerText: _footerCtrl.text.trim().isEmpty ? null : _footerCtrl.text.trim(),
      staffName: 'Admin', showTimestamp: _showTimestamp, showTaxCode: _showTaxCode, showBank: _showBank,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xem trước mẫu in (Nhiệt)'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: SelectableText(preview, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
      ),
    );
  }

  // ─── Test print ───

  Future<void> _testPrint() async {
    if (_config == null) {
      showToast(context, 'Chưa cấu hình máy in.', error: true);
      return;
    }
    setState(() => _testResult = 'Đang in...');
    final err = await PrinterService.testPrint(printerAddress: _config!.address, printerType: _config!.type);
    setState(() => _testResult = err ?? 'In thành công!');
  }

  // ─── Save print content settings ───

  Future<void> _savePrintContent() async {
    await SettingsController.updateStore(
      storeId: widget.store.id,
      printHeader: _headerCtrl.text.trim().isEmpty ? null : _headerCtrl.text.trim(),
      printFooter: _footerCtrl.text.trim().isEmpty ? null : _footerCtrl.text.trim(),
      printShowTimestamp: _showTimestamp,
      printShowTaxCode: _showTaxCode,
      printShowBank: _showBank,
    );
    ref.invalidate(storeDetailProvider(widget.store.id));
    if (mounted) showToast(context, 'Đã lưu nội dung in.');
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final isConfigured = _config != null && _config!.address.isNotEmpty;
    final isThermal = _config?.type == PrinterType.thermal;

    return Scaffold(
      appBar: AppBar(title: const Text('Cấu hình máy in')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Loại máy in ──
            const Text('Loại máy in:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<PrinterType>(
              segments: const [
                ButtonSegment(value: PrinterType.thermal, label: Text('Nhiệt'), icon: Icon(Icons.print)),
                ButtonSegment(value: PrinterType.laser, label: Text('Laser'), icon: Icon(Icons.print)),
              ],
              selected: {_selectedType},
              onSelectionChanged: isConfigured ? null : (sel) {
                if (sel.isNotEmpty) setState(() => _selectedType = sel.first);
              },
            ),

            const SizedBox(height: 16),

            // ── Cấu hình kết nối ──
            if (!isConfigured) ...[
              // Android: cả nhiệt và laser đều quét BLE + nhập IP
              if (Platform.isAndroid) ...[
                const Text('Android - Bluetooth (BLE):', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _scanning
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(_scanning ? 'Đang quét...' : 'Quét máy in Bluetooth'),
                    onPressed: _scanning ? null : _startBtScan,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Bật máy in → Bấm Quét → Chọn máy in trong danh sách.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 16),
                const Text('WiFi / WiFi Direct:', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.wifi),
                    label: const Text('Nhập IP:Port'),
                    onPressed: _pickTcpPrinter,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedType == PrinterType.laser
                      ? 'Nhập IP và Port của máy in laser trên mạng WiFi.'
                      : 'Nhập IP và Port của máy in nhiệt trên mạng WiFi.',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
              // Windows
              if (Platform.isWindows) ...[
                if (_selectedType == PrinterType.thermal) ...[
                  const Text('Windows:', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.usb),
                          label: const Text('Chọn máy in USB'),
                          onPressed: _refreshWindowsPrinters,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.wifi),
                          label: const Text('Nhập IP:Port'),
                          onPressed: _pickTcpPrinter,
                        ),
                      ),
                    ],
                  ),
                ],
                if (_selectedType == PrinterType.laser) ...[
                  const Text('Windows - Máy in laser:', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.settings),
                      label: const Text('Mở cài đặt máy in Windows'),
                      onPressed: _pickWindowsPrinter,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Mở Settings > Printers, chọn máy in laser mặc định. Sau đó quay lại bấm "Làm mới".', style: TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Làm mới & Chọn máy in'),
                      onPressed: _refreshWindowsPrinters,
                    ),
                  ),
                ],
              ],
            ],

            // ── Đã cấu hình ──
            if (isConfigured) ...[
              Card(
                child: ListTile(
                  leading: Icon(isThermal ? Icons.print : Icons.print, color: Colors.green),
                  title: Text(_config!.name ?? _config!.address),
                  subtitle: Text('${isThermal ? "Máy in nhiệt" : "Máy in laser"} · ${_config!.address}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: 'Xóa cấu hình',
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Xóa cấu hình máy in?'),
                          content: const Text('Bạn sẽ cần cấu hình lại máy in.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa')),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await _deleteConfig();
                        if (isThermal) await BluetoothPrinterService.disconnect();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Kiểm tra in'),
                  onPressed: _testPrint,
                ),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Icon(_testResult!.contains('thành công') ? Icons.check_circle : Icons.error,
                          color: _testResult!.contains('thành công') ? Colors.green : Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_testResult!, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
                ),
              ],
            ],

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),

            // ── Cài đặt nội dung in (chung) ──
            const Text('Nội dung phiếu in:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _headerCtrl,
              decoration: const InputDecoration(
                labelText: 'Lời chào (đầu phiếu)',
                helperText: 'VD: Cảm ơn quý khách đã tin tưởng!',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _footerCtrl,
              decoration: const InputDecoration(
                labelText: 'Lời nhắc (cuối phiếu)',
                helperText: 'VD: Bảo hành 90 ngày. Vui lòng giữ lại phiếu!',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            const Text('Hiển thị trên phiếu:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Ngày & giờ in'),
              value: _showTimestamp,
              onChanged: (v) => setState(() => _showTimestamp = v ?? true),
            ),
            CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Mã số thuế (MST)'),
              value: _showTaxCode,
              onChanged: (v) => setState(() => _showTaxCode = v ?? true),
            ),
            CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Tài khoản ngân hàng (STK)'),
              value: _showBank,
              onChanged: (v) => setState(() => _showBank = v ?? true),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Xem mẫu'),
                    onPressed: _showPreview,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Lưu nội dung'),
                    onPressed: _savePrintContent,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

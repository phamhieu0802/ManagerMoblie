import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/store.dart';
import '../models/repair_order.dart';

/// Tạo phiếu sửa chữa dạng PDF A5 (148 × 210 mm) cho máy in laser.
class LaserReceiptBuilder {
  static final _fontRegular = pw.Font.helvetica();
  static final _fontBold = pw.Font.helveticaBold();

  /// Kích thước A5: 148mm x 210mm
  static final _a5 = const PdfPageFormat(148 * PdfPageFormat.mm, 210 * PdfPageFormat.mm,
      marginTop: 10 * PdfPageFormat.mm, marginBottom: 10 * PdfPageFormat.mm,
      marginLeft: 12 * PdfPageFormat.mm, marginRight: 12 * PdfPageFormat.mm);

  static Future<Uint8List> buildPdf({
    required Store store,
    required RepairOrder order,
    String? staffName,
    String? headerText,
    String? footerText,
    bool showTimestamp = true,
    bool showTaxCode = true,
    bool showBank = true,
  }) async {
    final pdf = pw.Document();
    pdf.addPage(pw.Page(
      pageFormat: _a5,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // ── Timestamp ──
          if (showTimestamp) ...[
            _text('Ngày in: ${_fmtDate(DateTime.now())}  Giờ: ${_fmtTime(DateTime.now())}',
                font: _fontRegular, color: PdfColors.grey600),
            pw.SizedBox(height: 4),
          ],

          // ── Header ──
          if (headerText != null && headerText.isNotEmpty) ...[
            _text(headerText, font: _fontRegular, color: PdfColors.grey700),
            pw.SizedBox(height: 2),
          ],

          // ── Store info ──
          pw.Center(child: _text(store.name.toUpperCase(), font: _fontBold)),
          if (store.address != null && store.address!.isNotEmpty)
            pw.Center(child: _text(store.address!, font: _fontRegular)),
          if (store.phone != null && store.phone!.isNotEmpty)
            pw.Center(child: _text('Tel: ${store.phone}', font: _fontRegular)),
          if (showTaxCode && store.taxCode != null && store.taxCode!.isNotEmpty)
            pw.Center(child: _text('MST: ${store.taxCode}', font: _fontRegular)),
          pw.SizedBox(height: 4),
          _divider(),
          pw.SizedBox(height: 6),

          // ── Title ──
          pw.Center(child: _text('PHIẾU SỬA CHỮA', font: _fontBold)),
          pw.SizedBox(height: 8),

          // ── Order info ──
          _row('Mã phiếu:', order.code),
          _row('Ngày nhận:', _fmtDate(order.receivedAt)),
          if (order.customerId != null && order.customerId!.isNotEmpty)
            _row('Mã KH:', order.customerId!),
          pw.SizedBox(height: 6),
          _divider(),
          pw.SizedBox(height: 6),

          // ── Device ──
          if (order.deviceModel != null && order.deviceModel!.isNotEmpty)
            _row('Model:', order.deviceModel!),
          if (order.imei != null && order.imei!.isNotEmpty)
            _row('IMEI/Serial:', order.imei!),
          if (order.deviceModel != null || order.imei != null) ...[
            pw.SizedBox(height: 4),
            _divider(),
            pw.SizedBox(height: 6),
          ],

          // ── Issue ──
          _row('Tình trạng:', order.issueDescription ?? ''),
          pw.SizedBox(height: 4),
          _divider(),
          pw.SizedBox(height: 6),

          // ── Status ──
          _row('Trạng thái:', _statusLabel(order.status)),
          pw.SizedBox(height: 4),
          _divider(),
          pw.SizedBox(height: 6),

          // ── Payment ──
          _text('THANH TOÁN', font: _fontBold),
          pw.SizedBox(height: 4),
          _row('Tiền sửa:', '${_fmtMoney(order.finalCost > 0 ? order.finalCost : order.estimatedCost)}đ'),
          _row('Hình thức:', _paymentLabel(order.paymentMethod ?? 'cash')),
          pw.SizedBox(height: 4),
          _divider(),
          pw.SizedBox(height: 6),

          // ── Warranty ──
          if (order.warrantyDays > 0) ...[
            _text('CHẾ ĐỘ BẢO HÀNH', font: _fontBold),
            pw.SizedBox(height: 4),
            _text('${order.warrantyDays} ngày (kể từ ngày trả máy)', font: _fontRegular),
            pw.SizedBox(height: 4),
            _divider(),
            pw.SizedBox(height: 6),
          ],

          // ── Staff ──
          if (staffName != null && staffName.isNotEmpty)
            _row('KTV:', staffName),

          // ── Bank info ──
          if (showBank && store.bankName != null && store.bankName!.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            _divider(),
            pw.SizedBox(height: 6),
            _text('THÔNG TIN CHUYỂN KHOẢN', font: _fontBold),
            pw.SizedBox(height: 4),
            _row('Ngân hàng:', store.bankName!),
            if (store.bankBranch != null && store.bankBranch!.isNotEmpty)
              _row('Chi nhánh:', store.bankBranch!),
            if (store.bankAccount != null && store.bankAccount!.isNotEmpty)
              _row('STK:', store.bankAccount!),
          ],

          // ── Footer ──
          if (footerText != null && footerText.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            _divider(),
            pw.SizedBox(height: 4),
            pw.Center(child: _text(footerText, font: _fontRegular, color: PdfColors.grey600)),
          ],

          pw.Spacer(),
          pw.SizedBox(height: 20),
        ],
      ),
    ));
    return pdf.save();
  }

  // ─── Helpers ───

  static pw.Widget _text(String text, {required pw.Font font, PdfColor? color}) {
    return pw.Text(text, style: pw.TextStyle(font: font, fontSize: 10, color: color));
  }

  static pw.Widget _row(String label, String value) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 35 * PdfPageFormat.mm,
          child: _text(label, font: _fontBold),
        ),
        pw.Expanded(child: _text(value, font: _fontRegular)),
      ],
    );
  }

  static pw.Widget _divider() {
    return pw.Divider(height: 1, color: PdfColors.grey400);
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

  static String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _fmtMoney(num n) {
    final s = n.toStringAsFixed(0);
    final parts = <String>[];
    for (int i = s.length; i > 0; i -= 3) {
      parts.insert(0, s.substring(i > 3 ? i - 3 : 0, i));
    }
    return parts.join('.');
  }
}

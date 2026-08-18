/// Chuyển exception thô thành thông điệp tiếng Việt thân thiện cho người dùng.
/// Chi tiết kỹ thuật vẫn được ghi qua [AppLogger] — hàm này chỉ trả về
/// message hiển thị trên toast / dialog.
String friendlyError(Object e) {
  final raw = e.toString();

  // ── PostgREST / Supabase SQL errors ──
  // PostgrestException(message: ..., code: XXXXX, details: ...)
  final codeMatch = RegExp(r'code:\s*(\w{5})').firstMatch(raw);
  final msgMatch = RegExp(r'message:\s*(.+?)(?:,\s*code:|$)').firstMatch(raw);
  final detailMatch = RegExp(r'details:\s*(.+?)(?:,\s*hint:|$)').firstMatch(raw);
  final code = codeMatch?.group(1);
  final pgMsg = msgMatch?.group(1)?.trim() ?? '';
  final detail = detailMatch?.group(1)?.trim() ?? '';

  if (code != null) {
    switch (code) {
      case '23505':
        // duplicate key
        final col = RegExp(r'Key \(([^)]+)\)').firstMatch(detail);
        final colDesc = col != null ? _describeColumn(col.group(1)!) : '';
        return 'Dữ liệu đã tồn tại${colDesc.isNotEmpty ? ' ($colDesc)' : ''}. Vui lòng kiểm tra lại.';
      case '23503':
        final col = RegExp(r'Key \(([^)]+)\)').firstMatch(detail);
        final colDesc = col != null ? _describeColumn(col.group(1)!) : '';
        return 'Không thể xóa/sửa vì dữ liệu đang được sử dụng ở nơi khác${colDesc.isNotEmpty ? ' ($colDesc)' : ''}.';
      case '22P02':
        // invalid input syntax
        final typeMatch = RegExp(r'invalid input (?:value|syntax) for (?:type )?(\w+):\s*"?([^",]+)').firstMatch(raw);
        if (typeMatch != null) {
          final type = _describeType(typeMatch.group(1)!);
          final val = typeMatch.group(2)!;
          return 'Dữ liệu không hợp lệ: "$val" không phải $type.';
        }
        return 'Dữ liệu không đúng định dạng. Vui lòng kiểm tra lại.';
      case '42501':
        return 'Bạn không có quyền thực hiện thao tác này.';
      case '42P01':
        return 'Bảng dữ liệu không tồn tại trên hệ thống.';
      case 'PGRST116':
        return 'Không tìm thấy dữ liệu.';
      case 'PGRST204':
        return 'Dữ liệu trả về không đúng định dạng.';
    }
  }

  // ── HTTP / network ──
  if (raw.contains('SocketException') || raw.contains('Connection refused') || raw.contains('Failed host lookup')) {
    return 'Không thể kết nối máy chủ. Kiểm tra mạng và thử lại.';
  }
  if (raw.contains('TimeoutException') || raw.contains('timed out')) {
    return 'Hết thời gian chờ. Vui lòng thử lại.';
  }
  if (raw.contains('HttpRequestException') || raw.contains('HandshakeException')) {
    return 'Lỗi kết nối an toàn. Vui lòng thử lại.';
  }

  // ── Storage ──
  if (raw.contains('storage') && raw.contains('not found')) {
    return 'Không tìm thấy kho lưu trữ.';
  }
  if (raw.contains('file size') || raw.contains('too large')) {
    return 'File quá lớn.';
  }

  // ── Auth ──
  if (raw.contains('Invalid login credentials') || raw.contains('invalid_credentials')) {
    return 'Email hoặc mật khẩu không đúng.';
  }
  if (raw.contains('Email not confirmed')) {
    return 'Email chưa được xác nhận.';
  }
  if (raw.contains('User already registered')) {
    return 'Email này đã được đăng ký.';
  }
  if (raw.contains('Password should be at least')) {
    return 'Mật khẩu phải có ít nhất 6 ký tự.';
  }

  // ── Backup-specific ──
  if (raw.contains('File này không phải file backup')) return raw;
  if (raw.contains('File backup thuộc cửa hàng')) return raw;
  if (raw.contains('File backup bị hỏng')) return raw;
  if (raw.contains('File backup thiếu dữ liệu')) return raw;
  if (raw.contains('Đã hủy')) return raw;
  if (raw.contains('forbidden:')) {
    final msg = raw.replaceAll(RegExp(r'.*forbidden:\s*'), '');
    return msg.isNotEmpty ? msg : 'Bạn không có quyền thực hiện thao tác này.';
  }
  if (raw.contains('Lỗi khi sao lưu bảng')) {
    final tblMatch = RegExp(r'"(\w+)"').firstMatch(raw);
    final tbl = tblMatch != null ? _describeTable(tblMatch.group(1)!) : '';
    return 'Lỗi khi sao lưu${tbl.isNotEmpty ? ' bảng $tbl' : ''}. Xem chi tiết trong Nhật ký.';
  }
  if (raw.contains('Lỗi upload lên Storage')) {
    return 'Lỗi tải file lên đám mây. Xem chi tiết trong Nhật ký.';
  }

  // ── Fallback: strip PostgrestException wrapper ──
  final stripped = raw
      .replaceAll(RegExp(r'PostgrestException\(message:\s*'), '')
      .replaceAll(RegExp(r',\s*code:\s*\w+'), '')
      .replaceAll(RegExp(r',\s*details:\s*[^)]+'), '')
      .replaceAll(RegExp(r',\s*hint:\s*[^)]+'), '')
      .replaceAll(RegExp(r'\)$'), '')
      .trim();
  if (stripped.isNotEmpty && stripped != raw) return stripped;

  return 'Đã xảy ra lỗi. Vui lòng thử lại.';
}

/// Map PostgreSQL column name -> Vietnamese description.
String _describeColumn(String cols) {
  final parts = cols.split(',').map((c) => c.trim()).toList();
  final descriptions = <String, String>{
    'store_id': 'cửa hàng',
    'sku': 'mã linh kiện',
    'code': 'mã',
    'name': 'tên',
    'phone': 'số điện thoại',
    'email': 'email',
    'order_id': 'đơn hàng',
    'repair_order_id': 'đơn sửa chữa',
    'customer_id': 'khách hàng',
    'part_id': 'linh kiện',
    'account_id': 'tài khoản',
    'debt_id': 'khoản nợ',
    'user_id': 'người dùng',
    'employee_id': 'nhân viên',
  };
  final mapped = parts.map((p) => descriptions[p] ?? p).toList();
  return mapped.join(', ');
}

String _describeType(String t) {
  switch (t.toLowerCase()) {
    case 'uuid':
      return 'UUID (định danh)';
    case 'integer':
    case 'int':
    case 'int4':
      return 'số nguyên';
    case 'numeric':
    case 'decimal':
    case 'float8':
      return 'số thập phân';
    case 'text':
    case 'varchar':
      return 'chuỗi';
    case 'boolean':
    case 'bool':
      return 'true/false';
    case 'date':
      return 'ngày';
    case 'timestamp':
    case 'timestamptz':
      return 'thời gian';
    case 'repair_status':
      return 'trạng thái sửa chữa';
    case 'tx_type':
      return 'loại giao dịch';
    case 'inventory_tx_type':
      return 'loại giao dịch kho';
    default:
      return t;
  }
}

String _describeTable(String t) {
  const map = {
    'customers': 'khách hàng',
    'repair_orders': 'đơn sửa chữa',
    'repair_order_status_history': 'lịch sử trạng thái',
    'inventory_parts': 'linh kiện kho',
    'inventory_transactions': 'giao dịch kho',
    'stock_counts': 'kiểm kê kho',
    'cash_accounts': 'tài khoản tiền',
    'debts': 'khoản nợ',
    'debt_transactions': 'giao dịch nợ',
    'transactions': 'giao dịch',
    'salary_payments': 'lương nhân viên',
    'qr_codes': 'mã QR',
    'notifications': 'thông báo',
    'employee_invites': 'lời mời nhân viên',
    'profiles': 'tài khoản',
    'part_categories': 'danh mục linh kiện',
    'stores': 'cửa hàng',
    'app_logs': 'nhật ký',
  };
  return map[t] ?? t;
}

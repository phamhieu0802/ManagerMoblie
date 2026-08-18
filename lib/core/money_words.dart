/// Chuyển số tiền (VNĐ) sang chữ tiếng Việt, VD: 1500000 -> "Một triệu năm trăm nghìn đồng".
/// Dùng để hiện gợi ý ngay dưới các ô nhập giá tiền, tránh gõ nhầm số 0.
String moneyToVietnameseWords(num amount) {
  if (amount == 0) return 'Không đồng';
  final isNegative = amount < 0;
  var n = amount.abs().truncate();

  const digits = ['không', 'một', 'hai', 'ba', 'bốn', 'năm', 'sáu', 'bảy', 'tám', 'chín'];
  const units = ['', ' nghìn', ' triệu', ' tỷ', ' nghìn tỷ', ' triệu tỷ'];

  String readThree(int number, bool isFirstGroup) {
    final hundred = number ~/ 100;
    final remainder = number % 100;
    final ten = remainder ~/ 10;
    final unit = remainder % 10;
    final parts = <String>[];

    if (hundred > 0 || !isFirstGroup) {
      parts.add('${digits[hundred]} trăm');
    }
    if (ten == 0) {
      if (unit > 0) {
        if (hundred > 0 || !isFirstGroup) parts.add('lẻ');
        parts.add(digits[unit]);
      }
    } else if (ten == 1) {
      parts.add('mười');
      if (unit == 1) {
        parts.add('một');
      } else if (unit == 5) {
        parts.add('lăm');
      } else if (unit > 0) {
        parts.add(digits[unit]);
      }
    } else {
      parts.add('${digits[ten]} mươi');
      if (unit == 1) {
        parts.add('mốt');
      } else if (unit == 5) {
        parts.add('lăm');
      } else if (unit > 0) {
        parts.add(digits[unit]);
      }
    }
    return parts.join(' ');
  }

  final groups = <int>[];
  while (n > 0) {
    groups.add((n % 1000).toInt());
    n ~/= 1000;
  }
  if (groups.isEmpty) groups.add(0);

  final resultParts = <String>[];
  for (var i = groups.length - 1; i >= 0; i--) {
    final group = groups[i];
    if (group == 0) continue;
    final isFirstGroup = i == groups.length - 1;
    final words = readThree(group, isFirstGroup);
    resultParts.add('$words${units[i]}');
  }

  var result = resultParts.join(' ').trim();
  result = result[0].toUpperCase() + result.substring(1);
  return '${isNegative ? "Âm " : ""}$result đồng';
}

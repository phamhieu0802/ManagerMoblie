/// Phiên bản hiện tại của app.
const String currentAppVersion = '2.1.6';

/// So sánh 2 version string (major.minor.patch).
/// Trả về:
///  - 1 nếu a > b
///  - -1 nếu a < b
///  - 0 nếu a == b
int compareVersions(String a, String b) {
  final pa = a.split('.').map(int.tryParse).toList();
  final pb = b.split('.').map(int.tryParse).toList();
  for (var i = 0; i < 3; i++) {
    final va = (i < pa.length ? pa[i] : 0) ?? 0;
    final vb = (i < pb.length ? pb[i] : 0) ?? 0;
    if (va > vb) return 1;
    if (va < vb) return -1;
  }
  return 0;
}

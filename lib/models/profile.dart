enum UserRole { admin, receptionist, technician }

UserRole roleFromString(String value) {
  switch (value) {
    case 'admin':
      return UserRole.admin;
    case 'receptionist':
      return UserRole.receptionist;
    case 'technician':
      return UserRole.technician;
    default:
      return UserRole.technician;
  }
}

String roleToString(UserRole role) => role.name;

String roleLabel(UserRole role) {
  switch (role) {
    case UserRole.admin:
      return 'Quản trị (Chủ cửa hàng)';
    case UserRole.receptionist:
      return 'Lễ tân';
    case UserRole.technician:
      return 'Kỹ thuật viên';
  }
}

class Profile {
  final String id;
  final String? storeId;
  final String fullName;
  final String? phone;
  final UserRole role;
  final String? username;
  final bool isActive;
  final String? avatarUrl;
  final double? commissionRate;

  /// Cơ chế tính lương: 'labor_fixed' (số tiền cố định/1 đơn) hoặc 'profit_pct' (% lợi nhuận).
  final String? commissionType;

  /// Số tiền hoa hồng nhận trên 1 hóa đơn (VNĐ), dùng khi [commissionType] = 'labor_fixed'.
  final double? commissionAmount;
  final String? discordId;

  Profile({
    required this.id,
    required this.storeId,
    required this.fullName,
    required this.role,
    this.phone,
    this.username,
    this.isActive = true,
    this.avatarUrl,
    this.commissionRate,
    this.commissionType,
    this.commissionAmount,
    this.discordId,
  });

  factory Profile.fromMap(Map<String, dynamic> map) => Profile(
        id: map['id'] as String,
        storeId: map['store_id'] as String?,
        fullName: map['full_name'] as String? ?? '',
        phone: map['phone'] as String?,
        role: roleFromString(map['role'] as String? ?? 'technician'),
        username: map['username'] as String?,
        isActive: map['is_active'] as bool? ?? true,
        avatarUrl: map['avatar_url'] as String?,
        commissionRate: (map['commission_rate'] as num?)?.toDouble(),
        commissionType: map['commission_type'] as String?,
        commissionAmount: (map['commission_amount'] as num?)?.toDouble(),
        discordId: map['discord_id'] as String?,
      );
}

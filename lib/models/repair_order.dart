class RepairOrder {
  final String id;
  final String storeId;
  final String code;
  final String? customerId;
  final String? deviceModel;
  final String? imei;
  final String? issueDescription;
  final String? note;
  final String? photoFrontPath;
  final String? photoBackPath;
  final String status;
  final DateTime statusChangedAt;
  final int agingAlertLevel;
  final String? technicianId;
  final String? repairedBy;
  final String? receivedBy;
  final String? deliveredBy;
  final num estimatedCost;
  final num finalCost;
  final int warrantyDays;
  final String? paymentMethod;
  final DateTime? paidAt;
  final DateTime receivedAt;
  final DateTime? completedAt;
  final DateTime? deliveredAt;
  final DateTime? deletedAt;
  final String? deletedBy;

  RepairOrder({
    required this.id,
    required this.storeId,
    required this.code,
    required this.status,
    required this.statusChangedAt,
    this.agingAlertLevel = 0,
    required this.receivedAt,
    this.customerId,
    this.deviceModel,
    this.imei,
    this.issueDescription,
    this.note,
    this.photoFrontPath,
    this.photoBackPath,
    this.technicianId,
    this.repairedBy,
    this.receivedBy,
    this.deliveredBy,
    this.estimatedCost = 0,
    this.finalCost = 0,
    this.warrantyDays = 0,
    this.paymentMethod,
    this.paidAt,
    this.completedAt,
    this.deliveredAt,
    this.deletedAt,
    this.deletedBy,
  });

  bool get isDeleted => deletedAt != null;

  factory RepairOrder.fromMap(Map<String, dynamic> map) => RepairOrder(
        id: map['id'] as String,
        storeId: map['store_id'] as String,
        code: map['code'] as String,
        status: map['status'] as String,
        statusChangedAt: map['status_changed_at'] != null
            ? DateTime.parse(map['status_changed_at'] as String)
            : DateTime.parse(map['received_at'] as String),
        agingAlertLevel: map['aging_alert_level'] as int? ?? 0,
        receivedAt: DateTime.parse(map['received_at'] as String),
        customerId: map['customer_id'] as String?,
        deviceModel: map['device_model'] as String?,
        imei: map['imei'] as String?,
        issueDescription: map['issue_description'] as String?,
        note: map['note'] as String?,
        photoFrontPath: map['photo_front_path'] as String?,
        photoBackPath: map['photo_back_path'] as String?,
        technicianId: map['technician_id'] as String?,
        repairedBy: map['repaired_by'] as String?,
        receivedBy: map['received_by'] as String?,
        deliveredBy: map['delivered_by'] as String?,
        estimatedCost: map['estimated_cost'] as num? ?? 0,
        finalCost: map['final_cost'] as num? ?? 0,
        warrantyDays: map['warranty_days'] as int? ?? 0,
        paymentMethod: map['payment_method'] as String?,
        paidAt: map['paid_at'] != null ? DateTime.parse(map['paid_at'] as String) : null,
        completedAt: map['completed_at'] != null
            ? DateTime.parse(map['completed_at'] as String)
            : null,
        deliveredAt: map['delivered_at'] != null
            ? DateTime.parse(map['delivered_at'] as String)
            : null,
        deletedAt: map['deleted_at'] != null ? DateTime.parse(map['deleted_at'] as String) : null,
        deletedBy: map['deleted_by'] as String?,
      );
}

/// Toàn bộ trạng thái hợp lệ của 1 đơn sửa chữa.
const repairStatusOptions = [
  'received',
  'repairing',
  'repaired',
  'delivered',
  'cancelled',
];

/// Trạng thái được phép chọn tuỳ theo vai trò người được phân công xử lý đơn:
/// - Lễ tân: tiếp nhận / đã sửa xong / đã trả máy / khách không sửa (không tự
///   sửa máy nên không có "đang sửa").
/// - Kỹ thuật viên: chỉ đang sửa / đã sửa xong (không tiếp khách, không trả máy).
/// - Admin (hoặc chưa phân công ai): toàn quyền chọn cả 5 trạng thái
///   (admin được coi là 1 KTV nên có đầy đủ sửa/trả máy).
List<String> statusOptionsForRole(String? role) {
  switch (role) {
    case 'receptionist':
      return const ['received', 'repaired', 'delivered', 'cancelled'];
    case 'technician':
      return const ['repairing', 'repaired'];
    default:
      return repairStatusOptions;
  }
}

class Store {
  final String id;
  final String name;
  final String storeCode;
  final String? address;
  final String? phone;
  final String ownerId;
  final String? bankName;
  final String? bankAccount;
  final String? bankBranch;
  final String? bankQr;
  final String? printHeader;
  final String? printFooter;
  final String? taxCode;
  final bool printShowTimestamp;
  final bool printShowTaxCode;
  final bool printShowBank;
  final String? discordWebhookUrl;
  final String? printerAddress;
  final String? printerType;
  final bool autoBackup;
  final DateTime? lastBackupAt;

  Store({
    required this.id,
    required this.name,
    required this.storeCode,
    required this.ownerId,
    this.address,
    this.phone,
    this.taxCode,
    this.bankName,
    this.bankAccount,
    this.bankBranch,
    this.bankQr,
    this.printHeader,
    this.printFooter,
    this.printShowTimestamp = true,
    this.printShowTaxCode = true,
    this.printShowBank = true,
    this.discordWebhookUrl,
    this.printerAddress,
    this.printerType,
    this.autoBackup = false,
    this.lastBackupAt,
  });

  factory Store.fromMap(Map<String, dynamic> map) => Store(
        id: map['id'] as String,
        name: map['name'] as String,
        storeCode: map['store_code'] as String,
        ownerId: map['owner_id'] as String,
        address: map['address'] as String?,
        phone: map['phone'] as String?,
        taxCode: map['tax_code'] as String?,
        bankName: map['bank_name'] as String?,
        bankAccount: map['bank_account'] as String?,
        bankBranch: map['bank_branch'] as String?,
        bankQr: map['bank_qr'] as String?,
        printHeader: map['print_header'] as String?,
        printFooter: map['print_footer'] as String?,
        printShowTimestamp: map['print_show_timestamp'] as bool? ?? true,
        printShowTaxCode: map['print_show_tax_code'] as bool? ?? true,
        printShowBank: map['print_show_bank'] as bool? ?? true,
        discordWebhookUrl: map['discord_webhook_url'] as String?,
        printerAddress: map['printer_address'] as String?,
        printerType: map['printer_type'] as String?,
        autoBackup: map['auto_backup'] as bool? ?? false,
        lastBackupAt: map['last_backup_at'] != null
            ? DateTime.tryParse(map['last_backup_at'] as String)
            : null,
      );
}

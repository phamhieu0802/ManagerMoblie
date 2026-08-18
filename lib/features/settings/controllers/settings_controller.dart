import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show UserAttributes;
import '../../../core/supabase_service.dart';
import '../../../models/store.dart';

final storeDetailProvider = FutureProvider.family<Store?, String>((ref, storeId) async {
  final row = await SupabaseService.client.from('stores').select().eq('id', storeId).maybeSingle();
  return row == null ? null : Store.fromMap(row);
});

class SettingsController {
  static Future<void> updateStore({
    required String storeId,
    String? name,
    String? address,
    String? phone,
    String? taxCode,
    String? bankName,
    String? bankAccount,
    String? bankBranch,
    String? bankQr,
    String? printHeader,
    String? printFooter,
    bool? printShowTimestamp,
    bool? printShowTaxCode,
    bool? printShowBank,
    String? discordWebhookUrl,
    String? printerAddress,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (address != null) updates['address'] = address;
    if (phone != null) updates['phone'] = phone;
    if (taxCode != null) updates['tax_code'] = taxCode;
    if (bankName != null) updates['bank_name'] = bankName;
    if (bankAccount != null) updates['bank_account'] = bankAccount;
    if (bankBranch != null) updates['bank_branch'] = bankBranch;
    if (bankQr != null) updates['bank_qr'] = bankQr;
    if (printHeader != null) updates['print_header'] = printHeader;
    if (printFooter != null) updates['print_footer'] = printFooter;
    if (printShowTimestamp != null) updates['print_show_timestamp'] = printShowTimestamp;
    if (printShowTaxCode != null) updates['print_show_tax_code'] = printShowTaxCode;
    if (printShowBank != null) updates['print_show_bank'] = printShowBank;
    if (discordWebhookUrl != null) updates['discord_webhook_url'] = discordWebhookUrl;
    if (printerAddress != null) updates['printer_address'] = printerAddress;
    if (updates.isEmpty) return;
    await SupabaseService.client.from('stores').update(updates).eq('id', storeId);
  }

  static Future<void> updateProfile({
    required String userId,
    String? fullName,
    String? phone,
    String? discordId,
  }) async {
    final updates = <String, dynamic>{};
    if (fullName != null) updates['full_name'] = fullName;
    if (phone != null) updates['phone'] = phone;
    if (discordId != null) updates['discord_id'] = discordId;
    if (updates.isEmpty) return;
    await SupabaseService.client.from('profiles').update(updates).eq('id', userId);
  }

  static Future<void> changePassword(String newPassword) async {
    await SupabaseService.auth.updateUser(UserAttributes(password: newPassword));
  }
}

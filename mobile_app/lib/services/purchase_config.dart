import 'package:flutter/foundation.dart';

import 'supabase_service.dart';

/// Review switch (app_config.purchases_enabled, add-purchase-switch.sql).
/// When off, the app shows no prices, no enroll buttons for paid courses
/// and no payment form, for every account. Free courses and
/// already-enrolled students are unaffected. Flipped by an admin from the
/// admin screen, no app update needed.
class PurchaseConfig extends ChangeNotifier {
  PurchaseConfig._();
  static final PurchaseConfig instance = PurchaseConfig._();

  // Hidden until the setting has been read: if it can't be loaded, buying
  // stays hidden rather than showing to a reviewer by accident.
  bool _enabled = false;

  /// No Wayl or manual payment inside the apps (decided 2026-10-19): the
  /// website sells courses, and on iPhone Apple In-App Purchase does too
  /// (AppleIap, shown by the course page itself). Paid courses stay visible with their lectures and files
  /// locked; a course bought on the website unlocks here automatically.
  /// Neither app links to the website to buy, on any storefront (App
  /// Review 3.1.1, 2026-10-21).
  bool get enabled => false;

  /// The raw setting (for the admin toggle).
  bool get setting => _enabled;

  Future<void> load() async {
    final sb = SupabaseService.instance.client;
    try {
      final row = await sb
          .from('app_config')
          .select('value')
          .eq('key', 'purchases_enabled')
          .maybeSingle();
      _enabled = row?['value'] == true;
    } catch (_) {
      // Table not added yet or offline: keep the last value.
    }
    notifyListeners();
  }

  /// Admin only (the database rejects anyone else).
  Future<void> set(bool on) async {
    final saved = await SupabaseService.instance.client
        .from('app_config')
        .update({
          'value': on,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('key', 'purchases_enabled')
        .select('value');
    // A refused update changes no row and raises no error: show what the
    // database really holds, not what was asked for.
    _enabled = (saved as List).isNotEmpty ? saved.first['value'] == true : _enabled;
    notifyListeners();
    if (saved.isEmpty) throw StateError('purchase switch not saved');
  }
}

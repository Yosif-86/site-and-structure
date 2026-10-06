import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'supabase_service.dart';

/// Review switch (app_config.purchases_enabled, add-purchase-switch.sql).
/// When off, the app shows no prices, no enroll buttons for paid courses
/// and no payment form: what store reviewers must see. Free courses and
/// already-enrolled students are unaffected. Flipped by an admin from the
/// admin screen, no app update needed.
class PurchaseConfig extends ChangeNotifier {
  PurchaseConfig._();
  static final PurchaseConfig instance = PurchaseConfig._();

  // Hidden until the setting has been read: if it can't be loaded, buying
  // stays hidden rather than showing to a reviewer by accident.
  bool _enabled = false;
  bool _reviewer = false;

  /// Apple requires its own in-app purchase for digital courses, so the
  /// iPhone app never shows buying: students buy outside the iPhone app
  /// and watch on iPhone.
  static final bool _platformAllowsBuying = kIsWeb || !Platform.isIOS;

  /// Whether this user may see prices and buy.
  bool get enabled => _enabled && !_reviewer && _platformAllowsBuying;

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
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      _reviewer = false;
    } else {
      try {
        final me = await sb
            .from('profiles')
            .select('is_reviewer')
            .eq('id', user.id)
            .maybeSingle();
        _reviewer = me?['is_reviewer'] == true;
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Admin only (the database rejects anyone else).
  Future<void> set(bool on) async {
    await SupabaseService.instance.client.from('app_config').update({
      'value': on,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('key', 'purchases_enabled');
    _enabled = on;
    notifyListeners();
  }
}

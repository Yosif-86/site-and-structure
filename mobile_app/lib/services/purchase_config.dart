import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  /// iPhone: Apple allows a button to an outside checkout (Wayl) only for
  /// App Store accounts in the United States (Epic v. Apple, May 2025), so
  /// buying shows only when the device's App Store country is USA. Most
  /// iPhone users in Iraq use US Apple IDs. iPhone ignores the review switch
  /// above, which exists for Google Play.
  bool _iosUsStorefront = false;
  static const _storefront = MethodChannel('site_and_structure/storefront');

  /// Whether this user may see prices and buy.
  /// Test builds only (--dart-define=FORCE_BUY=true): show the Wayl button
  /// on Android regardless of the switch, to try a test-mode payment.
  static const bool _forceBuy = bool.fromEnvironment('FORCE_BUY');

  /// Store reviewers see exactly what real users on their storefront see:
  /// hiding buying from the review account would be a concealed feature
  /// (App Review guideline 2.5.19), so is_reviewer no longer affects it.
  bool get enabled {
    if (_forceBuy) return true;
    if (!kIsWeb && Platform.isIOS) return _iosUsStorefront;
    return _enabled;
  }

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
    if (!kIsWeb && Platform.isIOS) {
      try {
        final code = await _storefront.invokeMethod<String>('countryCode');
        _iosUsStorefront = code == 'USA' || code == 'US';
      } catch (_) {
        _iosUsStorefront = false;
      }
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

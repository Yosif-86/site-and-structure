// Replaces the stock `flutter create` counter smoke test, which referenced a
// `MyApp` class and a counter UI that never existed in this app (it was a
// compile error, not just a failing test). Pumping the real app root isn't
// practical in a plain unit test — it calls Supabase.initialize() and hits
// secure storage — so this covers the pure helpers instead.

import 'package:flutter_test/flutter_test.dart';

import 'package:site_and_structure/i18n/strings.dart';
import 'package:site_and_structure/services/deep_links.dart';

void main() {
  group('DeepLinks.handle', () {
    test('strips a leading @', () {
      expect(DeepLinks.handle('@someone'), 'someone');
      expect(DeepLinks.handle('  @someone  '), 'someone');
    });

    test('leaves a bare handle alone', () {
      expect(DeepLinks.handle('someone'), 'someone');
    });
  });

  group('DeepLinks.whatsappNumber', () {
    test('promotes a local Iraqi number to +964', () {
      expect(DeepLinks.whatsappNumber('07701234567'), '9647701234567');
      expect(DeepLinks.whatsappNumber('0770 123 4567'), '9647701234567');
    });

    test('passes an already-international number through', () {
      expect(DeepLinks.whatsappNumber('+964 770 123 4567'), '9647701234567');
      expect(DeepLinks.whatsappNumber('00964 770 123 4567'), '9647701234567');
    });

    test('strips separators', () {
      expect(DeepLinks.whatsappNumber('+1 (555) 010-9999'), '15550109999');
    });
  });

  group('AppStrings', () {
    test('resolves the new profile and settings keys', () {
      final t = AppStrings.instance.t;
      for (final key in [
        'profile_title',
        'edit_profile',
        'settings_support',
        'settings_privacy',
        'settings_payment_info',
        'privacy_draft_notice',
      ]) {
        expect(t(key), isNot(key), reason: 'missing i18n string for "$key"');
      }
    });

    test('falls back to the key itself when missing', () {
      expect(AppStrings.instance.t('definitely_not_a_key'), 'definitely_not_a_key');
    });
  });
}

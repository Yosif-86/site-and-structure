import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/services/signup_rules.dart';

void main() {
  test('phone normalization', () {
    expect(SignupRules.normalizeIraqiPhone('0780 123 4567'), '07801234567');
    expect(SignupRules.normalizeIraqiPhone('+964 750 123 4567'), '07501234567');
    expect(SignupRules.normalizeIraqiPhone('٠٧٨٠١٢٣٤٥٦٧'), '07801234567');
    expect(SignupRules.normalizeIraqiPhone('7701234567'), '07701234567');
    expect(SignupRules.normalizeIraqiPhone('07601234567'), isNull);
    expect(SignupRules.normalizeIraqiPhone('0780123456'), isNull);
    expect(SignupRules.normalizeIraqiPhone('078012345678'), isNull);
  });
  test('email domain', () {
    expect(SignupRules.isAllowedEmailDomain('a@Gmail.com'), isTrue);
    expect(SignupRules.isAllowedEmailDomain('a@st.nahrainuniv.edu.iq'), isTrue);
    expect(SignupRules.isAllowedEmailDomain('a@mailinator.com'), isFalse);
    expect(SignupRules.isAllowedEmailDomain('a@gmail.com.evil.io'), isFalse);
  });
  test('password strength', () {
    expect(SignupRules.isStrongPassword('Abcdefg1'), isTrue);
    expect(SignupRules.isStrongPassword('abcdefg1'), isFalse);
    expect(SignupRules.isStrongPassword('Abcdefgh'), isFalse);
    expect(SignupRules.isStrongPassword('Ab1'), isFalse);
  });
}

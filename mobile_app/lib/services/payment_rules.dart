import 'package:flutter/services.dart';

/// Payment numbers (Zain Cash phone, Qi Card account) and the platform's
/// commission, in one place so the admin, teacher and student screens agree.
class PaymentRules {
  /// Digits and spaces only -- spaces so people can type the number grouped
  /// the way it's printed on the card.
  static final numberInput = <TextInputFormatter>[
    FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
    LengthLimitingTextInputFormatter(24),
  ];

  static String digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// Iraqi mobile number: 07 + 9 digits.
  static bool isValidZain(String s) => RegExp(r'^07\d{9}$').hasMatch(digits(s));

  /// Qi Card account / card number: 8 to 20 digits.
  static bool isValidQi(String s) {
    final d = digits(s);
    return d.length >= 8 && d.length <= 20;
  }

  /// The platform's share of every paid enrollment, on the full price.
  static const platformRate = 0.20;

  /// Biggest discount a teacher may give: their whole 80% share.
  static const maxDiscountRate = 0.80;

  static int parsePrice(dynamic price) {
    final d = digits('${price ?? ''}');
    return d.isEmpty ? 0 : int.parse(d);
  }

  /// Splits one enrollment. [paid] is what the student actually paid (after
  /// any discount). The platform always takes 20% of the full [price]; the
  /// teacher gets the rest of what was paid. A direct-payment course of a
  /// teacher with that privilege keeps everything (no platform cut).
  static ({int platform, int teacher}) split(
      {required int price, required int paid, bool directToTeacher = false}) {
    if (directToTeacher) return (platform: 0, teacher: paid);
    final platform = (price * platformRate).round();
    final teacher = paid - platform;
    return (platform: platform, teacher: teacher < 0 ? 0 : teacher);
  }
}

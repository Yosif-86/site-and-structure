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

  /// Default platform share of every paid enrollment, on the full price.
  /// Each teacher can have their own (profiles.platform_rate, set by the
  /// admin, 0 to [maxPlatformPercent]).
  static const defaultPlatformPercent = 15.0;
  static const maxPlatformPercent = 30.0;
  static const platformRate = defaultPlatformPercent / 100;

  /// A teacher's platform share as a fraction (0.15), from the percent stored
  /// on their profile; anything missing or out of range counts as the default.
  static double rateFrom(dynamic percent) {
    final n = num.tryParse('${percent ?? ''}');
    if (n == null || n < 0 || n > maxPlatformPercent) return platformRate;
    return n / 100;
  }

  /// Biggest discount a teacher may give: their whole share (1 - platform cut).
  static double maxDiscountFor(double rate) => 1 - rate;

  /// 0.15 -> "15", 0.125 -> "12.5".
  static String pct(double rate) {
    final v = rate * 100;
    final r = double.parse(v.toStringAsFixed(2));
    return r == r.roundToDouble() ? r.round().toString() : r.toString();
  }

  static int parsePrice(dynamic price) {
    final d = digits('${price ?? ''}');
    return d.isEmpty ? 0 : int.parse(d);
  }

  /// Splits one enrollment. [paid] is what the student actually paid (after
  /// any discount). The platform always takes [rate] of the full [price]; the
  /// teacher gets the rest of what was paid. A direct-payment course of a
  /// teacher with that privilege keeps everything (no platform cut).
  static ({int platform, int teacher}) split(
      {required int price,
      required int paid,
      bool directToTeacher = false,
      double rate = platformRate}) {
    if (directToTeacher) return (platform: 0, teacher: paid);
    final platform = (price * rate).round();
    final teacher = paid - platform;
    return (platform: platform, teacher: teacher < 0 ? 0 : teacher);
  }
}

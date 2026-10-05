import 'package:flutter/services.dart';

/// Prices shown the same way everywhere: 1,000 IQD / 20,000 IQD / 100,000 IQD.
class Money {
  Money._();

  // Left-to-right isolate: inside Arabic (right-to-left) text the number and
  // "IQD" would otherwise swap places and read "IQD 100,000".
  static const _lri = '⁦';
  static const _pdi = '⁩';

  /// 1000000 -> "1,000,000" (no currency).
  static String group(num value) {
    final s = value.round().abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return value < 0 ? '-$b' : b.toString();
  }

  /// 100000 -> "100,000 IQD".
  static String iqd(num value) => '$_lri${group(value)} IQD$_pdi';

  /// Whole-number digits of anything price-like ("IQD 65,000", "15000",
  /// " 10 000 "); null when there are none.
  static int? digitsOf(dynamic v) {
    final d = (v?.toString() ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    return d.isEmpty ? null : int.tryParse(d);
  }

  /// Course price text from the database -> "65,000 IQD", or [fallback] when
  /// it holds no number.
  static String text(dynamic price, {String fallback = '—'}) {
    final n = digitsOf(price);
    return n == null ? fallback : iqd(n);
  }

  /// Price / discount / amount paid as lines of text (confirm dialogs).
  static String paymentSummary(
    String Function(String) t, {
    required int price,
    required int discount,
    required int paid,
    String? code,
  }) {
    final b = StringBuffer('${t('pay_lbl_price')}: ${iqd(price)}');
    if (discount > 0) {
      final c = (code != null && code.isNotEmpty) ? ' ($code)' : '';
      b.write('\n${t('pay_lbl_discount')}$c: -${iqd(discount)}');
    }
    b.write('\n${t('pay_lbl_paid')}: ${iqd(paid)}');
    return b.toString();
  }

  /// Shows commas while typing: 100000 -> 100,000. The saved value is read
  /// back with digits only (PaymentRules.parsePrice already ignores commas).
  static final inputFormatters = <TextInputFormatter>[
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(12),
    const _GroupingFormatter(),
  ];
}

class _GroupingFormatter extends TextInputFormatter {
  const _GroupingFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return newValue.copyWith(text: '');
    final text = Money.group(int.parse(digits));
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

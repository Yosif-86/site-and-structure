import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/services/money.dart';

void main() {
  test('groups thousands', () {
    expect(Money.group(0), '0');
    expect(Money.group(999), '999');
    expect(Money.group(1000), '1,000');
    expect(Money.group(20000), '20,000');
    expect(Money.group(100000), '100,000');
    expect(Money.group(1234567), '1,234,567');
  });

  test('iqd suffix, forced left-to-right', () {
    expect(Money.iqd(100000), '⁦100,000 IQD⁩');
  });

  test('reads old price text formats', () {
    expect(Money.digitsOf('IQD 65,000'), 65000);
    expect(Money.digitsOf('15,000 IQD'), 15000);
    expect(Money.digitsOf('10000'), 10000);
    expect(Money.digitsOf(null), isNull);
    expect(Money.text('IQD 65,000'), '⁦65,000 IQD⁩');
    expect(Money.text(null), '—');
  });

  test('typing adds commas and keeps the cursor at the end', () {
    var value = const TextEditingValue();
    for (final ch in '100000'.split('')) {
      var next = TextEditingValue(
          text: value.text + ch,
          selection: TextSelection.collapsed(offset: value.text.length + 1));
      for (final f in Money.inputFormatters) {
        next = f.formatEditUpdate(value, next);
      }
      value = next;
    }
    expect(value.text, '100,000');
    expect(value.selection.baseOffset, 7);
    // Deleting the last digit.
    var del = TextEditingValue(
        text: '100,00', selection: const TextSelection.collapsed(offset: 6));
    for (final f in Money.inputFormatters) {
      del = f.formatEditUpdate(value, del);
    }
    expect(del.text, '10,000');
  });

  test('payment summary lists price, discount and paid', () {
    String t(String k) => {
          'pay_lbl_price': 'السعر',
          'pay_lbl_discount': 'الخصم',
          'pay_lbl_paid': 'المبلغ المدفوع',
        }[k]!;
    final s = Money.paymentSummary(t,
        price: 30000, discount: 22000, paid: 8000, code: 'SAVE20');
    expect(s.contains('SAVE20'), isTrue);
    expect(s.split('\n').length, 3);
    final noDiscount = Money.paymentSummary(t,
        price: 10000, discount: 0, paid: 10000);
    expect(noDiscount.split('\n').length, 2);
  });
}

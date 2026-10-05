import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/services/text_search.dart';

void main() {
  test('finds by id with or without #', () {
    final fields = ['Yosif', 'a@b.com', '07822248697', '#2274'];
    expect(TextSearch.matches('2274', fields), isTrue);
    expect(TextSearch.matches(' 2274 '.replaceAll('#', ' '), fields), isTrue);
    expect(TextSearch.matches('9999', fields), isFalse);
  });

  test('name, email and phone parts, any order', () {
    final fields = ['Yosif Jamal', 'civilq.86@gmail.com', '07803006818'];
    expect(TextSearch.matches('jamal yosif', fields), isTrue);
    expect(TextSearch.matches('civilq', fields), isTrue);
    expect(TextSearch.matches('0780300', fields), isTrue);
    expect(TextSearch.matches('nobody', fields), isFalse);
    expect(TextSearch.matches('', fields), isTrue);
  });

  test('Arabic spelling variants', () {
    expect(TextSearch.matches('احمد', ['أحمد علي']), isTrue);
    expect(TextSearch.matches('مهندسه', ['مهندسة']), isTrue);
    expect(TextSearch.matches('موسى', ['موسي']), isTrue);
  });
}

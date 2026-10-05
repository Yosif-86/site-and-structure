/// Search helpers shared by the explore page and the admin lists.
class TextSearch {
  TextSearch._();

  /// Folds Arabic spelling variants together so "انشائية" finds "إنشائية":
  /// hamza forms of alef, taa marbuta / haa, alef maqsura / yaa, and ignores
  /// diacritics and tatweel. Latin text is lower-cased.
  static String normalize(String s) {
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      if (r >= 0x064B && r <= 0x0652) continue; // tashkeel
      if (r == 0x0640) continue; // tatweel
      switch (r) {
        case 0x0623: // أ
        case 0x0625: // إ
        case 0x0622: // آ
        case 0x0671: // ٱ
          b.writeCharCode(0x0627); // ا
        case 0x0629: // ة
          b.writeCharCode(0x0647); // ه
        case 0x0649: // ى
          b.writeCharCode(0x064A); // ي
        case 0x0624: // ؤ
          b.writeCharCode(0x0648); // و
        case 0x0626: // ئ
          b.writeCharCode(0x064A); // ي
        default:
          b.writeCharCode(r);
      }
    }
    return b.toString();
  }

  /// The words of a query, normalized (empty list for a blank query).
  static List<String> words(String query) => normalize(query.trim())
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Every typed word must appear somewhere in [fields], in any order.
  static bool matches(String query, Iterable<Object?> fields) {
    final w = words(query);
    if (w.isEmpty) return true;
    final hay = normalize(fields.map((f) => f?.toString() ?? '').join(' '));
    return w.every(hay.contains);
  }
}

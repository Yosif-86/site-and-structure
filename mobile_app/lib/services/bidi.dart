/// Keeps a name that is written in another script (an English course title
/// inside an Arabic sentence) from reshuffling the sentence around it:
/// the Unicode isolate marks make it read as one unit in its own direction.
class Bidi {
  Bidi._();

  static String iso(String? s) {
    final v = (s ?? '').trim();
    return v.isEmpty ? v : '\u2068$v\u2069';
  }
}

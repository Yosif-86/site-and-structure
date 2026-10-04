/// Ignores a second navigation tap that lands right after the first one
/// (a double tap used to open the same screen twice).
class TapGuard {
  static DateTime? _last;

  static bool allow({int ms = 700}) {
    final now = DateTime.now();
    if (_last != null && now.difference(_last!).inMilliseconds < ms) {
      return false;
    }
    _last = now;
    return true;
  }
}

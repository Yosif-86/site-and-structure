/// Signup field rules. Mirrored on the website (signup-rules.js) and enforced
/// again in the database (add-signup-validation.sql), so a modified client
/// can't skip them -- these client checks only exist to give a clear message
/// before the request is ever sent.
class SignupRules {
  SignupRules._();

  /// Well-known providers only. An allowlist (rather than blocking known
  /// temp-mail domains) is the only approach that keeps up with the endless
  /// stream of new disposable domains. University addresses (*.edu.iq) are
  /// trusted too, since most students here have one.
  static const Set<String> allowedEmailDomains = {
    'gmail.com',
    'googlemail.com',
    'outlook.com',
    'hotmail.com',
    'live.com',
    'msn.com',
    'yahoo.com',
    'ymail.com',
    'icloud.com',
    'me.com',
    'mac.com',
    'proton.me',
    'protonmail.com',
    'aol.com',
  };

  static final RegExp _emailShape =
      RegExp(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$');

  static bool isValidEmailShape(String email) =>
      _emailShape.hasMatch(email.trim());

  static bool isAllowedEmailDomain(String email) {
    final at = email.trim().lastIndexOf('@');
    if (at < 0) return false;
    final domain = email.trim().substring(at + 1).toLowerCase();
    return allowedEmailDomains.contains(domain) || domain.endsWith('.edu.iq');
  }

  /// At least 8 characters with an uppercase letter, a lowercase letter and
  /// a digit. Matches the Supabase Auth password requirements set on the
  /// project, which is what actually enforces it server-side.
  static bool isStrongPassword(String password) =>
      password.length >= 8 &&
      RegExp(r'[A-Z]').hasMatch(password) &&
      RegExp(r'[a-z]').hasMatch(password) &&
      RegExp(r'[0-9]').hasMatch(password);

  /// Normalizes an Iraqi mobile number to 07XXXXXXXXX (11 digits) or returns
  /// null if it isn't one. Accepts spaces/dashes, Arabic-Indic digits, and
  /// the +964 / 00964 / 964 international forms. Prefixes: 075 Korek,
  /// 077 Asiacell, 078/079 Zain.
  static String? normalizeIraqiPhone(String raw) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    final buf = StringBuffer();
    for (final ch in raw.split('')) {
      final a = arabic.indexOf(ch);
      final p = persian.indexOf(ch);
      if (a >= 0) {
        buf.write(a);
      } else if (p >= 0) {
        buf.write(p);
      } else if (RegExp(r'[0-9]').hasMatch(ch)) {
        buf.write(ch);
      }
    }
    var d = buf.toString();
    if (d.startsWith('00964')) d = '0${d.substring(5)}';
    if (d.startsWith('964')) d = '0${d.substring(3)}';
    if (d.length == 10 && d.startsWith('7')) d = '0$d';
    return RegExp(r'^07[5789][0-9]{8}$').hasMatch(d) ? d : null;
  }
}

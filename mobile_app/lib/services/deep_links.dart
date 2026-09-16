import 'package:url_launcher/url_launcher.dart';

/// Outbound deep links for the profile social row.
///
/// Every launcher follows the same shape: try the most specific URI first
/// (a custom app scheme, which only resolves when that app is installed),
/// then fall back to the https URL, which either hands off to the app or
/// opens a browser. `canLaunchUrl` on a custom scheme needs a matching
/// `<queries>` entry in AndroidManifest.xml on Android 11+ (and
/// `LSApplicationQueriesSchemes` on iOS) — both are configured.
class DeepLinks {
  /// Strips everything but digits, e.g. '+964 770 123 4567' -> '9647701234567'.
  static String digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// Strips a leading '@' (and any accidental whitespace) off a handle, so a
  /// user who typed '@someone' still gets a working link.
  static String handle(String s) => s.trim().replaceAll(RegExp(r'^@+'), '');

  /// wa.me requires a full international number with no '+' or separators.
  /// Profiles here store Iraqi local numbers as entered at signup
  /// (e.g. '07701234567'), so a bare local number is promoted to +964.
  /// Anything already carrying a country code (00-prefixed or simply longer
  /// than a local number) is passed through untouched.
  static String whatsappNumber(String phone) {
    var d = digitsOnly(phone);
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('0') && d.length == 11) return '964${d.substring(1)}';
    return d;
  }

  static Future<bool> _tryLaunch(Uri uri) async {
    try {
      if (!await canLaunchUrl(uri)) return false;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Tries each candidate in order. If every `canLaunchUrl` probe says no
  /// (which also happens when package-visibility filtering hides an app that
  /// is in fact installed), the last candidate is launched unguarded rather
  /// than silently doing nothing.
  static Future<bool> _launchFirst(List<Uri> candidates) async {
    for (final uri in candidates) {
      if (await _tryLaunch(uri)) return true;
    }
    try {
      return await launchUrl(candidates.last, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> instagram(String username) {
    final u = handle(username);
    return _launchFirst([
      Uri.parse('instagram://user?username=$u'),
      Uri.parse('https://instagram.com/$u'),
    ]);
  }

  /// t.me alone opens the Telegram app when installed, or the web page
  /// otherwise — no separate tg:// probe needed.
  static Future<bool> telegram(String username) =>
      _launchFirst([Uri.parse('https://t.me/${handle(username)}')]);

  static Future<bool> whatsapp(String phone) =>
      _launchFirst([Uri.parse('https://wa.me/${whatsappNumber(phone)}')]);

  static Future<bool> phoneCall(String phone) =>
      _launchFirst([Uri(scheme: 'tel', path: digitsOnly(phone))]);

  static Future<bool> email(String address, {String? subject}) => _launchFirst([
        Uri(
          scheme: 'mailto',
          path: address,
          query: subject == null ? null : 'subject=${Uri.encodeComponent(subject)}',
        ),
      ]);
}

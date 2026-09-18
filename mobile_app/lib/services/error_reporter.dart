import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../i18n/strings.dart';
import 'supabase_service.dart';

/// Routes errors to the same error_logs table the website's pages report
/// into, so app crashes show up in the admin dashboard's error log instead
/// of vanishing in a release build. Inserts are open to anon/authenticated
/// by policy (add-error-logs-table.sql), and every call is best-effort: a
/// failed report must never throw or recurse into itself.
class ErrorReporter {
  static bool _reporting = false;

  static Future<void> report(Object error, StackTrace? stack,
      {String page = 'app'}) async {
    debugPrint('[$page] $error\n${stack ?? ''}');
    if (_reporting) return;
    _reporting = true;
    try {
      await SupabaseService.instance.client.from('error_logs').insert({
        'message': error
            .toString()
            .substring(0, error.toString().length.clamp(0, 2000)),
        'stack': stack
            ?.toString()
            .substring(0, stack.toString().length.clamp(0, 4000)),
        'page': 'mobile/$page',
        'user_id': SupabaseService.instance.currentUser?.id,
        'user_agent':
            'Flutter app (${kIsWeb ? 'web' : Platform.operatingSystem})',
      });
    } catch (_) {
      // Reporting failures are swallowed on purpose.
    } finally {
      _reporting = false;
    }
  }

  /// What the user sees. Raw exception text (table names, Postgres detail)
  /// stays in the log, never on screen.
  static String userMessage(Object error, {String page = 'app'}) {
    report(error, null, page: page);
    return AppStrings.instance.t('err_generic');
  }
}

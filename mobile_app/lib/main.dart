import 'dart:async';

import 'package:flutter/material.dart';

import 'i18n/strings.dart';
import 'screens/catalogue_screen.dart';
import 'services/supabase_service.dart';
import 'theme.dart';
import 'widgets/privacy_overlay.dart';

final navigatorKey = GlobalKey<NavigatorState>();

// No crash-reporting service is wired up yet (no Sentry/Firebase project
// configured) — this at least stops a release crash from vanishing
// silently, by routing every uncaught error through one place. Point
// _reportError at Sentry.captureException/Crashlytics.recordError once a
// service is set up; until then it just logs, same as an unhandled error
// would have shown in debug.
void _reportError(Object error, StackTrace stack) {
  debugPrint('Uncaught error: $error\n$stack');
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      _reportError(details.exception, details.stack ?? StackTrace.empty);
    };
    await SupabaseService.init();
    SupabaseService.instance.resumeSessionWatchIfLoggedIn();
    SupabaseService.instance.onForcedLogout = _showForcedLogoutDialog;
    runApp(const SiteAndStructureApp());
  }, _reportError);
}

void _showForcedLogoutDialog() {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      content: Text(AppStrings.instance.t('alert_kicked'), style: const TextStyle(color: AppColors.text)),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
    ),
  );
}

class SiteAndStructureApp extends StatelessWidget {
  const SiteAndStructureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppStrings.instance,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: AppStrings.instance.t('app_name'),
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          builder: (context, child) => PrivacyOverlay(child: child!),
          home: const CatalogueScreen(),
        );
      },
    );
  }
}

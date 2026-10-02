import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n/strings.dart';
import 'screens/catalogue_screen.dart';
import 'screens/set_new_password_screen.dart';
import 'services/error_reporter.dart';
import 'services/supabase_service.dart';
import 'theme.dart';
import 'widgets/intro_overlay.dart';
import 'widgets/privacy_overlay.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void _reportError(Object error, StackTrace stack) {
  ErrorReporter.report(error, stack, page: 'uncaught');
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      _reportError(details.exception, details.stack ?? StackTrace.empty);
    };
    await AppTheme.instance.init();
    await SupabaseService.init();
    SupabaseService.instance.listenForOAuthCompletion();
    await SupabaseService.instance.listenForPasswordRecovery(
        _showSetNewPasswordScreen, _showLinkExpiredDialog);
    SupabaseService.instance.resumeSessionWatchIfLoggedIn();
    SupabaseService.instance.onForcedLogout = _showForcedLogoutDialog;
    runApp(const SiteAndStructureApp());
  }, _reportError);
}

bool _setNewPasswordOpen = false;

void _showSetNewPasswordScreen() {
  final nav = navigatorKey.currentState;
  if (nav == null) {
    // Link cold-started the app: the recovery event arrives before the
    // first frame, so wait for the navigator to exist.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _showSetNewPasswordScreen());
    return;
  }
  if (_setNewPasswordOpen) return;
  _setNewPasswordOpen = true;
  nav
      .push(MaterialPageRoute(builder: (_) => const SetNewPasswordScreen()))
      .whenComplete(() => _setNewPasswordOpen = false);
}

void _showLinkExpiredDialog() {
  final context = navigatorKey.currentContext;
  if (context == null) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _showLinkExpiredDialog());
    return;
  }
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      content: Text(AppStrings.instance.t('err_link_expired'),
          style: TextStyle(color: AppColors.text)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))
      ],
    ),
  );
}

void _showForcedLogoutDialog() {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      content: Text(AppStrings.instance.t('alert_kicked'),
          style: TextStyle(color: AppColors.text)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))
      ],
    ),
  );
}

class SiteAndStructureApp extends StatelessWidget {
  const SiteAndStructureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppStrings.instance, AppTheme.instance]),
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: AppStrings.instance.t('app_name'),
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          // The launch intro sits above the navigator (not a route), so Home
          // loads underneath it and deep links (password reset) still open
          // normally; it removes itself when the animation ends.
          // Status bar icons follow the theme: light on the dark sheet,
          // dark on the white one (screens with an AppBar get the same from
          // appBarTheme; the sign-in screen forces light itself).
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.instance.isDark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            child: PrivacyOverlay(
              child: Stack(
                fit: StackFit.expand,
                children: [child!, const IntroOverlay()],
              ),
            ),
          ),
          home: const CatalogueScreen(),
        );
      },
    );
  }
}

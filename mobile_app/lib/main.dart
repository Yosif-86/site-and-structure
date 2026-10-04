import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n/strings.dart';
import 'screens/auth_screen.dart';
import 'screens/catalogue_screen.dart';
import 'screens/set_new_password_screen.dart';
import 'services/error_reporter.dart';
import 'services/notification_service.dart';
import 'services/supabase_service.dart';
import 'services/net_status.dart';
import 'services/screen_security.dart';
import 'services/upload_manager.dart';
import 'theme.dart';
import 'widgets/blueprint_splash.dart';
import 'widgets/offline_banner.dart';
import 'widgets/upload_pill.dart';
import 'widgets/privacy_overlay.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets Home notice when a screen above it closes (see CatalogueScreen).
final routeObserver = RouteObserver<PageRoute<dynamic>>();

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
    SupabaseService.instance.onSessionExpired = _showSessionExpiredDialog;
    // Starts the live notifications stream (and follows sign-in/out).
    NotificationService.instance;
    NetStatus.instance.start();
    ScreenSecurity.init();
    UploadManager.instance.onMessage = (m) => messengerKey.currentState
        ?.showSnackBar(SnackBar(content: Text(m)));
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

void _showSessionExpiredDialog() {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      content: Text(AppStrings.instance.t('session_expired'),
          style: TextStyle(color: AppColors.text)),
      actions: [
        TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              navigatorKey.currentState?.push(
                  MaterialPageRoute(builder: (_) => const AuthScreen()));
            },
            child: Text(AppStrings.instance.t('log_in'))),
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
          scaffoldMessengerKey: messengerKey,
          navigatorObservers: [routeObserver],
          title: AppStrings.instance.t('app_name'),
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          // Status bar icons follow the theme: light on the dark sheet,
          // dark on the white one (screens with an AppBar get the same from
          // appBarTheme; the sign-in screen forces light itself).
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.instance.isDark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            child: PrivacyOverlay(
              child: OfflineBanner(child: UploadPill(child: child!)),
            ),
          ),
          home: const _LaunchGate(),
        );
      },
    );
  }
}

/// What a cold start shows. Signed out: straight to the sign-in screen,
/// whose Blueprint Pour animation then lifts into the form (back from there
/// still lands on Home for browsing as a guest). Signed in: the same
/// animation as a splash over Home, then a fade.
class _LaunchGate extends StatefulWidget {
  const _LaunchGate();

  @override
  State<_LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<_LaunchGate> {
  final bool _signedIn = SupabaseService.instance.isLoggedIn;
  late bool _splash = _signedIn;
  // Dark cover for the single frame before the sign-in route is pushed, so
  // Home never flashes between the native splash and the sign-in screen.
  late bool _cover = !_signedIn;

  @override
  void initState() {
    super.initState();
    if (_signedIn) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A password-reset link that cold-started the app owns the screen.
      if (!_setNewPasswordOpen) {
        navigatorKey.currentState?.push(PageRouteBuilder(
          pageBuilder: (_, __, ___) => const AuthScreen(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 250),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        ));
      }
      if (mounted) setState(() => _cover = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const CatalogueScreen(),
        if (_cover) const ColoredBox(color: Color(0xFF14120F)),
        if (_splash)
          BlueprintSplash(onDone: () => setState(() => _splash = false)),
      ],
    );
  }
}

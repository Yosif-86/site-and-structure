import 'package:flutter/material.dart';

import 'i18n/strings.dart';
import 'screens/catalogue_screen.dart';
import 'services/supabase_service.dart';
import 'theme.dart';
import 'widgets/privacy_overlay.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.init();
  SupabaseService.instance.resumeSessionWatchIfLoggedIn();
  SupabaseService.instance.onForcedLogout = _showForcedLogoutDialog;
  runApp(const SiteAndStructureApp());
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

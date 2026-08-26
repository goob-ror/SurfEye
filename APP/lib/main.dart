import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:surfeye_app/router.dart';
import 'package:surfeye_app/services/orientation_manager.dart';
import 'package:surfeye_app/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Read system auto-rotate setting and apply portrait orientation.
  // Also registers a lifecycle observer to re-apply on app resume.
  await OrientationManager.init();

  // Edge-to-edge immersive display
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const SurfEyeApp());
}

class SurfEyeApp extends StatelessWidget {
  const SurfEyeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SurfEye',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: appRouter,
    );
  }
}

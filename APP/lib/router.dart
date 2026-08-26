import 'package:go_router/go_router.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/screens/splash_screen.dart';
import 'package:surfeye_app/screens/camera_screen.dart';
import 'package:surfeye_app/screens/home_screen.dart';
import 'package:surfeye_app/screens/results_screen.dart';
import 'package:surfeye_app/screens/calibration_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/camera',
      builder: (context, state) => const CameraScreen(),
    ),
    GoRoute(
      path: '/calibration',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final imagePath = extra?['imagePath'] as String? ?? '';
        return CalibrationScreen(imagePath: imagePath);
      },
    ),
    GoRoute(
      path: '/results',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;

        // History mode: a full Measurement object passed from home screen
        if (extra?['measurement'] is Measurement) {
          return ResultsScreen(measurement: extra!['measurement'] as Measurement);
        }

        // New capture mode: legacy angle + imagePath
        final angle = (extra?['angle'] as double?) ?? 0.0;
        final rawPaths = extra?['imagePaths'];
        final legacyPath = extra?['imagePath'] as String?;
        final List<String> imagePaths = rawPaths is List<String>
            ? rawPaths
            : (legacyPath != null ? [legacyPath] : []);
        return ResultsScreen(angle: angle, imagePaths: imagePaths);
      },
    ),
  ],
);

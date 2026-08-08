import 'package:go_router/go_router.dart';
import 'package:surfeye_app/screens/camera_screen.dart';
import 'package:surfeye_app/screens/home_screen.dart';
import 'package:surfeye_app/screens/results_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/camera',
      builder: (context, state) => const CameraScreen(),
    ),
    GoRoute(
      path: '/results',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final angle = (extra?['angle'] as double?) ?? 52.3;
        final imagePath = extra?['imagePath'] as String?;
        return ResultsScreen(angle: angle, imagePath: imagePath);
      },
    ),
  ],
);

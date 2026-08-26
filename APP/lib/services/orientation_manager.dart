import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Private lifecycle observer that re-applies orientation on app resume.
class _OrientationLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      OrientationManager.init();
    }
  }
}

/// Manages device orientation for SurfEye.
///
/// Reads the system auto-rotate setting and applies portrait-only
/// constraints (portrait up + portrait down). When auto-rotate is
/// disabled, locks to portrait-up only.
///
/// Call [init] once after [WidgetsFlutterBinding.ensureInitialized] in main().
class OrientationManager {
  static const MethodChannel _channel =
      MethodChannel('surfeye/orientation');

  static _OrientationLifecycleObserver? _observer;

  /// Reads the auto-rotate setting and applies the appropriate orientation
  /// constraints. Also registers a lifecycle observer to re-apply on resume.
  static Future<void> init() async {
    // Register the lifecycle observer only once.
    if (_observer == null) {
      _observer = _OrientationLifecycleObserver();
      WidgetsBinding.instance.addObserver(_observer!);
    }

    final autoRotate = await isAutoRotateEnabled();
    await applyOrientation(autoRotateEnabled: autoRotate);
  }

  /// Applies orientation constraints via [SystemChrome.setPreferredOrientations].
  ///
  /// - [autoRotateEnabled] == true  → portrait up + portrait down.
  /// - [autoRotateEnabled] == false → portrait-up only.
  static Future<void> applyOrientation({required bool autoRotateEnabled}) async {
    if (autoRotateEnabled) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// Returns whether the system auto-rotate setting is enabled.
  ///
  /// On Android, queries the native side via the [MethodChannel]
  /// `'surfeye/orientation'` with method `'isAutoRotateEnabled'`.
  /// Falls back to `true` (both portrait orientations) if the platform
  /// channel is unavailable.
  static Future<bool> isAutoRotateEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAutoRotateEnabled');
      return result ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }
}

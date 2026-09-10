import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for persisting calibration settings across app sessions.
///
/// Stores baseline offset and optional droplet bounding box coordinates
/// to enable users with consistent setups to skip manual calibration.
class CalibrationStorage {
  static const _baselineOffsetKey = 'baseline_offset_y';
  static const _bboxX1Key = 'droplet_bbox_x1';
  static const _bboxY1Key = 'droplet_bbox_y1';
  static const _bboxX2Key = 'droplet_bbox_x2';
  static const _bboxY2Key = 'droplet_bbox_y2';
  static const _useDefaultsKey = 'use_calibration_defaults';
  
  // Advanced settings keys
  static const _brightnessKey = 'advanced_brightness';
  static const _contrastKey = 'advanced_contrast';
  static const _edgeSensitivityKey = 'advanced_edge_sensitivity';
  static const _ellipseAngleKey = 'advanced_ellipse_angle';
  static const _ellipseScaleAKey = 'advanced_ellipse_scale_a';
  static const _ellipseScaleBKey = 'advanced_ellipse_scale_b';

  /// Save calibration defaults to persistent storage.
  ///
  /// [baselineOffsetY] is the normalized Y position of the baseline (0-1 range).
  /// [dropletBbox] is the optional normalized bounding box around the droplet.
  /// [brightness], [contrast], [edgeSensitivity], [ellipseAngle], [ellipseScaleA], 
  /// and [ellipseScaleB] are optional advanced preprocessing parameters.
  static Future<void> saveDefaults(
    double baselineOffsetY,
    Rect? dropletBbox, {
    int? brightness,
    double? contrast,
    int? edgeSensitivity,
    double? ellipseAngle,
    double? ellipseScaleA,
    double? ellipseScaleB,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setDouble(_baselineOffsetKey, baselineOffsetY);
    await prefs.setBool(_useDefaultsKey, true);

    if (dropletBbox != null) {
      await prefs.setDouble(_bboxX1Key, dropletBbox.left);
      await prefs.setDouble(_bboxY1Key, dropletBbox.top);
      await prefs.setDouble(_bboxX2Key, dropletBbox.right);
      await prefs.setDouble(_bboxY2Key, dropletBbox.bottom);
    } else {
      // Clear bbox if not provided
      await prefs.remove(_bboxX1Key);
      await prefs.remove(_bboxY1Key);
      await prefs.remove(_bboxX2Key);
      await prefs.remove(_bboxY2Key);
    }

    // Save advanced settings if provided
    if (brightness != null) {
      await prefs.setInt(_brightnessKey, brightness);
    }
    if (contrast != null) {
      await prefs.setDouble(_contrastKey, contrast);
    }
    if (edgeSensitivity != null) {
      await prefs.setInt(_edgeSensitivityKey, edgeSensitivity);
    }
    if (ellipseAngle != null) {
      await prefs.setDouble(_ellipseAngleKey, ellipseAngle);
    }
    if (ellipseScaleA != null) {
      await prefs.setDouble(_ellipseScaleAKey, ellipseScaleA);
    }
    if (ellipseScaleB != null) {
      await prefs.setDouble(_ellipseScaleBKey, ellipseScaleB);
    }
  }

  /// Load saved calibration defaults from persistent storage.
  ///
  /// Returns a map containing:
  /// - 'baselineOffsetY': double? - normalized baseline Y position
  /// - 'dropletBbox': Rect? - normalized bounding box, or null if not saved
  /// - 'useDefaults': bool - whether defaults should be applied
  /// - 'brightness': int? - brightness adjustment (-100 to 100)
  /// - 'contrast': double? - contrast multiplier (0.5 to 3.0)
  /// - 'edgeSensitivity': int? - edge detection sensitivity (10 to 150)
  /// - 'ellipseAngle': double? - ellipse rotation angle (-45 to 45)
  /// - 'ellipseScaleA': double? - ellipse width scale (0.5 to 2.0)
  /// - 'ellipseScaleB': double? - ellipse height scale (0.5 to 2.0)
  static Future<Map<String, dynamic>> loadDefaults() async {
    final prefs = await SharedPreferences.getInstance();

    final useDefaults = prefs.getBool(_useDefaultsKey) ?? false;
    if (!useDefaults) {
      return {'useDefaults': false};
    }

    final baselineOffsetY = prefs.getDouble(_baselineOffsetKey);

    // Load bbox only if all coordinates are present
    final x1 = prefs.getDouble(_bboxX1Key);
    final y1 = prefs.getDouble(_bboxY1Key);
    final x2 = prefs.getDouble(_bboxX2Key);
    final y2 = prefs.getDouble(_bboxY2Key);

    Rect? dropletBbox;
    if (x1 != null && y1 != null && x2 != null && y2 != null) {
      dropletBbox = Rect.fromLTRB(x1, y1, x2, y2);
    }

    // Load advanced settings
    final brightness = prefs.getInt(_brightnessKey);
    final contrast = prefs.getDouble(_contrastKey);
    final edgeSensitivity = prefs.getInt(_edgeSensitivityKey);
    final ellipseAngle = prefs.getDouble(_ellipseAngleKey);
    final ellipseScaleA = prefs.getDouble(_ellipseScaleAKey);
    final ellipseScaleB = prefs.getDouble(_ellipseScaleBKey);

    return {
      'useDefaults': true,
      'baselineOffsetY': baselineOffsetY,
      'dropletBbox': dropletBbox,
      'brightness': brightness,
      'contrast': contrast,
      'edgeSensitivity': edgeSensitivity,
      'ellipseAngle': ellipseAngle,
      'ellipseScaleA': ellipseScaleA,
      'ellipseScaleB': ellipseScaleB,
    };
  }

  /// Clear all saved calibration defaults.
  ///
  /// Resets the app to automatic detection mode.
  static Future<void> clearDefaults() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(_baselineOffsetKey);
    await prefs.remove(_bboxX1Key);
    await prefs.remove(_bboxY1Key);
    await prefs.remove(_bboxX2Key);
    await prefs.remove(_bboxY2Key);
    await prefs.setBool(_useDefaultsKey, false);
    
    // Clear advanced settings
    await prefs.remove(_brightnessKey);
    await prefs.remove(_contrastKey);
    await prefs.remove(_edgeSensitivityKey);
    await prefs.remove(_ellipseAngleKey);
    await prefs.remove(_ellipseScaleAKey);
    await prefs.remove(_ellipseScaleBKey);
  }

  /// Check if calibration defaults are currently saved.
  static Future<bool> hasDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_useDefaultsKey) ?? false;
  }
}

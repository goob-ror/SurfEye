import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:surfeye_app/config/app_config.dart';

class ApiService {
  // Shared client — reuse TCP connections across calls.
  static final http.Client _client = http.Client();

  /// POST /analyze — uploads [imagePath] and optionally a [baselineY] override
  /// and/or a [dropletBbox] for manual droplet region specification.
  /// Also supports advanced parameters for image preprocessing and ellipse fine-tuning.
  /// Returns the decoded JSON map or null on any error.
  static Future<Map<String, dynamic>?> analyzeImage(
    String imagePath, {
    int? baselineY,
    Rect? dropletBbox,
    int brightness = 0,
    double contrast = 1.0,
    int edgeSensitivity = 50,
    // Explicit ellipse params (pixel coords) — send when user has detected/dragged
    double? cx,
    double? cy,
    double? semiA,
    double? semiB,
    double? ellipseAngle,
    double? ellipseScaleA,
    double? ellipseScaleB,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(AppConfig.analyzeUrl),
      );

      request.files.add(
        await _createMultipartFile('file', imagePath),
      );

      if (baselineY != null) {
        request.fields['baseline_y'] = baselineY.toString();
      }

      // Add droplet bounding box coordinates if provided
      if (dropletBbox != null) {
        request.fields['droplet_x1'] = dropletBbox.left.toString();
        request.fields['droplet_y1'] = dropletBbox.top.toString();
        request.fields['droplet_x2'] = dropletBbox.right.toString();
        request.fields['droplet_y2'] = dropletBbox.bottom.toString();
      }

      // Add advanced preprocessing parameters
      request.fields['brightness'] = brightness.toString();
      request.fields['contrast'] = contrast.toString();
      request.fields['edge_sensitivity'] = edgeSensitivity.toString();

      // Send explicit ellipse if user has already detected / dragged handles
      if (cx != null)    request.fields['cx']     = cx.toString();
      if (cy != null)    request.fields['cy']     = cy.toString();
      if (semiA != null) request.fields['semi_a'] = semiA.toString();
      if (semiB != null) request.fields['semi_b'] = semiB.toString();

      // Add ellipse fine-tuning parameters if provided
      if (ellipseAngle != null) {
        request.fields['ellipse_angle'] = ellipseAngle.toString();
      }
      if (ellipseScaleA != null) {
        request.fields['ellipse_scale_a'] = ellipseScaleA.toString();
      }
      if (ellipseScaleB != null) {
        request.fields['ellipse_scale_b'] = ellipseScaleB.toString();
      }

      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 60));

      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        debugPrint(
            'ApiService.analyzeImage HTTP ${streamed.statusCode}: $body');
        return null;
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;

      // Rewrite relative image paths to full URLs so the app can display them.
      _rewriteImagePaths(decoded);

      return decoded;
    } on SocketException catch (e) {
      debugPrint('ApiService.analyzeImage network error: $e');
      return null;
    } catch (e) {
      debugPrint('ApiService.analyzeImage error: $e');
      return null;
    }
  }

  /// Lightweight pre-flight: uploads the image with no baseline override to
  /// get the server's auto-detected [detected_baseline_y] so the calibration
  /// screen can pre-position its yellow line.
  static Future<Map<String, dynamic>?> detectBaseline(
      String imagePath) async {
    // Reuse analyzeImage with no baselineY — the server always returns
    // detected_baseline_y in the response regardless of whether an override
    // was supplied.
    return analyzeImage(imagePath);
  }

  /// POST /detect — runs HoughCircles droplet detection and returns ellipse
  /// parameters [cx, cy, semi_a, semi_b, angle_deg] in image pixel coordinates,
  /// without performing full WCA analysis.
  /// Also accepts [baselineY], [brightness], [contrast], [edgeSensitivity] and
  /// an optional [dropletBbox] to constrain detection to a region.
  /// Returns map with keys: cx, cy, semi_a, semi_b, angle_deg, detected_baseline_y
  static Future<Map<String, dynamic>?> detectDroplet(
    String imagePath, {
    int? baselineY,
    Rect? dropletBbox,
    int brightness = 0,
    double contrast = 1.0,
    int edgeSensitivity = 50,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConfig.baseUrl}/detect'),
      );

      request.files.add(await _createMultipartFile('file', imagePath));

      if (baselineY != null) {
        request.fields['baseline_y'] = baselineY.toString();
      }
      if (dropletBbox != null) {
        request.fields['droplet_x1'] = dropletBbox.left.toString();
        request.fields['droplet_y1'] = dropletBbox.top.toString();
        request.fields['droplet_x2'] = dropletBbox.right.toString();
        request.fields['droplet_y2'] = dropletBbox.bottom.toString();
      }
      request.fields['brightness'] = brightness.toString();
      request.fields['contrast'] = contrast.toString();
      request.fields['edge_sensitivity'] = edgeSensitivity.toString();

      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));

      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        debugPrint('ApiService.detectDroplet HTTP ${streamed.statusCode}: $body');
        return null;
      }

      return jsonDecode(body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      debugPrint('ApiService.detectDroplet network error: $e');
      return null;
    } catch (e) {
      debugPrint('ApiService.detectDroplet error: $e');
      return null;
    }
  }

  /// POST /preview — generates a live preview of preprocessing effects
  /// without running full analysis. Shows edges overlay and baseline.
  /// Returns quickly for real-time feedback as settings change.
  static Future<Map<String, dynamic>?> getPreview(
    String imagePath, {
    int brightness = 0,
    double contrast = 1.0,
    int edgeSensitivity = 50,
    int sharpness = 0,
    int? baselineY,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AppConfig.baseUrl}/preview'),
      );

      request.files.add(
        await _createMultipartFile('file', imagePath),
      );

      // Add preprocessing parameters
      request.fields['brightness'] = brightness.toString();
      request.fields['contrast'] = contrast.toString();
      request.fields['edge_sensitivity'] = edgeSensitivity.toString();
      request.fields['sharpness'] = sharpness.toString();

      if (baselineY != null) {
        request.fields['baseline_y'] = baselineY.toString();
      }

      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));

      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        debugPrint('ApiService.getPreview HTTP ${streamed.statusCode}: $body');
        return null;
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;

      // Rewrite relative image paths to full URLs
      _rewriteImagePaths(decoded);

      return decoded;
    } on SocketException catch (e) {
      debugPrint('ApiService.getPreview network error: $e');
      return null;
    } catch (e) {
      debugPrint('ApiService.getPreview error: $e');
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static Future<http.MultipartFile> _createMultipartFile(String field, String path) async {
    if (kIsWeb) {
      final response = await http.get(Uri.parse(path));
      return http.MultipartFile.fromBytes(field, response.bodyBytes, filename: 'upload.png');
    } else {
      return await http.MultipartFile.fromPath(field, path);
    }
  }

  /// Converts server-relative paths like "/image/abc_edges.png" into full
  /// URLs using [AppConfig.baseUrl] so Image.network() / photo_view can
  /// load them directly.
  static void _rewriteImagePaths(Map<String, dynamic> result) {
    for (final key in ['edge_image_path', 'annotated_image_path', 'preview_image_path']) {
      final value = result[key];
      if (value is String && value.startsWith('/')) {
        result[key] = AppConfig.imageUrl(value);
      }
    }
  }
}
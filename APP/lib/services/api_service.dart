import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:surfeye_app/config/app_config.dart';

class ApiService {
  // Shared client — reuse TCP connections across calls.
  static final http.Client _client = http.Client();

  /// POST /analyze — uploads [imagePath] and optionally a [baselineY] override.
  /// Returns the decoded JSON map or null on any error.
  static Future<Map<String, dynamic>?> analyzeImage(
    String imagePath, {
    int? baselineY,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(AppConfig.analyzeUrl),
      );

      request.files.add(
        await http.MultipartFile.fromPath('file', imagePath),
      );

      if (baselineY != null) {
        request.fields['baseline_y'] = baselineY.toString();
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

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Converts server-relative paths like "/image/abc_edges.png" into full
  /// URLs using [AppConfig.baseUrl] so Image.network() / photo_view can
  /// load them directly.
  static void _rewriteImagePaths(Map<String, dynamic> result) {
    for (final key in ['edge_image_path', 'annotated_image_path']) {
      final value = result[key];
      if (value is String && value.startsWith('/')) {
        result[key] = AppConfig.imageUrl(value);
      }
    }
  }
}

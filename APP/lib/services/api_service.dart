import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ApiService {
  static const MethodChannel _pythonChannel = MethodChannel('com.surfeye/python');

  static Future<Map<String, dynamic>?> analyzeImage(String imagePath, {int? baselineY}) async {
    try {
      final args = <String, dynamic>{'imagePath': imagePath};
      if (baselineY != null) args['baselineY'] = baselineY;

      final dynamic result = await _pythonChannel.invokeMethod('analyzeDroplet', args);
      
      if (result != null) {
        if (result is String) {
          return jsonDecode(result) as Map<String, dynamic>;
        }
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      debugPrint('Exception during Python analysis: $e');
      return null;
    }
  }
}

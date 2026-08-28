/// Central configuration for the SurfEye app.
///
/// When starting the server, run:
/// ```
///   cd API && python server.py --token `<your_ngrok_token>`
/// ```
///
/// The terminal will print a line like:
///   Public URL : https://xxxx-xx-xx-xxx-xx.ngrok-free.app
///
/// Paste that URL (no trailing slash) into [baseUrl] below, then hot-restart.
class AppConfig {
  AppConfig._();

  /// Base URL of the SurfEye FastAPI server.
  /// Example: 'https://xxxx-xx-xx-xxx-xx.ngrok-free.app'
  static const String baseUrl = 'https://loraine-resistible-hans.ngrok-free.dev/';

  /// /analyze endpoint
  static String get analyzeUrl => '$baseUrl/analyze';

  /// /image/`<filename>` endpoint – prefix returned paths from the server with this
  static String imageUrl(String relPath) {
    // relPath already starts with /image/... as returned by the server
    return '$baseUrl$relPath';
  }
}

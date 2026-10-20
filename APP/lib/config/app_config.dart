/// Central configuration for the SurfEye app.
///
/// When starting the server, run:
/// ```
///   cd API && python server.py
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
  static const String baseUrl = 'https://gargle-thriving-fable.ngrok-free.dev';

  /// /analyze endpoint
  static String get analyzeUrl => '$baseUrl/analyze';

  /// /image/`<filename>` endpoint – prefix returned paths from the server with this
  static String imageUrl(String relPath) {
    // relPath already starts with /image/... as returned by the server
    return '$baseUrl$relPath';
  }

  /// Rebases a stored image reference onto the CURRENT [baseUrl].
  ///
  /// Measurements are persisted with whatever base URL was live at capture
  /// time, so rows saved before an ngrok restart keep pointing at a dead
  /// domain. Call this everywhere a stored path is read back for display.
  ///
  /// Accepts all three shapes that can end up in the DB / navigation extras:
  ///   - server-relative:  `/image/abc_annotated.webp`
  ///   - absolute stale:   `https://old-domain.ngrok-free.dev/image/abc.webp`
  ///   - local device file: `/data/user/0/.../abc.jpg`  (returned untouched)
  static String rebaseStoredPath(String? stored) {
    if (stored == null || stored.isEmpty) return '';

    // Server-relative path.
    if (stored.startsWith('/image/')) return imageUrl(stored);

    // Absolute (possibly stale) http(s) URL — swap the origin, keep the path.
    final uri = Uri.tryParse(stored);
    if (uri != null && uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final newBase = Uri.parse(baseUrl);
      return uri.replace(scheme: newBase.scheme, host: newBase.host, port: newBase.port).toString();
    }

    // Anything else is a local file path — leave it alone.
    return stored;
  }

  /// Inverse of [imageUrl]: strips the current [baseUrl] to recover the
  /// server-relative `/image/...` path, so newly-captured measurements are
  /// stored domain-agnostic and survive ngrok restarts.
  ///
  /// Values that don't start with [baseUrl] (e.g. local camera files) are
  /// returned unchanged.
  static String toRelativePath(String? absolute) {
    if (absolute == null || absolute.isEmpty) return '';
    if (absolute.startsWith(baseUrl)) {
      final tail = absolute.substring(baseUrl.length);
      return tail.startsWith('/') ? tail : '/$tail';
    }
    return absolute;
  }
}

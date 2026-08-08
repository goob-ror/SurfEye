class Measurement {
  final int id;
  final double angle;
  final String surface;
  final DateTime timestamp;
  final String? imagePath;

  const Measurement({
    required this.id,
    required this.angle,
    required this.surface,
    required this.timestamp,
    this.imagePath,
  });

  String get category {
    if (angle < 10) return 'Super-Hydrophilic';
    if (angle < 90) return 'Hydrophilic';
    if (angle < 150) return 'Hydrophobic';
    return 'Super-Hydrophobic';
  }

  String get description {
    if (angle < 10) return 'The surface exhibits extreme wettability. Water spreads almost completely flat.';
    if (angle < 90) return 'The surface is wettable. Water tends to spread and adhere to the surface.';
    if (angle < 150) return 'The surface repels water. Droplets bead up and can roll off easily.';
    return 'The surface exhibits extreme water repulsion, similar to a lotus leaf effect.';
  }

  String get timeAgo {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }
}

// ── Sample data (mirrors the web app's recentTests) ──────────────────────────
final List<Measurement> sampleMeasurements = [
  Measurement(
    id: 1,
    angle: 42.3,
    surface: 'Glass Slide',
    timestamp: DateTime.now().subtract(const Duration(hours: 2)),
  ),
  Measurement(
    id: 2,
    angle: 98.7,
    surface: 'Teflon Sheet',
    timestamp: DateTime.now().subtract(const Duration(days: 1)),
  ),
  Measurement(
    id: 3,
    angle: 15.1,
    surface: 'Plasma Treated',
    timestamp: DateTime.now().subtract(const Duration(days: 2)),
  ),
];

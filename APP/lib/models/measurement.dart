class Measurement {
  final int id;
  final double angle;
  final String surface;
  final DateTime timestamp;
  final String? imagePath;
  // Optional richer fields from Young-Laplace analysis
  final double? leftAngle;
  final double? rightAngle;
  final double? bondNumber;
  final String? method;
  final double? dropletWidthPx;
  final double? dropletHeightPx;
  final double? fitResidualRms;

  const Measurement({
    required this.id,
    required this.angle,
    required this.surface,
    required this.timestamp,
    this.imagePath,
    this.leftAngle,
    this.rightAngle,
    this.bondNumber,
    this.method,
    this.dropletWidthPx,
    this.dropletHeightPx,
    this.fitResidualRms,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'angle': angle,
      'surface': surface,
      'timestamp': timestamp.toIso8601String(),
      'imagePath': imagePath,
      'leftAngle': leftAngle,
      'rightAngle': rightAngle,
      'bondNumber': bondNumber,
      'method': method,
      'dropletWidthPx': dropletWidthPx,
      'dropletHeightPx': dropletHeightPx,
      'fitResidualRms': fitResidualRms,
    };
  }

  factory Measurement.fromMap(Map<String, dynamic> map) {
    return Measurement(
      id: map['id'] as int,
      angle: (map['angle'] as num).toDouble(),
      surface: map['surface'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      imagePath: map['imagePath'] as String?,
      leftAngle: (map['leftAngle'] as num?)?.toDouble(),
      rightAngle: (map['rightAngle'] as num?)?.toDouble(),
      bondNumber: (map['bondNumber'] as num?)?.toDouble(),
      method: map['method'] as String?,
      dropletWidthPx: (map['dropletWidthPx'] as num?)?.toDouble(),
      dropletHeightPx: (map['dropletHeightPx'] as num?)?.toDouble(),
      fitResidualRms: (map['fitResidualRms'] as num?)?.toDouble(),
    );
  }

  String get category {
    if (angle < 10) return 'Super-Hidrofilik';
    if (angle < 90) return 'Hidrofilik';
    if (angle < 150) return 'Hidrofobik';
    return 'Super-Hidrofobik';
  }

  String get description {
    if (angle < 10) return 'Permukaan menunjukkan kebasahan ekstrem. Air menyebar hampir sepenuhnya rata.';
    if (angle < 90) return 'Permukaan dapat basah. Air cenderung menyebar dan menempel pada permukaan.';
    if (angle < 150) return 'Permukaan menolak air. Tetesan membentuk butiran dan dapat menggelinding dengan mudah.';
    return 'Permukaan menunjukkan penolakan air yang ekstrem, mirip dengan efek daun teratai.';
  }

  String get timeAgo {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m lalu';
    if (diff.inHours < 24) return '${diff.inHours}j lalu';
    if (diff.inDays == 1) return 'Kemarin';
    return '${diff.inDays} hari lalu';
  }

  /// Format angle as XXX.YY (max 3 digits before decimal, 2 after)
  String get formattedAngle => angle.toStringAsFixed(2);
}

// Sample data
final List<Measurement> sampleMeasurements = [
  Measurement(
    id: 1,
    angle: 42.30,
    surface: 'Glass Slide',
    timestamp: DateTime.now().subtract(const Duration(hours: 2)),
  ),
  Measurement(
    id: 2,
    angle: 98.70,
    surface: 'Teflon Sheet',
    timestamp: DateTime.now().subtract(const Duration(days: 1)),
  ),
  Measurement(
    id: 3,
    angle: 15.10,
    surface: 'Plasma Treated',
    timestamp: DateTime.now().subtract(const Duration(days: 2)),
  ),
];

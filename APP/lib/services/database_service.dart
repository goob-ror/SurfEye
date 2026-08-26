import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/measurement.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('measurements.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 2, onCreate: _createDB, onUpgrade: _upgradeDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
CREATE TABLE measurements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  angle REAL NOT NULL,
  surface TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  imagePath TEXT,
  leftAngle REAL,
  rightAngle REAL,
  bondNumber REAL,
  method TEXT,
  dropletWidthPx REAL,
  dropletHeightPx REAL,
  fitResidualRms REAL
)
''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE measurements ADD COLUMN leftAngle REAL');
      await db.execute('ALTER TABLE measurements ADD COLUMN rightAngle REAL');
      await db.execute('ALTER TABLE measurements ADD COLUMN bondNumber REAL');
      await db.execute('ALTER TABLE measurements ADD COLUMN method TEXT');
      await db.execute('ALTER TABLE measurements ADD COLUMN dropletWidthPx REAL');
      await db.execute('ALTER TABLE measurements ADD COLUMN dropletHeightPx REAL');
      await db.execute('ALTER TABLE measurements ADD COLUMN fitResidualRms REAL');
    }
  }

  Future<Measurement> insertMeasurement(Measurement measurement) async {
    final db = await instance.database;
    final map = measurement.toMap();
    map.remove('id');
    final id = await db.insert('measurements', map);
    return Measurement(
      id: id,
      angle: measurement.angle,
      surface: measurement.surface,
      timestamp: measurement.timestamp,
      imagePath: measurement.imagePath,
      leftAngle: measurement.leftAngle,
      rightAngle: measurement.rightAngle,
      bondNumber: measurement.bondNumber,
      method: measurement.method,
      dropletWidthPx: measurement.dropletWidthPx,
      dropletHeightPx: measurement.dropletHeightPx,
      fitResidualRms: measurement.fitResidualRms,
    );
  }

  Future<List<Measurement>> getMeasurements() async {
    final db = await instance.database;
    final result = await db.query('measurements', orderBy: 'timestamp DESC');
    return result.map((json) => Measurement.fromMap(json)).toList();
  }

  Future<Measurement?> getMeasurementById(int id) async {
    final db = await instance.database;
    final result = await db.query('measurements', where: 'id = ?', whereArgs: [id], limit: 1);
    if (result.isEmpty) return null;
    return Measurement.fromMap(result.first);
  }
}

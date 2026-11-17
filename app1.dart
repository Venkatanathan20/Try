import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UVMonitorAppV2());
}

class UVMonitorAppV2 extends StatefulWidget {
  const UVMonitorAppV2({super.key});

  @override
  State<UVMonitorAppV2> createState() => _UVMonitorAppV2State();
}

class _UVMonitorAppV2State extends State<UVMonitorAppV2> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          (_themeMode == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Google Weather Style UV Hub V2',
      themeMode: _themeMode,
      theme: ThemeData.light(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0077B6),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF111318),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8AB4F8),
          brightness: Brightness.dark,
        ),
      ),
      home: UVMonitorScreenV2(
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

// ================= 0-3.3V (0-3300mV) PIECEWISE CALIBRATION ENGINE =================
class GuvaCalibrationEngine {
  static const List<double> mvThresholds = <double>[
    128.0, 582.0, 815.0, 1046.0, 1290.0, 1554.0,
    1785.0, 2038.0, 2259.0, 2503.0, 2767.0, 3000.0
  ];

  static int lookupDiscreteUVI(double mv) {
    final double clamped = mv.clamp(0.0, 3300.0);
    if (clamped < 128.0) return 0;
    for (int uvi = 11; uvi >= 1; uvi--) {
      if (clamped >= mvThresholds[uvi]) return uvi;
    }
    return 0;
  }

  static double calculateCalibratedUVI(double mv) {
    final double clamped = mv.clamp(0.0, 3300.0);
    if (clamped < 128.0) return 0.0;
    if (clamped >= 3000.0) {
      return (11.0 + (clamped - 3000.0) / 233.0).clamp(0.0, 12.0);
    }
    for (int i = 0; i < 11; i++) {
      final double vLow = mvThresholds[i];
      final double vHigh = mvThresholds[i + 1];
      if (clamped >= vLow && clamped <= vHigh) {
        return i + (mv - vLow) / (vHigh - vLow);
      }
    }
    return 0.0;
  }

  static double calculateOldLinearUVI(double mv) =>
      mv.clamp(0.0, 3300.0) / 256.4;

  static String getRiskCategory(double uvi) {
    if (uvi < 3.0) return 'Low';
    if (uvi < 6.0) return 'Moderate';
    if (uvi < 8.0) return 'High';
    if (uvi < 11.0) return 'Very High';
    return 'Extreme';
  }
}

// ================= TELEMETRY RECORD MODEL (3 FILTERS, 0-3300mV) =================
class UVRecord {
  final DateTime timestamp;
  final double mvRaw;
  final double mvMedian;
  final double mvKalman;
  final double mvHybrid;
  final double uviCalibrated;
  final double uviLinearOld;
  final int uviLookupInt;
  final String riskCategory;
  final int rssi;

  UVRecord({
    required this.timestamp,
    required this.mvRaw,
    required this.mvMedian,
    required this.mvKalman,
    required this.mvHybrid,
    required this.uviCalibrated,
    required this.uviLinearOld,
    required this.uviLookupInt,
    required this.riskCategory,
    required this.rssi,
  });

  double getMvByFilter(String filterName) {
    switch (filterName) {
      case 'Median Filter':
        return mvMedian.clamp(0.0, 3300.0);
      case '1D Kalman Filter':
        return mvKalman.clamp(0.0, 3300.0);
      case 'Hybrid (Median+Kalman)':
      default:
        return mvHybrid.clamp(0.0, 3300.0);
    }
  }

  double getUviByFilter(String filterName) {
    return GuvaCalibrationEngine.calculateCalibratedUVI(
        getMvByFilter(filterName));
  }

  double get uviRaw =>
      GuvaCalibrationEngine.calculateCalibratedUVI(mvRaw.clamp(0.0, 3300.0));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': timestamp.toIso8601String(),
        'raw': mvRaw.clamp(0.0, 3300.0),
        'med': mvMedian.clamp(0.0, 3300.0),
        'kal': mvKalman.clamp(0.0, 3300.0),
        'hyb': mvHybrid.clamp(0.0, 3300.0),
        'uvi_cal': uviCalibrated,
        'uvi_lin': uviLinearOld,
        'uvi_int': uviLookupInt,
        'risk': riskCategory,
        'rssi': rssi,
      };

  factory UVRecord.fromJson(Map<String, dynamic> json) {
    final double hyb =
        (((json['hyb'] ?? json['kal'] ?? json['mv'] ?? 0.0) as num).toDouble())
            .clamp(0.0, 3300.0);
    final double raw =
        (((json['raw'] ?? hyb) as num).toDouble()).clamp(0.0, 3300.0);
    final double med =
        (((json['med'] ?? hyb) as num).toDouble()).clamp(0.0, 3300.0);
    final double kal =
        (((json['kal'] ?? hyb) as num).toDouble()).clamp(0.0, 3300.0);
    final double uviCal = GuvaCalibrationEngine.calculateCalibratedUVI(hyb);
    return UVRecord(
      timestamp: DateTime.parse(json['ts'].toString()).toLocal(),
      mvRaw: raw,
      mvMedian: med,
      mvKalman: kal,
      mvHybrid: hyb,
      uviCalibrated: uviCal,
      uviLinearOld: GuvaCalibrationEngine.calculateOldLinearUVI(hyb),
      uviLookupInt: GuvaCalibrationEngine.lookupDiscreteUVI(hyb),
      riskCategory: GuvaCalibrationEngine.getRiskCategory(uviCal),
      rssi: ((json['rssi'] ?? 0) as num).toInt(),
    );
  }
}

class _ChartBucketPoint {
  final DateTime timestamp;
  final String label;
  final double uviFiltered;
  final double uviRaw;
  final double mvFiltered;
  final double mvRaw;

  _ChartBucketPoint({
    required this.timestamp,
    required this.label,
    required this.uviFiltered,
    required this.uviRaw,
    required this.mvFiltered,
    required this.mvRaw,
  });
}

class HourlyBucketStat {
  final int hour;
  final String timeSlot;
  final double peakUvi;
  final double avgMv;
  final int count;
  final String risk;

  HourlyBucketStat({
    required this.hour,
    required this.timeSlot,
    required this.peakUvi,
    required this.avgMv,
    required this.count,
    required this.risk,
  });
}

class GranularTelemetryRow {
  final String time;
  final String uvData;
  final String voltage;

  GranularTelemetryRow({
    required this.time,
    required this.uvData,
    required this.voltage,
  });
}

// ================= GOOGLE WEATHER SEMI-CIRCULAR ARC GAUGE PAINTER =================
class GoogleWeatherUvArcPainter extends CustomPainter {
  final double uvi;
  final bool isDarkMode;

  GoogleWeatherUvArcPainter({required this.uvi, required this.isDarkMode});

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2 + 6);
    final double radius = min(size.width, size.height) / 2 - 8;
    const double startAngle = 0.75 * pi;
    const double sweepAngle = 1.5 * pi;

    final Rect arcRect = Rect.fromCircle(center: center, radius: radius);

    final Paint bgPaint = Paint()
      ..color = isDarkMode ? Colors.white12 : Colors.black12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, startAngle, sweepAngle, false, bgPaint);

    final Shader gradientShader = const SweepGradient(
      startAngle: 0.0,
      endAngle: 2 * pi,
      colors: <Color>[
        Color(0xFF4CAF50),
        Color(0xFFFFEB3B),
        Color(0xFFFF9800),
        Color(0xFFF44336),
        Color(0xFF9C27B0),
        Color(0xFF4CAF50),
      ],
      stops: <double>[0.0, 0.25, 0.45, 0.65, 0.85, 1.0],
      transform: GradientRotation(0.75 * pi),
    ).createShader(arcRect);

    final Paint fgPaint = Paint()
      ..shader = gradientShader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final double normalized = (uvi.clamp(0.0, 12.0)) / 12.0;
    canvas.drawArc(
        arcRect, startAngle, sweepAngle * max(0.02, normalized), false, fgPaint);

    final double thumbAngle = startAngle + sweepAngle * normalized;
    final Offset thumbCenter = Offset(
      center.dx + radius * cos(thumbAngle),
      center.dy + radius * sin(thumbAngle),
    );

    canvas.drawCircle(
      thumbCenter,
      6.5,
      Paint()..color = isDarkMode ? Colors.white : Colors.black87,
    );
  }

  @override
  bool shouldRepaint(covariant GoogleWeatherUvArcPainter oldDelegate) =>
      oldDelegate.uvi != uvi || oldDelegate.isDarkMode != isDarkMode;
}

class UVMonitorScreenV2 extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const UVMonitorScreenV2({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<UVMonitorScreenV2> createState() => _UVMonitorScreenV2State();
}

class _UVMonitorScreenV2State extends State<UVMonitorScreenV2> {
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.0.117');

  static const String _influxBaseUrl =
      'https://us-east-1-1.aws.cloud2.influxdata.com';
  static const String _influxOrg = 'IOT';
  static const String _influxBucket = 'uv_sensor_data';
  static const String _influxToken =
      'Dbzt7IHP3G4E4McgOmsRBrZLUaK2fsEgexNVFzYSQI1V2PhqWbL6SFhB64Vg-jOY6HQIu7BibH8jkSQvHqLNWw==';

  static const String _mqttBroker = 'broker.hivemq.com';
  static const String _mqttTopic = 'venkat_iot/sensors/uv/node_01';

  Timer? _pollTimer;
  Timer? _influxSyncTimer;
  MqttServerClient? _mqttClient;

  bool _isConnected = true;
  bool _isMqttCloudConnected = false;
  bool _isInfluxCloudConnected = false;
  bool _isSimulating = false;
  String _status = 'Syncing via HiveMQ, InfluxDB & Local HTTP...';
  final int _selectedPollSeconds = 3;

  String _selectedFilter = 'Hybrid (Median+Kalman)';
  bool _overlayRawOnChart = true;
  final List<String> _filterOptions = <String>[
    'Hybrid (Median+Kalman)',
    '1D Kalman Filter',
    'Median Filter',
  ];

  final List<double> _winBuf = <double>[];
  double _kalX = 0.0, _kalP = 1.0;
  double _hybX = 0.0, _hybP = 1.0;

  UVRecord? _latestRecord;
  int _packetCount = 0;

  final List<UVRecord> _liveRecords = <UVRecord>[];
  List<UVRecord> _allHistoryRecords = <UVRecord>[];

  String _periodMode = 'Date';
  int _selectedYear = DateTime.now().year;
  int _selectedMonth = DateTime.now().month;
  int _selectedWeek = ((DateTime.now().day - 1) ~/ 7) + 1;
  int _selectedDay = DateTime.now().day;

  String _graphGranularity = 'Minutes';
  String _timeGranularity = 'Seconds';

  static const List<String> _monthNames = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedHistory();
    _startAlwaysOnSync();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _influxSyncTimer?.cancel();
    _mqttClient?.disconnect();
    _ipController.dispose();
    super.dispose();
  }

  void _startAlwaysOnSync() {
    _connectHiveMqCloud();
    _syncFromInfluxDbCloud();
    _fetchLocalHttp();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: _selectedPollSeconds),
      (_) {
        if (_isConnected && !_isSimulating) {
          _fetchLocalHttp();
        }
      },
    );

    _influxSyncTimer?.cancel();
    _influxSyncTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) {
        if (_isConnected && !_isSimulating) {
          _syncFromInfluxDbCloud();
        }
      },
    );
  }

  Future<void> _loadSavedHistory() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? savedJson =
        prefs.getStringList('uv_history_logs_v5_clean');
    if (savedJson != null && savedJson.isNotEmpty) {
      final List<UVRecord> loaded = savedJson
          .map((String str) =>
              UVRecord.fromJson(jsonDecode(str) as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _allHistoryRecords = loaded;
        _liveRecords
          ..clear()
          ..addAll(loaded.length > 60
              ? loaded.sublist(loaded.length - 60)
              : loaded);
        _latestRecord = loaded.last;
      });
    }
  }

  Future<void> _saveRecordToHistory(UVRecord record) async {
    final bool exists = _allHistoryRecords.any((UVRecord r) =>
        (r.timestamp.difference(record.timestamp).inSeconds).abs() < 1);
    if (!exists) {
      _allHistoryRecords.add(record);
      _allHistoryRecords.sort(
          (UVRecord a, UVRecord b) => a.timestamp.compareTo(b.timestamp));
      if (_allHistoryRecords.length > 8000) {
        _allHistoryRecords.removeRange(0, _allHistoryRecords.length - 8000);
      }
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> encoded = _allHistoryRecords
          .map((UVRecord r) => jsonEncode(r.toJson()))
          .toList();
      await prefs.setStringList('uv_history_logs_v5_clean', encoded);
    }
  }

  Future<void> _connectHiveMqCloud() async {
    final String clientId = 'flutter_uv_v2_${Random().nextInt(999999)}';
    _mqttClient = MqttServerClient.withPort(_mqttBroker, clientId, 1883);
    _mqttClient!.keepAlivePeriod = 30;
    _mqttClient!.autoReconnect = true;
    _mqttClient!.onConnected = () {
      if (mounted) setState(() => _isMqttCloudConnected = true);
      _mqttClient!.subscribe(_mqttTopic, MqttQos.atMostOnce);
    };
    _mqttClient!.onDisconnected = () {
      if (mounted) setState(() => _isMqttCloudConnected = false);
    };

    try {
      await _mqttClient!.connect();
      _mqttClient!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        if (!_isConnected || _isSimulating) return;
        final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
        final String payload =
            MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        _parseIncomingJson(payload, source: 'HiveMQ Cloud');
      });
    } catch (_) {
      if (mounted) setState(() => _isMqttCloudConnected = false);
    }
  }

  Future<void> _syncFromInfluxDbCloud() async {
    try {
      const String fluxQuery = '''
from(bucket: "$_influxBucket")
  |> range(start: -24h)
  |> filter(fn: (r) => r["_measurement"] == "uv_measurement")
  |> filter(fn: (r) => r["_field"] == "voltage_raw_mv" or r["_field"] == "voltage_median_mv" or r["_field"] == "voltage_kalman_mv" or r["_field"] == "voltage_hybrid_mv" or r["_field"] == "uv_index_estimated")
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"], desc: false)
  |> tail(n: 120)
''';

      final Uri uri =
          Uri.parse('$_influxBaseUrl/api/v2/query?org=$_influxOrg');
      final http.Response response = await http
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Token $_influxToken',
              'Content-Type': 'application/vnd.flux',
              'Accept': 'application/csv',
            },
            body: fluxQuery,
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 && response.body.trim().isNotEmpty) {
        if (mounted) setState(() => _isInfluxCloudConnected = true);
        _parseInfluxCsvResponse(response.body);
      }
    } catch (_) {
      if (mounted) setState(() => _isInfluxCloudConnected = false);
    }
  }

  void _parseInfluxCsvResponse(String csvBody) {
    final List<String> lines = const LineSplitter().convert(csvBody);
    if (lines.length < 2) return;

    List<String>? headers;
    int newPointsAdded = 0;
    UVRecord? newestFromDb;

    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final List<String> cols = line.split(',');
      if (cols.contains('_time') && cols.contains('voltage_hybrid_mv')) {
        headers = cols;
        continue;
      }
      if (headers == null || cols.length < headers.length) continue;

      final Map<String, String> rowMap = <String, String>{};
      for (int i = 0; i < headers.length; i++) {
        rowMap[headers[i]] = cols[i];
      }

      final DateTime? ts = DateTime.tryParse(rowMap['_time'] ?? '')?.toLocal();
      if (ts == null) continue;

      final double raw =
          (double.tryParse(rowMap['voltage_raw_mv'] ?? '') ?? 0.0)
              .clamp(0.0, 3300.0);
      final double med =
          (double.tryParse(rowMap['voltage_median_mv'] ?? '') ?? raw)
              .clamp(0.0, 3300.0);
      final double kal =
          (double.tryParse(rowMap['voltage_kalman_mv'] ?? '') ?? raw)
              .clamp(0.0, 3300.0);
      final double hyb =
          (double.tryParse(rowMap['voltage_hybrid_mv'] ?? '') ?? raw)
              .clamp(0.0, 3300.0);
      final double uviEst = GuvaCalibrationEngine.calculateCalibratedUVI(hyb);

      final UVRecord rec = UVRecord(
        timestamp: ts,
        mvRaw: raw,
        mvMedian: med,
        mvKalman: kal,
        mvHybrid: hyb,
        uviCalibrated: uviEst,
        uviLinearOld: GuvaCalibrationEngine.calculateOldLinearUVI(hyb),
        uviLookupInt: GuvaCalibrationEngine.lookupDiscreteUVI(hyb),
        riskCategory: GuvaCalibrationEngine.getRiskCategory(uviEst),
        rssi: 0,
      );

      final bool alreadyExists = _allHistoryRecords.any((UVRecord r) =>
          (r.timestamp.difference(rec.timestamp).inSeconds).abs() < 2);
      if (!alreadyExists) {
        _allHistoryRecords.add(rec);
        newPointsAdded++;
      }
      newestFromDb = rec;
    }

    if (newPointsAdded > 0 || (_latestRecord == null && newestFromDb != null)) {
      _allHistoryRecords
          .sort((UVRecord a, UVRecord b) => a.timestamp.compareTo(b.timestamp));
      if (!mounted) return;
      setState(() {
        if (newestFromDb != null) {
          _latestRecord = newestFromDb;
        }
        _liveRecords
          ..clear()
          ..addAll(_allHistoryRecords.length > 60
              ? _allHistoryRecords.sublist(_allHistoryRecords.length - 60)
              : _allHistoryRecords);
        _packetCount += newPointsAdded;
        _status = 'InfluxDB + HiveMQ Synced • #$_packetCount';
      });
    }
  }

  void _toggleConnection() {
    setState(() {
      _isSimulating = false;
      _isConnected = !_isConnected;
    });

    if (_isConnected) {
      setState(() => _status = 'Syncing via HiveMQ, InfluxDB & Local HTTP...');
      _startAlwaysOnSync();
    } else {
      _pollTimer?.cancel();
      _influxSyncTimer?.cancel();
      setState(() => _status = 'Telemetry Paused');
    }
  }

  Future<void> _fetchLocalHttp() async {
    final String ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    try {
      final http.Response response = await http
          .get(Uri.parse('http://$ip/data'))
          .timeout(const Duration(milliseconds: 1800));

      if (response.statusCode == 200) {
        _parseIncomingJson(response.body, source: 'Local Wi-Fi ($ip)');
      }
    } catch (_) {}
  }

  void _parseIncomingJson(String body, {required String source}) {
    try {
      final Map<String, dynamic> data =
          jsonDecode(body) as Map<String, dynamic>;
      double raw = double.tryParse(
              (data['mv_raw'] ?? data['sensor_mv'] ?? '0').toString()) ??
          0.0;
      if (raw < 128.0) raw = 0.0;
      raw = raw.clamp(0.0, 3300.0);

      final int rssi = int.tryParse((data['rssi_dbm'] ?? '0').toString()) ?? 0;

      if (data.containsKey('mv_hybrid')) {
        final double med =
            (double.tryParse(data['mv_median'].toString()) ?? raw)
                .clamp(0.0, 3300.0);
        final double kal =
            (double.tryParse(data['mv_kalman'].toString()) ?? raw)
                .clamp(0.0, 3300.0);
        final double hyb =
            (double.tryParse(data['mv_hybrid'].toString()) ?? raw)
                .clamp(0.0, 3300.0);
        _recordSample(raw, med, kal, hyb, rssi, source: source);
      } else {
        _compute3FiltersLocallyAndRecord(raw, rssi, source: source);
      }
    } catch (_) {}
  }

  void _compute3FiltersLocallyAndRecord(double raw, int rssi,
      {required String source}) {
    final double clampedRaw = (raw < 128.0) ? 0.0 : raw.clamp(0.0, 3300.0);
    _winBuf.add(clampedRaw);
    if (_winBuf.length > 9) _winBuf.removeAt(0);

    final List<double> sorted = List<double>.from(_winBuf)..sort();
    final double med = sorted[sorted.length ~/ 2].clamp(0.0, 3300.0);

    if (_packetCount == 0) _kalX = clampedRaw;
    _kalP += 0.05;
    final double kG = _kalP / (_kalP + 2.5);
    _kalX = (_kalX + kG * (clampedRaw - _kalX)).clamp(0.0, 3300.0);
    _kalP = (1.0 - kG) * _kalP;

    if (_packetCount == 0) _hybX = med;
    _hybP += 0.05;
    final double hG = _hybP / (_hybP + 1.5);
    _hybX = (_hybX + hG * (med - _hybX)).clamp(0.0, 3300.0);
    _hybP = (1.0 - hG) * _hybP;

    _recordSample(clampedRaw, med, _kalX, _hybX, rssi, source: source);
  }

  void _recordSample(
    double raw,
    double med,
    double kal,
    double hyb,
    int rssi, {
    required String source,
  }) {
    if (!mounted) return;

    final double cleanRaw = raw.clamp(0.0, 3300.0);
    final double cleanMed = med.clamp(0.0, 3300.0);
    final double cleanKal = kal.clamp(0.0, 3300.0);
    final double cleanHyb = hyb.clamp(0.0, 3300.0);

    final double uviCal =
        GuvaCalibrationEngine.calculateCalibratedUVI(cleanHyb);
    final double uviLin = GuvaCalibrationEngine.calculateOldLinearUVI(cleanHyb);
    final int uviInt = GuvaCalibrationEngine.lookupDiscreteUVI(cleanHyb);
    final String risk = GuvaCalibrationEngine.getRiskCategory(uviCal);

    final UVRecord rec = UVRecord(
      timestamp: DateTime.now(),
      mvRaw: cleanRaw,
      mvMedian: cleanMed,
      mvKalman: cleanKal,
      mvHybrid: cleanHyb,
      uviCalibrated: uviCal,
      uviLinearOld: uviLin,
      uviLookupInt: uviInt,
      riskCategory: risk,
      rssi: rssi,
    );

    setState(() {
      _latestRecord = rec;
      _packetCount++;
      _status = '$source • #$_packetCount';
      _liveRecords.add(rec);
      if (_liveRecords.length > 60) _liveRecords.removeAt(0);
    });

    _saveRecordToHistory(rec);
  }

  void _toggleDemoStream() {
    _pollTimer?.cancel();
    setState(() {
      _isConnected = false;
      _isSimulating = !_isSimulating;
      if (_isSimulating) {
        _generateDemoPoint();
        _pollTimer = Timer.periodic(
          Duration(seconds: _selectedPollSeconds),
          (_) => _generateDemoPoint(),
        );
      } else {
        _status = 'Demo Stopped';
      }
    });
  }

  void _generateDemoPoint() {
    final Random rng = Random();
    final double phase = (_packetCount % 24) / 24.0 * pi;
    final double solarBell = sin(phase) * 2450.0;
    final double whiteNoise = (rng.nextDouble() - 0.5) * 90.0;
    final double wifiSpike = (rng.nextInt(5) == 0) ? 450.0 : 0.0;
    final double raw = (solarBell + whiteNoise + wifiSpike).clamp(0.0, 3300.0);
    _compute3FiltersLocallyAndRecord(raw, -49, source: 'WHO Curve Demo');
  }

  Future<void> _showPhoneStyleWiFiDialog() async {
    final TextEditingController ssidCtrl = TextEditingController();
    final TextEditingController passCtrl = TextEditingController();
    final TextEditingController influxUrlCtrl = TextEditingController();
    final TextEditingController influxTokCtrl = TextEditingController();

    List> scannedNetworks = >[];
    bool isScanning = false;
    bool obscurePass = true;

    Future<void> scanNetworks(StateSetter setModalState) async {
      setModalState(() => isScanning = true);
      final String targetIp = _ipController.text.trim().isEmpty
          ? '192.168.4.1'
          : _ipController.text.trim();
      try {
        final http.Response res = await http
            .get(Uri.parse('http://$targetIp/scan'))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final Map<String, dynamic> decoded =
              jsonDecode(res.body) as Map<String, dynamic>;
          final List<dynamic> nets =
              (decoded['networks'] as List<dynamic>?) ?? <dynamic>[];
          setModalState(() {
            scannedNetworks = nets
                .map((dynamic e) => Map<String, dynamic>.from(e as Map))
                .toList();
          });
        }
      } catch (_) {}
      setModalState(() => isScanning = false);
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Icon(Icons.wifi_find_rounded, color: Color(0xFF00B4D8)),
                      SizedBox(width: 8),
                      Text('Configure ESP32 Wi-Fi',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  IconButton(
                    icon: isScanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    tooltip: 'Scan Nearby Wi-Fi Networks via ESP32',
                    onPressed: () => scanNetworks(setModalState),
                  ),
                ],
              ),
              content: SizedBox(
                width: 340,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Tip: Connect phone to "ESP32_UV_WiFi_Setup" AP (IP 192.168.4.1) if changing networks.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 10),
                      if (scannedNetworks.isNotEmpty) ...<Widget>[
                        const Text('Available Networks Found by ESP32:',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Container(
                          height: 120,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white24),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListView.builder(
                            itemCount: scannedNetworks.length,
                            itemBuilder: (BuildContext c, int i) {
                              final Map<String, dynamic> net =
                                  scannedNetworks[i];
                              final String ssid =
                                  (net['ssid'] ?? '').toString();
                              final int rssi =
                                  int.tryParse((net['rssi'] ?? '0').toString()) ??
                                      -70;
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.wifi_rounded,
                                    size: 18, color: Color(0xFF00B4D8)),
                                title: Text(ssid,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                                trailing: Text('$rssi dBm',
                                    style: const TextStyle(fontSize: 10)),
                                onTap: () =>
                                    setModalState(() => ssidCtrl.text = ssid),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      TextField(
                        controller: ssidCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Wi-Fi / Hotspot Name (SSID)',
                          prefixIcon: Icon(Icons.wifi_rounded),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: passCtrl,
                        obscureText: obscurePass,
                        decoration: InputDecoration(
                          labelText: 'Wi-Fi Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(obscurePass
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setModalState(
                                () => obscurePass = !obscurePass),
                          ),
                          isDense: true,
                        ),
                      ),
                      const Divider(height: 24),
                      const Text('Optional InfluxDB Cloud Override:',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: influxUrlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'InfluxDB Write URL',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: influxTokCtrl,
                        decoration: const InputDecoration(
                          labelText: 'InfluxDB API Token',
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Connect ESP32'),
                  onPressed: () async {
                    final String targetIp = _ipController.text.trim().isEmpty
                        ? '192.168.4.1'
                        : _ipController.text.trim();
                    try {
                      await http
                          .post(
                            Uri.parse('http://$targetIp/wifi'),
                            body: <String, String>{
                              'ssid': ssidCtrl.text.trim(),
                              'pass': passCtrl.text.trim(),
                              'influx_url': influxUrlCtrl.text.trim(),
                              'influx_token': influxTokCtrl.text.trim(),
                            },
                          )
                          .timeout(const Duration(seconds: 4));
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Saved! ESP32 is reconnecting & syncing via HiveMQ Cloud.')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('ESP32 Wi-Fi Config Sent ($e)')),
                        );
                      }
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  double _calcFilterStdDev(String filterName) {
    if (_liveRecords.length < 3) return 0.0;
    final List<double> vals =
        _liveRecords.map((UVRecord r) => r.getMvByFilter(filterName)).toList();
    final List<double> diffs = <double>[];
    for (int i = 1; i < vals.length; i++) {
      diffs.add(vals[i] - vals[i - 1]);
    }
    final double mean =
        diffs.reduce((double a, double b) => a + b) / diffs.length;
    final double variance = diffs
            .map((double d) => pow(d - mean, 2).toDouble())
            .reduce((double a, double b) => a + b) /
        diffs.length;
    return sqrt(variance);
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  List<UVRecord> _getFilteredRecords() {
    return _allHistoryRecords.where((UVRecord r) {
      final DateTime ts = r.timestamp;
      if (_periodMode == 'Year') {
        return ts.year == _selectedYear;
      } else if (_periodMode == 'Month') {
        return ts.year == _selectedYear && ts.month == _selectedMonth;
      } else if (_periodMode == 'Week') {
        final int wk = ((ts.day - 1) ~/ 7) + 1;
        return ts.year == _selectedYear &&
            ts.month == _selectedMonth &&
            wk == _selectedWeek;
      } else {
        return ts.year == _selectedYear &&
            ts.month == _selectedMonth &&
            ts.day == _selectedDay;
      }
    }).toList();
  }

  List<_ChartBucketPoint> _getAggregatedChartPoints() {
    final List<UVRecord> source = _getFilteredRecords().isNotEmpty
        ? _getFilteredRecords()
        : _liveRecords;
    if (source.isEmpty) return <_ChartBucketPoint>[];

    final Map<String, List<UVRecord>> grouped = <String, List<UVRecord>>{};
    for (final UVRecord r in source) {
      String key;
      if (_graphGranularity == 'Seconds') {
        key = DateFormat('HH:mm:ss').format(r.timestamp);
      } else if (_graphGranularity == 'Minutes') {
        key = DateFormat('HH:mm').format(r.timestamp);
      } else if (_graphGranularity == 'Hours') {
        key = DateFormat('MM-dd HH:00').format(r.timestamp);
      } else if (_graphGranularity == 'Days') {
        key = DateFormat('MM-dd').format(r.timestamp);
      } else {
        key = DateFormat('yyyy-MM').format(r.timestamp);
      }
      grouped.putIfAbsent(key, () => <UVRecord>[]).add(r);
    }

    final List<_ChartBucketPoint> points = <_ChartBucketPoint>[];
    grouped.forEach((String label, List<UVRecord> recs) {
      final double avgFiltMv = (recs
                  .map((UVRecord e) => e.getMvByFilter(_selectedFilter))
                  .reduce((double a, double b) => a + b) /
              recs.length)
          .clamp(0.0, 3300.0);
      final double avgRawMv = (recs
                  .map((UVRecord e) => e.mvRaw.clamp(0.0, 3300.0))
                  .reduce((double a, double b) => a + b) /
              recs.length)
          .clamp(0.0, 3300.0);

      points.add(_ChartBucketPoint(
        timestamp: recs.last.timestamp,
        label: label,
        uviFiltered: GuvaCalibrationEngine.calculateCalibratedUVI(avgFiltMv),
        uviRaw: GuvaCalibrationEngine.calculateCalibratedUVI(avgRawMv),
        mvFiltered: avgFiltMv,
        mvRaw: avgRawMv,
      ));
    });

    return points.length > 80 ? points.sublist(points.length - 80) : points;
  }

  List<HourlyBucketStat> _get24HrList({required bool descending}) {
    final Iterable<UVRecord> dayRecords = _allHistoryRecords.where(
        (UVRecord r) =>
            r.timestamp.year == _selectedYear &&
            r.timestamp.month == _selectedMonth &&
            r.timestamp.day == _selectedDay);

    final Map<int, List<UVRecord>> byHour = <int, List<UVRecord>>{
      for (int h = 0; h < 24; h++) h: <UVRecord>[]
    };
    for (final UVRecord r in dayRecords) {
      byHour[r.timestamp.hour]?.add(r);
    }

    final List<HourlyBucketStat> list24 = <HourlyBucketStat>[];
    for (int h = 0; h < 24; h++) {
      final List<UVRecord> items = byHour[h]!;
      double peakUvi = 0.0;
      double avgMv = 0.0;
      if (items.isNotEmpty) {
        for (final UVRecord item in items) {
          final double u = item.getUviByFilter(_selectedFilter);
          if (u > peakUvi) peakUvi = u;
          avgMv += item.getMvByFilter(_selectedFilter);
        }
        avgMv = (avgMv / items.length).clamp(0.0, 3300.0);
      }
      list24.add(HourlyBucketStat(
        hour: h,
        timeSlot: '${h.toString().padLeft(2, '0')}:00',
        peakUvi: peakUvi,
        avgMv: avgMv,
        count: items.length,
        risk: GuvaCalibrationEngine.getRiskCategory(peakUvi),
      ));
    }

    if (descending) {
      list24.sort((HourlyBucketStat a, HourlyBucketStat b) {
        final int cmp = b.peakUvi.compareTo(a.peakUvi);
        if (cmp != 0) return cmp;
        return a.hour.compareTo(b.hour);
      });
    }
    return list24;
  }

  List<GranularTelemetryRow> _getGranularityTableRows() {
    final List<UVRecord> source = _getFilteredRecords();
    if (source.isEmpty) return <GranularTelemetryRow>[];

    final Map<String, List<UVRecord>> bucketed = <String, List<UVRecord>>{};
    for (final UVRecord r in source.reversed) {
      String key;
      if (_timeGranularity == 'Seconds') {
        key = DateFormat('yyyy-MM-dd HH:mm:ss').format(r.timestamp);
      } else if (_timeGranularity == 'Minutes') {
        key = DateFormat('yyyy-MM-dd HH:mm').format(r.timestamp);
      } else if (_timeGranularity == 'Hours') {
        key = DateFormat('yyyy-MM-dd HH:00').format(r.timestamp);
      } else {
        key = DateFormat('yyyy-MM-dd').format(r.timestamp);
      }
      bucketed.putIfAbsent(key, () => <UVRecord>[]).add(r);
    }

    return bucketed.entries.take(150).map((MapEntry<String, List<UVRecord>> e) {
      final List<UVRecord> recs = e.value;
      final double avgMv = (recs
                  .map((UVRecord r) => r.getMvByFilter(_selectedFilter))
                  .reduce((double a, double b) => a + b) /
              recs.length)
          .clamp(0.0, 3300.0);
      final double avgUvi = GuvaCalibrationEngine.calculateCalibratedUVI(avgMv);
      return GranularTelemetryRow(
        time: e.key,
        uvData:
            '${avgUvi.toStringAsFixed(2)} UVI (${GuvaCalibrationEngine.getRiskCategory(avgUvi)})',
        voltage: '${avgMv.toStringAsFixed(1)} mV',
      );
    }).toList();
  }

  Future<void> _downloadFullGraphDataCsv() async {
    final List<_ChartBucketPoint> pts = _getAggregatedChartPoints();
    if (pts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No graph data in current period to export!')),
      );
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln(
        'Bucket_Time ($_graphGranularity),Calibrated_UVI ($_selectedFilter),Raw_UVI,Filtered_mV,Raw_mV,WHO_Risk_Level');
    for (final _ChartBucketPoint p in pts) {
      csv.writeln(
        '${p.label},'
        '${p.uviFiltered.toStringAsFixed(3)},'
        '${p.uviRaw.toStringAsFixed(3)},'
        '${p.mvFiltered.toStringAsFixed(2)},'
        '${p.mvRaw.toStringAsFixed(2)},'
        '${GuvaCalibrationEngine.getRiskCategory(p.uviFiltered)}',
      );
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File(
        '${dir.path}/full_uv_graph_data_${_graphGranularity.toLowerCase()}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await file.writeAsString(csv.toString());
    await Share.shareXFiles(<XFile>[XFile(file.path)],
        text: 'Full UV Graph Data ($_graphGranularity) - All Plotted Points');
  }

  Future<void> _download3FilterComparisonCsv() async {
    final List<UVRecord> list = _getFilteredRecords().isNotEmpty
        ? _getFilteredRecords()
        : _allHistoryRecords;
    if (list.isEmpty) return;

    final StringBuffer csv = StringBuffer();
    csv.writeln(
        'Timestamp,Raw_mV,Median_mV,Kalman_mV,Hybrid_MedKal_mV,UVI_Calibrated,UVI_Lookup_Int,UVI_Linear_Old,Risk_Category');

    final DateFormat df = DateFormat('yyyy-MM-dd HH:mm:ss');
    for (final UVRecord r in list) {
      csv.writeln(
        '${df.format(r.timestamp)},'
        '${r.mvRaw.clamp(0.0, 3300.0).toStringAsFixed(2)},'
        '${r.mvMedian.clamp(0.0, 3300.0).toStringAsFixed(2)},'
        '${r.mvKalman.clamp(0.0, 3300.0).toStringAsFixed(2)},'
        '${r.mvHybrid.clamp(0.0, 3300.0).toStringAsFixed(2)},'
        '${r.uviCalibrated.toStringAsFixed(3)},'
        '${r.uviLookupInt},'
        '${r.uviLinearOld.toStringAsFixed(3)},'
        '${r.riskCategory}',
      );
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File(
        '${dir.path}/uv_3filter_benchmark_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await file.writeAsString(csv.toString());
    await Share.shareXFiles(<XFile>[XFile(file.path)],
        text: '3-Filter UV Comparison Dataset (Hybrid, Kalman, Median)');
  }

  Future<void> _exportFullCanvasGraphPng() async {
    final List<_ChartBucketPoint> pts = _getAggregatedChartPoints();
    if (pts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No graph data available to render!')),
      );
      return;
    }

    try {
      const double width = 1800;
      const double height = 960;
      const double padLeft = 110;
      const double padRight = 90;
      const double padTop = 140;
      const double padBottom = 150;
      const double plotW = width - padLeft - padRight;
      const double plotH = height - padTop - padBottom;

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);

      canvas.drawRect(
        const Rect.fromLTWH(0, 0, width, height),
        Paint()..color = const Color(0xFF111318),
      );

      _drawCanvasText(
        canvas,
        'World Health Organization UVI — Full Unclipped Curve ($_selectedFilter • $_graphGranularity)',
        const Offset(padLeft, 42),
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      );
      _drawCanvasText(
        canvas,
        'Exported: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}  |  Range: 0 - 3300 mV (0-3.3V)  |  Total Plotted Buckets: ${pts.length}',
        const Offset(padLeft, 84),
        fontSize: 18,
        color: Colors.white70,
      );

      for (int uvi = 0; uvi <= 12; uvi++) {
        final double y = padTop + plotH - (uvi / 12.0) * plotH;
        canvas.drawLine(
          Offset(padLeft, y),
          Offset(width - padRight, y),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.12)
            ..strokeWidth = 1.2,
        );
        _drawCanvasText(
          canvas,
          '$uvi',
          Offset(padLeft - 45, y - 10),
          fontSize: 18,
          color: Colors.white70,
        );
      }

      final List<Offset> filtCoords = <Offset>[];
      final List<Offset> rawCoords = <Offset>[];
      for (int i = 0; i < pts.length; i++) {
        final double x = pts.length == 1
            ? padLeft + plotW / 2
            : padLeft + (i / (pts.length - 1)) * plotW;
        final double yFilt =
            padTop + plotH - (pts[i].uviFiltered.clamp(0.0, 12.0) / 12.0) * plotH;
        final double yRaw =
            padTop + plotH - (pts[i].uviRaw.clamp(0.0, 12.0) / 12.0) * plotH;
        filtCoords.add(Offset(x, yFilt));
        rawCoords.add(Offset(x, yRaw));
      }

      if (_overlayRawOnChart && rawCoords.length > 1) {
        final Path rawPath = Path()..moveTo(rawCoords.first.dx, rawCoords.first.dy);
        for (int i = 1; i < rawCoords.length; i++) {
          rawPath.lineTo(rawCoords[i].dx, rawCoords[i].dy);
        }
        canvas.drawPath(
          rawPath,
          Paint()
            ..color = const Color(0xFFFF4D6D).withValues(alpha: 0.65)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }

      if (filtCoords.isNotEmpty) {
        final Path linePath = Path()
          ..moveTo(filtCoords.first.dx, filtCoords.first.dy);
        for (int i = 1; i < filtCoords.length; i++) {
          linePath.lineTo(filtCoords[i].dx, filtCoords[i].dy);
        }

        final Path areaPath = Path.from(linePath)
          ..lineTo(filtCoords.last.dx, padTop + plotH)
          ..lineTo(filtCoords.first.dx, padTop + plotH)
          ..close();

        final Shader whoGradient = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[
            Color(0xFF2ECC71),
            Color(0xFFF1C40F),
            Color(0xFFE67E22),
            Color(0xFFE74C3C),
            Color(0xFF9B59B6),
          ],
          stops: <double>[0.0, 0.25, 0.50, 0.75, 1.0],
        ).createShader(const Rect.fromLTWH(padLeft, padTop, plotW, plotH));

        canvas.drawPath(
          areaPath,
          Paint()
            ..shader = whoGradient
            ..style = PaintingStyle.fill,
        );

        canvas.drawPath(
          linePath,
          Paint()
            ..shader = whoGradient
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5.0
            ..strokeCap = StrokeCap.round,
        );
      }

      final int step = max(1, (pts.length / 8).floor());
      for (int i = 0; i < pts.length; i += step) {
        final double x = pts.length == 1
            ? padLeft + plotW / 2
            : padLeft + (i / (pts.length - 1)) * plotW;
        _drawCanvasText(
          canvas,
          pts[i].label,
          Offset(x - 32, padTop + plotH + 24),
          fontSize: 16,
          color: Colors.white70,
        );
      }

      final ui.Picture picture = recorder.endRecording();
      final ui.Image img =
          await picture.toImage(width.toInt(), height.toInt());
      final ByteData? byteData =
          await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final Directory dir = await getTemporaryDirectory();
      final File file = File(
          '${dir.path}/full_uv_gradient_graph_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await Share.shareXFiles(<XFile>[XFile(file.path)],
          text: 'Full High-Res WHO UV Index Gradient Graph ($_selectedFilter)');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export Error: $e')));
    }
  }

  void _drawCanvasText(
    Canvas canvas,
    String text,
    Offset pos, {
    double fontSize = 16,
    FontWeight fontWeight = FontWeight.normal,
    Color color = Colors.white,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style:
            TextStyle(fontSize: fontSize, fontWeight: fontWeight, color: color),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  Color _getWhoColor(double uvi) {
    if (uvi < 3.0) return const Color(0xFF4CAF50);
    if (uvi < 6.0) return const Color(0xFFFFC107);
    if (uvi < 8.0) return const Color(0xFFFF9800);
    if (uvi < 11.0) return const Color(0xFFF44336);
    return const Color(0xFFAB47BC);
  }

  String _getSunProtectionWindowText(List<HourlyBucketStat> list24) {
    final List<HourlyBucketStat> needProtection =
        list24.where((HourlyBucketStat h) => h.peakUvi >= 3.0).toList();
    if (needProtection.isEmpty) {
      return 'Sun protection recommended from 11:00 to 16:00.';
    }
    needProtection.sort(
        (HourlyBucketStat a, HourlyBucketStat b) => a.hour.compareTo(b.hour));
    final String startHr =
        '${needProtection.first.hour.toString().padLeft(2, '0')}:00';
    final String endHr =
        '${(needProtection.last.hour + 1).clamp(0, 23).toString().padLeft(2, '0')}:00';
    return 'Sun protection recommended from $startHr to $endHr.';
  }

  List<DateTime> _get7DayStripDates() {
    final DateTime selected =
        DateTime(_selectedYear, _selectedMonth, _selectedDay);
    return List<DateTime>.generate(
      7,
      (int idx) => selected.subtract(Duration(days: 3 - idx)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final Color cardBg =
        isDark ? const Color(0xFF1C1F26) : const Color(0xFFFFFFFF);
    final Color subCardBg =
        isDark ? const Color(0xFF252932) : const Color(0xFFF0F4F9);
    final Color primaryText = isDark ? Colors.white : const Color(0xFF1A1C1E);
    final Color secondaryText =
        isDark ? Colors.white70 : const Color(0xFF5F6368);

    final double activeMv =
        (_latestRecord?.getMvByFilter(_selectedFilter) ?? 0.0)
            .clamp(0.0, 3300.0);
    final double rawMv = (_latestRecord?.mvRaw ?? 0.0).clamp(0.0, 3300.0);
    final double activeUvi =
        GuvaCalibrationEngine.calculateCalibratedUVI(activeMv);
    final int discreteUvi = GuvaCalibrationEngine.lookupDiscreteUVI(activeMv);
    final String activeRisk = GuvaCalibrationEngine.getRiskCategory(activeUvi);
    final Color activeWhoColor = _getWhoColor(activeUvi);

    final List<HourlyBucketStat> hourlyChronological =
        _get24HrList(descending: false);
    final List<HourlyBucketStat> hourlyRankedDesc =
        _get24HrList(descending: true);
    final double maxDayUvi = hourlyRankedDesc.isNotEmpty
        ? max(activeUvi, hourlyRankedDesc.first.peakUvi)
        : activeUvi;

    final List<_ChartBucketPoint> chartPoints = _getAggregatedChartPoints();
    final List<GranularTelemetryRow> granularRows = _getGranularityTableRows();
    final List<DateTime> stripDates = _get7DayStripDates();

    final int currentYear = max(2026, DateTime.now().year);
    final List<int> yearOptions =
        List<int>.generate((currentYear - 2020) + 1, (int i) => 2020 + i);
    final int maxDays = _daysInMonth(_selectedYear, _selectedMonth);
    if (_selectedDay > maxDays) _selectedDay = maxDays;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: <Widget>[
            Icon(Icons.wb_sunny_outlined, color: activeWhoColor, size: 22),
            const SizedBox(width: 8),
            Text(
              'UV Index',
              style: TextStyle(
                color: primaryText,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: isDark
                ? 'Switch to White (Light) Mode'
                : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? const Color(0xFFFFD54F) : const Color(0xFF455A64),
            ),
            onPressed: widget.onToggleTheme,
          ),
          IconButton(
            tooltip: 'Connect ESP32 to Wi-Fi',
            icon: Icon(Icons.wifi_rounded, color: primaryText),
            onPressed: _showPhoneStyleWiFiDialog,
          ),
          IconButton(
            tooltip: 'Sync InfluxDB Cloud',
            icon: const Icon(Icons.cloud_sync_rounded, color: Color(0xFF4FC3F7)),
            onPressed: _syncFromInfluxDbCloud,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilledButton.tonalIcon(
              onPressed: _toggleDemoStream,
              icon: Icon(
                _isSimulating ? Icons.stop_circle : Icons.auto_graph_rounded,
                size: 16,
              ),
              label: Text(_isSimulating ? 'Stop' : 'Demo'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 1. GOOGLE WEATHER 7-DAY CALENDAR STRIP
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: stripDates.map((DateTime dt) {
                        final bool isSelected = dt.year == _selectedYear &&
                            dt.month == _selectedMonth &&
                            dt.day == _selectedDay;
                        final String dayLetter =
                            DateFormat('E').format(dt).substring(0, 1);
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _periodMode = 'Date';
                              _selectedYear = dt.year;
                              _selectedMonth = dt.month;
                              _selectedDay = dt.day;
                            });
                          },
                          child: Column(
                            children: <Widget>[
                              Text(
                                dayLetter,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: secondaryText,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected
                                      ? (isDark
                                          ? Colors.white
                                          : const Color(0xFF1A73E8))
                                      : Colors.transparent,
                                ),
                                child: Text(
                                  '${dt.day}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? (isDark ? Colors.black : Colors.white)
                                        : primaryText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      DateFormat('EEEE, d MMMM yyyy').format(
                          DateTime(_selectedYear, _selectedMonth, _selectedDay)),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 2. HERO UV INDEX & SEMI-CIRCULAR GAUGE CARD
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(Icons.sensors_rounded,
                                  size: 16, color: secondaryText),
                              const SizedBox(width: 6),
                              Text(
                                'ESP32-C3 Edge Sensor • GPIO2',
                                style: TextStyle(
                                    fontSize: 12, color: secondaryText),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'UV ${activeUvi.toStringAsFixed(1)}',
                            style: TextStyle(
                              fontSize: 42,
                              fontWeight: FontWeight.w800,
                              color: primaryText,
                            ),
                          ),
                          Text(
                            activeRisk,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: activeWhoColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Filtered: ${activeMv.toStringAsFixed(1)} mV  •  Raw: ${rawMv.toStringAsFixed(1)} mV',
                            style:
                                TextStyle(fontSize: 12, color: secondaryText),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      children: <Widget>[
                        SizedBox(
                          width: 92,
                          height: 92,
                          child: CustomPaint(
                            painter: GoogleWeatherUvArcPainter(
                              uvi: activeUvi,
                              isDarkMode: isDark,
                            ),
                            child: Center(
                              child: Text(
                                '$discreteUvi',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: primaryText,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          'Max UV: ${maxDayUvi.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 3. GOOGLE WEATHER WHO GRADIENT GRAPH CARD
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: <Widget>[
                                Text(
                                  activeUvi.toStringAsFixed(0),
                                  style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w800,
                                    color: primaryText,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  activeRisk,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: secondaryText,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              'World Health Organization UVI (0-3.3V Scale)',
                              style: TextStyle(
                                  fontSize: 12, color: secondaryText),
                            ),
                          ],
                        ),
                        Row(
                          children: <Widget>[
                            Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: subCardBg,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _graphGranularity,
                                  items: <String>[
                                    'Seconds',
                                    'Minutes',
                                    'Hours',
                                    'Days',
                                    'Months'
                                  ]
                                      .map((String g) =>
                                          DropdownMenuItem<String>(
                                            value: g,
                                            child: Text(g,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: primaryText)),
                                          ))
                                      .toList(),
                                  onChanged: (String? val) {
                                    if (val != null) {
                                      setState(() => _graphGranularity = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Export Full Unclipped Canvas (PNG)',
                              icon: Icon(Icons.download_rounded,
                                  color: primaryText),
                              onPressed: _exportFullCanvasGraphPng,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (chartPoints.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 6.0, right: 24.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: chartPoints
                              .take(8)
                              .map((_ChartBucketPoint p) => Text(
                                    p.uviFiltered.toStringAsFixed(0),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: secondaryText,
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    Container(
                      height: 220,
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF15181E)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                            color: isDark ? Colors.white10 : Colors.black12),
                      ),
                      child: chartPoints.isEmpty
                          ? Center(
                              child: Text(
                                'Tap "Demo" or "Connect" to view the live WHO UV Gradient Curve.',
                                style: TextStyle(
                                    color: secondaryText, fontSize: 12),
                              ),
                            )
                          : LineChart(
                              LineChartData(
                                minY: 0,
                                maxY: 12,
                                clipData: const FlClipData.all(),
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: true,
                                  horizontalInterval: 2,
                                  getDrawingHorizontalLine: (double v) => FlLine(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.07)
                                        : Colors.black.withValues(alpha: 0.07),
                                    strokeWidth: 1,
                                  ),
                                  getDrawingVerticalLine: (double v) => FlLine(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.05)
                                        : Colors.black.withValues(alpha: 0.05),
                                    strokeWidth: 1,
                                  ),
                                ),
                                borderData: FlBorderData(show: false),
                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  leftTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  rightTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 26,
                                      interval: 1,
                                      getTitlesWidget:
                                          (double val, TitleMeta meta) {
                                        final int v = val.toInt();
                                        if (v >= 0 && v <= 12) {
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                                left: 6.0),
                                            child: Text(
                                              '$v',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: secondaryText),
                                            ),
                                          );
                                        }
                                        return const SizedBox.shrink();
                                      },
                                    ),
                                  ),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 24,
                                      interval: (chartPoints.length > 5)
                                          ? (chartPoints.length / 5)
                                              .floorToDouble()
                                          : 1,
                                      getTitlesWidget:
                                          (double val, TitleMeta meta) {
                                        final int idx = val.toInt();
                                        if (idx >= 0 &&
                                            idx < chartPoints.length) {
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                                top: 6.0),
                                            child: Text(
                                              chartPoints[idx].label,
                                              style: TextStyle(
                                                  fontSize: 9,
                                                  color: secondaryText),
                                            ),
                                          );
                                        }
                                        return const SizedBox.shrink();
                                      },
                                    ),
                                  ),
                                ),
                                lineBarsData: <LineChartBarData>[
                                  if (_overlayRawOnChart)
                                    LineChartBarData(
                                      spots: chartPoints
                                          .asMap()
                                          .entries
                                          .map((MapEntry<int, _ChartBucketPoint>
                                                  e) =>
                                              FlSpot(
                                                  e.key.toDouble(),
                                                  e.value.uviRaw
                                                      .clamp(0.0, 12.0)))
                                          .toList(),
                                      isCurved: false,
                                      color: const Color(0xFFFF4D6D)
                                          .withValues(alpha: 0.55),
                                      barWidth: 1.4,
                                      dashArray: <int>[4, 4],
                                      dotData: const FlDotData(show: false),
                                    ),
                                  LineChartBarData(
                                    spots: chartPoints
                                        .asMap()
                                        .entries
                                        .map((MapEntry<int, _ChartBucketPoint>
                                                e) =>
                                            FlSpot(
                                                e.key.toDouble(),
                                                e.value.uviFiltered
                                                    .clamp(0.0, 12.0)))
                                        .toList(),
                                    isCurved: true,
                                    curveSmoothness: 0.35,
                                    preventCurveOvershootingThreshold: 10.0,
                                    gradient: const LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: <Color>[
                                        Color(0xFF4CAF50),
                                        Color(0xFFFFEB3B),
                                        Color(0xFFFF9800),
                                        Color(0xFFF44336),
                                        Color(0xFF9C27B0),
                                      ],
                                    ),
                                    barWidth: 3.5,
                                    dotData: FlDotData(
                                      show: true,
                                      checkToShowDot: (FlSpot spot,
                                              LineChartBarData barData) =>
                                          spot == barData.spots.last,
                                    ),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: <Color>[
                                          const Color(0xFF4CAF50)
                                              .withValues(alpha: 0.35),
                                          const Color(0xFFFFEB3B)
                                              .withValues(alpha: 0.40),
                                          const Color(0xFFFF9800)
                                              .withValues(alpha: 0.45),
                                          const Color(0xFFF44336)
                                              .withValues(alpha: 0.50),
                                          const Color(0xFF9C27B0)
                                              .withValues(alpha: 0.55),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      DateFormat('d MMMM yyyy').format(
                          DateTime(_selectedYear, _selectedMonth, _selectedDay)),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: primaryText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _getSunProtectionWindowText(hourlyChronological),
                      style: TextStyle(fontSize: 13, color: secondaryText),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 4. CONNECTION & 3-FILTER CONTROL CARD
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'ESP32-C3 Telemetry & 3-Tier DSP Filter Lab (0-3300 mV)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: primaryText,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _ipController,
                            style: TextStyle(
                                color: primaryText,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'ESP32 Local IP (or 192.168.4.1 Setup)',
                              prefixIcon: const Icon(Icons.router_rounded,
                                  size: 18),
                              filled: true,
                              fillColor: subCardBg,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _toggleConnection,
                          child: Text(_isConnected ? 'Stop' : 'Connect'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _status,
                            style:
                                TextStyle(fontSize: 11, color: secondaryText),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Row(
                          children: <Widget>[
                            _statusChip(
                              label: _isInfluxCloudConnected
                                  ? 'InfluxDB'
                                  : 'Influx Sync',
                              ok: _isInfluxCloudConnected,
                            ),
                            const SizedBox(width: 6),
                            _statusChip(
                              label:
                                  _isMqttCloudConnected ? 'HiveMQ' : 'MQTT Wait',
                              ok: _isMqttCloudConnected,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Row(
                      children: <Widget>[
                        const Icon(Icons.tune_rounded, size: 18),
                        const SizedBox(width: 6),
                        Text('Active DSP:',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: primaryText)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedFilter,
                              isExpanded: true,
                              items: _filterOptions
                                  .map((String f) => DropdownMenuItem<String>(
                                        value: f,
                                        child: Text(f,
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: primaryText)),
                                      ))
                                  .toList(),
                              onChanged: (String? val) {
                                if (val != null) {
                                  setState(() => _selectedFilter = val);
                                }
                              },
                            ),
                          ),
                        ),
                        Checkbox(
                          value: _overlayRawOnChart,
                          onChanged: (bool? v) =>
                              setState(() => _overlayRawOnChart = v ?? true),
                        ),
                        Text('Raw',
                            style:
                                TextStyle(fontSize: 11, color: secondaryText)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _filterOptions.map((String fName) {
                          final double sigma = _calcFilterStdDev(fName);
                          final double val =
                              (_latestRecord?.getMvByFilter(fName) ?? 0.0)
                                  .clamp(0.0, 3300.0);
                          final bool isSelected = _selectedFilter == fName;
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _selectedFilter = fName),
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? activeWhoColor.withValues(alpha: 0.16)
                                    : subCardBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isSelected
                                      ? activeWhoColor
                                      : Colors.transparent,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(fName,
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: primaryText)),
                                  Text(
                                    '${val.toStringAsFixed(1)} mV  (σ=${sigma.toStringAsFixed(2)})',
                                    style: TextStyle(
                                        fontSize: 10, color: secondaryText),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 5. PERSONAL UV PROTECTION INSIGHTS CARD
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.health_and_safety_outlined,
                            color: activeWhoColor, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Personal UV Protection Insights',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: primaryText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _insightBullet(
                      icon: Icons.wb_twilight_rounded,
                      title: 'Sunscreen',
                      subtitle: activeUvi >= 3.0
                          ? 'Apply broad-spectrum SPF 30+ sunscreen and reapply every 2 hours while outdoors.'
                          : 'UV Index is below 3. Sunscreen is optional unless outdoors for extended periods.',
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                    const SizedBox(height: 8),
                    _insightBullet(
                      icon: Icons.checkroom_rounded,
                      title: 'Clothing & Shade',
                      subtitle: activeUvi >= 6.0
                          ? 'High/Very High UV detected. Wear a wide-brimmed sunhat, UV-blocking sunglasses, and seek shade between 10 AM and 4 PM.'
                          : 'Lightweight breathable clothing and sunglasses recommended for bright daylight.',
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                    const Divider(height: 22),
                    Text(
                      "The World Health Organization's UV index (UVI) measures ultraviolet radiation. The higher the UVI, the greater the potential for skin and eye damage, and the faster harm can occur.",
                      style: TextStyle(fontSize: 11, color: secondaryText),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: <Widget>[
                        _whoBandLabelLine(
                            '0-2 Low', const Color(0xFF4CAF50), secondaryText),
                        _whoBandLabelLine('3-5 Moderate',
                            const Color(0xFFFFC107), secondaryText),
                        _whoBandLabelLine(
                            '6-7 High', const Color(0xFFFF9800), secondaryText),
                        _whoBandLabelLine('8-10 Very High',
                            const Color(0xFFF44336), secondaryText),
                        _whoBandLabelLine('11+ Extreme',
                            const Color(0xFFAB47BC), secondaryText),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 6. PERIOD FILTER & 24-HOUR DESCENDING PEAK RANKING
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Historical Period Filter & 24-Hour Peak Ranking',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: primaryText,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <String>['Date', 'Week', 'Month', 'Year']
                          .map((String mode) {
                        final bool selected = _periodMode == mode;
                        return Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 2.0),
                            child: ChoiceChip(
                              label: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  mode,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                              selected: selected,
                              onSelected: (bool _) =>
                                  setState(() => _periodMode = mode),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _buildDropdownChip<int>(
                          label: 'Year',
                          value: _selectedYear,
                          subCardBg: subCardBg,
                          primaryText: primaryText,
                          items: yearOptions
                              .map((int y) => DropdownMenuItem<int>(
                                  value: y, child: Text('$y')))
                              .toList(),
                          onChanged: (int? val) => setState(
                              () => _selectedYear = val ?? currentYear),
                        ),
                        if (_periodMode != 'Year')
                          _buildDropdownChip<int>(
                            label: 'Month',
                            value: _selectedMonth,
                            subCardBg: subCardBg,
                            primaryText: primaryText,
                            items: List<DropdownMenuItem<int>>.generate(
                              12,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text(_monthNames[i]),
                              ),
                            ),
                            onChanged: (int? val) =>
                                setState(() => _selectedMonth = val ?? 1),
                          ),
                        if (_periodMode == 'Week')
                          _buildDropdownChip<int>(
                            label: 'Week',
                            value: _selectedWeek,
                            subCardBg: subCardBg,
                            primaryText: primaryText,
                            items: List<DropdownMenuItem<int>>.generate(
                              5,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text('Week ${i + 1}'),
                              ),
                            ),
                            onChanged: (int? val) =>
                                setState(() => _selectedWeek = val ?? 1),
                          ),
                        if (_periodMode == 'Date')
                          _buildDropdownChip<int>(
                            label: 'Date',
                            value: _selectedDay,
                            subCardBg: subCardBg,
                            primaryText: primaryText,
                            items: List<DropdownMenuItem<int>>.generate(
                              maxDays,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text(
                                    '${i + 1} ${_monthNames[_selectedMonth - 1]}'),
                              ),
                            ),
                            onChanged: (int? val) =>
                                setState(() => _selectedDay = val ?? 1),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 190,
                      child: ListView.builder(
                        itemCount: hourlyRankedDesc.length,
                        itemBuilder: (BuildContext ctx, int idx) {
                          final HourlyBucketStat hr = hourlyRankedDesc[idx];
                          final bool isTop = idx == 0;
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(
                              color: isTop
                                  ? const Color(0xFFFF0055)
                                      .withValues(alpha: 0.14)
                                  : subCardBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isTop
                                    ? const Color(0xFFFF0055)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                Text(
                                  isTop
                                      ? '★ #1 Peak Hour (${hr.timeSlot})'
                                      : '#${idx + 1}  ${hr.timeSlot}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isTop
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    color: primaryText,
                                  ),
                                ),
                                Text(
                                  'UVI ${hr.peakUvi.toStringAsFixed(2)}  •  ${hr.avgMv.toStringAsFixed(1)} mV',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: _getWhoColor(hr.peakUvi),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 7. TELEMETRY DATA TABLE & FULL EXPORTS
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(
                          'Telemetry Data Log',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: primaryText,
                          ),
                        ),
                        DropdownButton<String>(
                          value: _timeGranularity,
                          items: <String>['Seconds', 'Minutes', 'Hours', 'Day']
                              .map((String unit) => DropdownMenuItem<String>(
                                    value: unit,
                                    child: Text(unit,
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: primaryText)),
                                  ))
                              .toList(),
                          onChanged: (String? v) {
                            if (v != null) {
                              setState(() => _timeGranularity = v);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 190,
                      width: double.infinity,
                      child: granularRows.isEmpty
                          ? Center(
                              child: Text(
                                'No records for this period yet.',
                                style: TextStyle(
                                    color: secondaryText, fontSize: 12),
                              ),
                            )
                          : SingleChildScrollView(
                              scrollDirection: Axis.vertical,
                              child: DataTable(
                                columnSpacing: 16,
                                columns: const <DataColumn>[
                                  DataColumn(label: Text('Time')),
                                  DataColumn(label: Text('UV Index')),
                                  DataColumn(label: Text('Voltage')),
                                ],
                                rows: granularRows
                                    .map((GranularTelemetryRow row) {
                                  return DataRow(cells: <DataCell>[
                                    DataCell(Text(row.time,
                                        style: const TextStyle(fontSize: 11))),
                                    DataCell(Text(row.uvData,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold))),
                                    DataCell(Text(row.voltage,
                                        style: const TextStyle(fontSize: 11))),
                                  ]);
                                }).toList(),
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _downloadFullGraphDataCsv,
                            icon: const Icon(Icons.show_chart_rounded, size: 16),
                            label: const Text(
                              'Full Graph Data CSV',
                              style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _download3FilterComparisonCsv,
                            icon: const Icon(Icons.analytics_outlined, size: 16),
                            label: const Text(
                              '3-Filter Dataset CSV',
                              style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _exportFullCanvasGraphPng,
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: const Text(
                          'Export Full Unclipped WHO Gradient Graph (High-Res PNG)',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip({required String label, required bool ok}) {
    final Color c = ok ? const Color(0xFF4CAF50) : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c),
      ),
    );
  }

  Widget _insightBullet({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: secondaryText),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: primaryText)),
              Text(subtitle,
                  style: TextStyle(fontSize: 12, color: secondaryText)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _whoBandLabelLine(String text, Color dotColor, Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11, color: textColor)),
      ],
    );
  }

  Widget _buildDropdownChip<T>({
    required String label,
    required T value,
    required Color subCardBg,
    required Color primaryText,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: subCardBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$label: ', style: const TextStyle(fontSize: 11)),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              style: TextStyle(
                  color: primaryText,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
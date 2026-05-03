import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'api_service.dart';
import 'auth_service.dart';
import 'qr_pairing_page.dart';
import 'screens/register_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService().loadToken();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0FA3B1),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF07131A),
        cardTheme: CardThemeData(
          color: const Color(0xFF102028),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF102028),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: AuthService().token == null ? const LoginPage() : const HomePage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  bool loading = false;

  Future<void> submit() async {
    setState(() => loading = true);

    final auth = AuthService();
    final ok = await auth.login(email.text.trim(), pass.text);

    if (!mounted) {
      return;
    }
    setState(() => loading = false);

    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(auth.lastErrorMessage ?? 'Błąd')));
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Dojrzewalnia PRO',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: pass,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Hasło',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: loading ? null : submit,
                        child: Text(loading ? 'Czekaj...' : 'Zaloguj'),
                      ),
                    ),
                    if (AuthService.supportsRegistration) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: loading
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const RegisterPage(),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Utworz nowe konto'),
                      ),
                    ],
                    if (!AuthService.supportsRegistration) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Ten panel VPS nie obsluguje rejestracji nowych kont. Zaloguj sie istniejacymi danymi administratora.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final api = ApiService();
  static const String _fallbackDeviceId = 'dojrzewalnia-01';
  String deviceId = _fallbackDeviceId;

  Map<String, dynamic>? data;
  List history = [];
  List available = [];
  bool demoMode = false;
  String? loadError;
  double? draftTargetTemp;
  double? draftTargetHumidity;
  double? draftTempHysteresis;
  double? draftHumHysteresis;
  bool savingTargetTemp = false;
  bool savingTargetHumidity = false;
  bool savingTempHysteresis = false;
  bool savingHumHysteresis = false;

  int tab = 0;
  StreamSubscription? realtimeSub;

  Future<void> _logout() async {
    await AuthService().logout();
    if (!mounted) {
      return;
    }
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    load();
    scanDevices();
    startRealtime();
  }

  @override
  void dispose() {
    realtimeSub?.cancel();
    super.dispose();
  }

  String? _deviceIdFromEntry(dynamic entry) {
    if (entry is! Map) {
      return null;
    }

    final rawId = entry['id'] ?? entry['deviceId'] ?? entry['device_id'];
    final id = rawId?.toString().trim() ?? '';
    return id.isEmpty ? null : id;
  }

  String? _pickPreferredDeviceId(List entries) {
    for (final entry in entries) {
      if (entry is! Map) {
        continue;
      }
      if (entry['online'] == true) {
        final id = _deviceIdFromEntry(entry);
        if (id != null) {
          return id;
        }
      }
    }

    for (final entry in entries) {
      final id = _deviceIdFromEntry(entry);
      if (id != null) {
        return id;
      }
    }

    return null;
  }

  void _updateAvailableDevices(List entries) {
    final preferredDeviceId = _pickPreferredDeviceId(entries);
    final hasCurrentDevice = entries.any(
      (entry) => _deviceIdFromEntry(entry) == deviceId,
    );
    final shouldSwitchDevice =
        preferredDeviceId != null &&
        (deviceId == _fallbackDeviceId || !hasCurrentDevice);

    setState(() {
      available = entries;
      if (shouldSwitchDevice) {
        deviceId = preferredDeviceId;
      }
    });

    if (shouldSwitchDevice) {
      startRealtime();
      unawaited(load());
    }
  }

  Future load() async {
    try {
      final currentDeviceId = deviceId;
      final d = await api.getDeviceData(deviceId: currentDeviceId);
      final h = await api.getHistory(deviceId: currentDeviceId);
      if (!mounted) {
        return;
      }
      setState(() {
        loadError = null;
        data = Map<String, dynamic>.from((d['data'] as Map?) ?? const {});
        history = h;
        if (!savingTargetTemp &&
            !savingTargetHumidity &&
            !savingTempHysteresis &&
            !savingHumHysteresis) {
          draftTargetTemp = null;
          draftTargetHumidity = null;
          draftTempHysteresis = null;
          draftHumHysteresis = null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        loadError = error.toString();
      });
    }
  }

  void startRealtime() {
    realtimeSub?.cancel();

    final currentDeviceId = deviceId;

    realtimeSub = api
        .streamDevice(currentDeviceId)
        .listen(
          (event) {
            final deviceList = event['devices'];
            final realtimeData = event['data'];

            if (!mounted) {
              return;
            }

            if (deviceList is List) {
              _updateAvailableDevices(deviceList);
            }

            if (realtimeData is Map<String, dynamic>) {
              setState(() {
                loadError = null;
                data = {...?data, ...realtimeData};
                history = [
                  ...history.take(80),
                  {
                    'temp': realtimeData['temp'],
                    'hum': realtimeData['hum'] ?? realtimeData['humidity'],
                    'created_at': DateTime.now().toIso8601String(),
                  },
                ];
              });
            }
          },
          onError: (_) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) {
                startRealtime();
              }
            });
          },
        );
  }

  Future scanDevices() async {
    try {
      final list = await api.getAvailableDevices();
      if (!mounted) {
        return;
      }
      _updateAvailableDevices(list);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> exportHistoryCsv() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/historia_dojrzewalni.csv');

    final rows = [
      'czas,temp,wilgotnosc',
      ...history.map((entry) {
        final time = entry['created_at'] ?? '';
        final temp = entry['temp'] ?? entry['temperature'] ?? '';
        final hum = entry['hum'] ?? entry['humidity'] ?? '';
        return '$time,$temp,$hum';
      }),
    ];

    await file.writeAsString(rows.join('\n'));
    await Share.shareXFiles([XFile(file.path)], text: 'Historia dojrzewalni');
  }

  double _readNumber(dynamic value, {double fallback = double.nan}) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  double _statusValue(List<String> keys, {double fallback = double.nan}) {
    final snapshot = data;
    if (snapshot == null) {
      return fallback;
    }

    for (final key in keys) {
      final parsed = _readNumber(snapshot[key], fallback: double.nan);
      if (parsed.isFinite) {
        return parsed;
      }
    }

    return fallback;
  }

  double _historyValue(dynamic entry, List<String> keys) {
    for (final key in keys) {
      final parsed = _readNumber(entry[key], fallback: double.nan);
      if (parsed.isFinite) {
        return parsed;
      }
    }
    return double.nan;
  }

  double _currentTargetTemp() {
    final target = _statusValue([
      'target_temp',
      'targetTemp',
      'targetTemperature',
    ], fallback: double.nan);
    if (target.isFinite) {
      return target.clamp(0.0, 25.0).toDouble();
    }

    final currentTemp = _statusValue(['temp', 'temperature'], fallback: 14.0);
    return currentTemp.clamp(0.0, 25.0).toDouble();
  }

  double _currentTargetHumidity() {
    final target = _statusValue([
      'target_humidity',
      'targetHum',
      'targetHumidity',
      'humidityTarget',
    ], fallback: double.nan);
    if (target.isFinite) {
      return target.clamp(40.0, 100.0).toDouble();
    }
    return 78.0;
  }

  double _currentTempHysteresis() {
    final explicit = _statusValue([
      'temp_hysteresis',
      'tempHysteresis',
    ], fallback: double.nan);
    if (explicit.isFinite) {
      return explicit.clamp(0.0, 10.0).toDouble();
    }

    return 0.5;
  }

  double _currentHumHysteresis() {
    final explicit = _statusValue([
      'hum_hysteresis',
      'humHysteresis',
    ], fallback: double.nan);
    if (explicit.isFinite) {
      return explicit.clamp(0.0, 30.0).toDouble();
    }

    return 2.0;
  }

  List<FlSpot> _historySpots(List<String> keys) {
    final spots = <FlSpot>[];
    for (final entry in history) {
      final value = _historyValue(entry, keys);
      if (value.isFinite) {
        spots.add(FlSpot(spots.length.toDouble(), value));
      }
    }
    return spots;
  }

  Future<void> _saveTargetTemp(double value) async {
    final previousValue = _currentTargetTemp();
    final humidityTarget = draftTargetHumidity ?? _currentTargetHumidity();
    final tempHysteresis = draftTempHysteresis ?? _currentTempHysteresis();
    final humHysteresis = draftHumHysteresis ?? _currentHumHysteresis();

    setState(() {
      draftTargetTemp = value;
      savingTargetTemp = true;
    });

    try {
      await api.saveTargets(
        deviceId: deviceId,
        targetTemp: value,
        targetHumidity: humidityTarget,
        tempHysteresis: tempHysteresis,
        humHysteresis: humHysteresis,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        savingTargetTemp = false;
        data = {
          ...?data,
          'target_temp': value,
          'target_humidity': humidityTarget,
          'temp_hysteresis': tempHysteresis,
          'hum_hysteresis': humHysteresis,
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Zapisano temperature zadana: ${value.toStringAsFixed(1)} C',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        savingTargetTemp = false;
        draftTargetTemp = previousValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nie udalo sie zapisac temperatury zadanej: $error'),
        ),
      );
    }
  }

  Future<void> _saveTargetHumidity(double value) async {
    final previousValue = _currentTargetHumidity();
    final temperatureTarget = draftTargetTemp ?? _currentTargetTemp();
    final tempHysteresis = draftTempHysteresis ?? _currentTempHysteresis();
    final humHysteresis = draftHumHysteresis ?? _currentHumHysteresis();

    setState(() {
      draftTargetHumidity = value;
      savingTargetHumidity = true;
    });

    try {
      await api.saveTargets(
        deviceId: deviceId,
        targetTemp: temperatureTarget,
        targetHumidity: value,
        tempHysteresis: tempHysteresis,
        humHysteresis: humHysteresis,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        savingTargetHumidity = false;
        data = {
          ...?data,
          'target_temp': temperatureTarget,
          'target_humidity': value,
          'temp_hysteresis': tempHysteresis,
          'hum_hysteresis': humHysteresis,
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Zapisano wilgotnosc zadana: ${value.toStringAsFixed(0)} %',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        savingTargetHumidity = false;
        draftTargetHumidity = previousValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nie udalo sie zapisac wilgotnosci zadanej: $error'),
        ),
      );
    }
  }

  Future<void> _saveTempHysteresis(double value) async {
    final previousValue = _currentTempHysteresis();
    final temperatureTarget = draftTargetTemp ?? _currentTargetTemp();
    final humidityTarget = draftTargetHumidity ?? _currentTargetHumidity();
    final humHysteresis = draftHumHysteresis ?? _currentHumHysteresis();

    setState(() {
      draftTempHysteresis = value;
      savingTempHysteresis = true;
    });

    try {
      await api.saveTargets(
        deviceId: deviceId,
        targetTemp: temperatureTarget,
        targetHumidity: humidityTarget,
        tempHysteresis: value,
        humHysteresis: humHysteresis,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        savingTempHysteresis = false;
        data = {
          ...?data,
          'target_temp': temperatureTarget,
          'target_humidity': humidityTarget,
          'temp_hysteresis': value,
          'hum_hysteresis': humHysteresis,
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Zapisano histereze temperatury: ${value.toStringAsFixed(1)} C',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        savingTempHysteresis = false;
        draftTempHysteresis = previousValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nie udalo sie zapisac histerezy temperatury: $error'),
        ),
      );
    }
  }

  Future<void> _saveHumHysteresis(double value) async {
    final previousValue = _currentHumHysteresis();
    final temperatureTarget = draftTargetTemp ?? _currentTargetTemp();
    final humidityTarget = draftTargetHumidity ?? _currentTargetHumidity();
    final tempHysteresis = draftTempHysteresis ?? _currentTempHysteresis();

    setState(() {
      draftHumHysteresis = value;
      savingHumHysteresis = true;
    });

    try {
      await api.saveTargets(
        deviceId: deviceId,
        targetTemp: temperatureTarget,
        targetHumidity: humidityTarget,
        tempHysteresis: tempHysteresis,
        humHysteresis: value,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        savingHumHysteresis = false;
        data = {
          ...?data,
          'target_temp': temperatureTarget,
          'target_humidity': humidityTarget,
          'temp_hysteresis': tempHysteresis,
          'hum_hysteresis': value,
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Zapisano histereze wilgotnosci: ${value.toStringAsFixed(1)} %',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        savingHumHysteresis = false;
        draftHumHysteresis = previousValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nie udalo sie zapisac histerezy wilgotnosci: $error'),
        ),
      );
    }
  }

  Widget _buildTelemetryChart({
    required String title,
    required String unit,
    required Color color,
    required List<FlSpot> spots,
    double? targetLine,
  }) {
    if (spots.length < 2) {
      return Card(
        child: SizedBox(
          height: 200,
          child: Center(child: Text('Za malo danych dla wykresu: $title')),
        ),
      );
    }

    final values = <double>[for (final spot in spots) spot.y, ?targetLine];
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final range = (maxValue - minValue).abs();
    final padding = range < 1 ? 1.0 : range * 0.18;
    final boundedMinY = unit == '%'
        ? math.max(0.0, minValue - padding)
        : math.max(0.0, minValue - padding);
    final boundedMaxY = unit == '%'
        ? math.min(100.0, maxValue + padding)
        : math.min(25.0, maxValue + padding);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(1, spots.length - 1).toDouble(),
                  minY: boundedMinY,
                  maxY: math.max(boundedMaxY, boundedMinY + 0.5),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: math.max(
                      (boundedMaxY - boundedMinY) / 4,
                      1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, meta) {
                          final decimals = unit == '%' ? 0 : 1;
                          return Text(
                            '${value.toStringAsFixed(decimals)}$unit',
                            style: Theme.of(context).textTheme.bodySmall,
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.white24),
                  ),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      if (targetLine != null)
                        HorizontalLine(
                          y: targetLine,
                          color: color.withValues(alpha: 0.45),
                          strokeWidth: 1.5,
                          dashArray: const [8, 6],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topRight,
                            style: Theme.of(context).textTheme.bodySmall,
                            labelResolver: (_) =>
                                'Cel ${targetLine.toStringAsFixed(1)}$unit',
                          ),
                        ),
                    ],
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: color,
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: color.withValues(alpha: 0.16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dojrzewalnia'),
        actions: [
          IconButton(
            tooltip: 'Odswiez',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Wyloguj',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: tab,
        onTap: (i) => setState(() => tab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      body: tab == 0 ? dashboard() : settings(),
    );
  }

  Widget dashboard() {
    if (demoMode) {
      data = {
        'temp': 12.4,
        'humidity': 78,
        'wifi': true,
        'mqtt': true,
        'mode': 'ai',
      };
    }

    if (loadError != null && data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: load, child: const Text('Ponow')),
            ],
          ),
        ),
      );
    }

    if (data == null) return const Center(child: CircularProgressIndicator());

    final currentTempValue = _statusValue(['temp', 'temperature'], fallback: 0);
    final temp = currentTempValue.toStringAsFixed(1);
    final hum = _statusValue([
      'humidity',
      'hum',
    ], fallback: 0).toStringAsFixed(0);
    final targetTemp = draftTargetTemp ?? _currentTargetTemp();
    final targetHumidity = draftTargetHumidity ?? _currentTargetHumidity();
    final tempSpots = _historySpots(['temp', 'temperature']);
    final humiditySpots = _historySpots(['hum', 'humidity']);
    final mode = (data!['mode'] ?? 'unknown').toString().toUpperCase();
    final wifiOk = data!['wifi'] == true || data!['wifiOk'] == true;
    final mqttOk = data!['mqtt'] == true || data!['brokerConnected'] == true;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              colors: [Color(0xFF0E7490), Color(0xFF1D4ED8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sterowanie komora',
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.thermostat,
                      label: 'Temperatura',
                      value: '$temp °C',
                      hint: 'Zadana ${targetTemp.toStringAsFixed(1)} °C',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.water_drop,
                      label: 'Wilgotnosc',
                      value: '$hum %',
                      hint: 'Zadana ${targetHumidity.toStringAsFixed(0)} %',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusChip(label: 'Tryb $mode', active: true),
                  _StatusChip(label: 'WiFi', active: wifiOk),
                  _StatusChip(label: 'MQTT', active: mqttOk),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Zadana temperatura',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '${targetTemp.toStringAsFixed(1)} °C',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: targetTemp,
                  min: 0,
                  max: 25,
                  divisions: 50,
                  label: '${targetTemp.toStringAsFixed(1)} °C',
                  onChanged: (value) => setState(() => draftTargetTemp = value),
                  onChangeEnd: _saveTargetTemp,
                ),
                if (savingTargetTemp) const LinearProgressIndicator(),
                const SizedBox(height: 20),
                const Text(
                  'Zadana wilgotnosc',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '${targetHumidity.toStringAsFixed(0)} %',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: targetHumidity,
                  min: 40,
                  max: 100,
                  divisions: 60,
                  label: '${targetHumidity.toStringAsFixed(0)} %',
                  onChanged: (value) =>
                      setState(() => draftTargetHumidity = value),
                  onChangeEnd: _saveTargetHumidity,
                ),
                if (savingTargetHumidity) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _buildTelemetryChart(
          title: 'Wykres temperatury',
          unit: '°C',
          color: Colors.orangeAccent,
          spots: tempSpots,
          targetLine: targetTemp,
        ),
        const SizedBox(height: 16),
        _buildTelemetryChart(
          title: 'Wykres wilgotnosci',
          unit: '%',
          color: Colors.cyanAccent,
          spots: humiditySpots,
          targetLine: targetHumidity,
        ),
        const SizedBox(height: 20),
        const Text(
          'Tryb pracy',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.tonal(
              onPressed: () => api.setPidMode(deviceId: deviceId, mode: 'auto'),
              child: const Text('AUTO'),
            ),
            FilledButton.tonal(
              onPressed: () =>
                  api.setPidMode(deviceId: deviceId, mode: 'manual'),
              child: const Text('MANUAL'),
            ),
            FilledButton.tonal(
              onPressed: () => api.setPidMode(deviceId: deviceId, mode: 'ai'),
              child: const Text('AI'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'Sterowanie reczne',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => api.sendControlCommand(
                deviceId: deviceId,
                topic: 'cooling',
                value: true,
              ),
              icon: const Icon(Icons.ac_unit),
              label: const Text('Cooling'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => api.sendControlCommand(
                deviceId: deviceId,
                topic: 'fan',
                value: true,
              ),
              icon: const Icon(Icons.air),
              label: const Text('Fan'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => api.sendControlCommand(
                deviceId: deviceId,
                topic: 'humidifier',
                value: true,
              ),
              icon: const Icon(Icons.water_drop),
              label: const Text('Humidifier'),
            ),
          ],
        ),
      ],
    );
  }

  Widget settings() {
    final targetTemp = draftTargetTemp ?? _currentTargetTemp();
    final targetHumidity = draftTargetHumidity ?? _currentTargetHumidity();
    final tempHysteresis = draftTempHysteresis ?? _currentTempHysteresis();
    final humHysteresis = draftHumHysteresis ?? _currentHumHysteresis();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Histereza temperatury',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Chlodzenie wlaczy sie od ${(targetTemp + tempHysteresis).toStringAsFixed(1)} °C i wylaczy po zejsciu do ${targetTemp.toStringAsFixed(1)} °C',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '${tempHysteresis.toStringAsFixed(1)} °C',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: tempHysteresis,
                  min: 0,
                  max: 5,
                  divisions: 50,
                  label: '${tempHysteresis.toStringAsFixed(1)} °C',
                  onChanged: (value) =>
                      setState(() => draftTempHysteresis = value),
                  onChangeEnd: _saveTempHysteresis,
                ),
                if (savingTempHysteresis) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Histereza wilgotnosci',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Nawilzanie wlaczy sie ponizej ${(targetHumidity - humHysteresis).toStringAsFixed(1)} % i wylaczy po dojściu do ${targetHumidity.toStringAsFixed(1)} %',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '${humHysteresis.toStringAsFixed(1)} %',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: humHysteresis,
                  min: 0,
                  max: 20,
                  divisions: 40,
                  label: '${humHysteresis.toStringAsFixed(1)} %',
                  onChanged: (value) =>
                      setState(() => draftHumHysteresis = value),
                  onChangeEnd: _saveHumHysteresis,
                ),
                if (savingHumHysteresis) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('🔍 Skan ESP', style: TextStyle(fontSize: 20)),
        ElevatedButton(onPressed: scanDevices, child: const Text('Skanuj')),
        ElevatedButton.icon(
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Skanuj QR ESP'),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => QrPairingPage(api: api)),
            );
          },
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('Eksport CSV'),
          onPressed: exportHistoryCsv,
        ),
        SwitchListTile(
          title: const Text('Tryb demo'),
          subtitle: const Text('Pokazuj dane testowe bez ESP'),
          value: demoMode,
          onChanged: (value) => setState(() => demoMode = value),
        ),
        ...available.map(
          (d) => ListTile(
            title: Text(d['id'].toString()),
            subtitle: Text(
              d['online'] == true
                  ? 'Online • ${d['lastSeen'] ?? ''}'
                  : 'Brak danych live',
            ),
            trailing: ElevatedButton(
              onPressed: () async {
                try {
                  await api.addDevice(d['id'].toString());
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Dodano urzadzenie')),
                  );
                } catch (error) {
                  if (!mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              child: const Text('Dodaj'),
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF22C55E) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

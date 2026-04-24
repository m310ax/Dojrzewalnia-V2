import 'dart:async';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../mqtt_service.dart';
import '../widget_service.dart';
import '../widgets/control_slider.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow.dart';
import '../widgets/multi_chart.dart';
import 'tiles_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.enableAutoConnect = true,
    this.deviceRevision = 0,
  });

  final bool enableAutoConnect;
  final int deviceRevision;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  final api = ApiService();
  final mqtt = MqttService();

  double temp = 0;
  double hum = 0;
  RangeValues tempRange = const RangeValues(0, 4);
  RangeValues humRange = const RangeValues(78, 82);
  String aiText = 'Start...';
  String mode = 'AUTO';
  String deviceIp = '-';
  bool sensorConnected = false;
  bool wifiConnected = false;
  bool deviceOnline = false;
  bool isConnecting = false;
  bool isConnected = false;
  bool isLoadingDevices = false;
  bool _contentVisible = false;
  List<Map<String, dynamic>> devices = [];
  String selectedDevice = '';
  String selectedDeviceName = 'Brak urządzenia';

  final List<double> tempData = [];
  final List<double> humData = [];
  StreamSubscription<double>? _tempSubscription;
  StreamSubscription<double>? _humSubscription;
  StreamSubscription<bool>? _statusSubscription;
  Timer? _aiDebounce;
  Timer? _telemetryDebounce;
  bool _isAiUpdating = false;
  bool _humidityAlertTriggered = false;
  bool _isHistoryLoading = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _contentVisible = true);
      }
    });
    _tempSubscription = mqtt.tempStream.stream.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        temp = value;
        tempData.add(value);
        if (tempData.length > 30) {
          tempData.removeAt(0);
        }
        _updateAiStatus();
      });
      _scheduleAiRefresh();
      _scheduleTelemetryPersist();
      unawaited(_syncHomeWidget());
    });
    _humSubscription = mqtt.humStream.stream.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        hum = value;
        humData.add(value);
        if (humData.length > 30) {
          humData.removeAt(0);
        }
        _updateAiStatus();
      });
      _checkHumidityAlert();
      _scheduleAiRefresh();
      _scheduleTelemetryPersist();
      unawaited(_syncHomeWidget());
    });
    _statusSubscription = mqtt.statusStream.stream.listen((online) {
      if (!mounted) {
        return;
      }
      setState(() => deviceOnline = online);
      unawaited(_syncHomeWidget());
    });
    _initialize();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceRevision != widget.deviceRevision) {
      unawaited(loadDevices());
    }
  }

  Future<void> _initialize() async {
    await loadDevices();
    if (widget.enableAutoConnect) {
      await _connect();
    }
  }

  @override
  void dispose() {
    _aiDebounce?.cancel();
    _telemetryDebounce?.cancel();
    unawaited(_tempSubscription?.cancel());
    unawaited(_humSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    _pulse.dispose();
    mqtt.removeListener(_handleMessage);
    super.dispose();
  }

  void _updateAiStatus() {
    if (temp > tempRange.end) {
      aiText = 'Za ciepło';
    } else if (temp < tempRange.start) {
      aiText = 'Za zimno';
    } else if (hum < humRange.start) {
      aiText = 'Za sucho';
    } else if (hum > humRange.end) {
      aiText = 'Za wilgotno';
    } else {
      aiText = 'Stabilne warunki';
    }
  }

  Future<void> _syncHomeWidget() async {
    await WidgetService.updateDashboard(
      device: selectedDeviceName,
      temp: temp,
      hum: hum,
      online: deviceOnline,
    );
  }

  void _scheduleTelemetryPersist() {
    if (selectedDevice.isEmpty || !deviceOnline) {
      return;
    }

    _telemetryDebounce?.cancel();
    _telemetryDebounce = Timer(const Duration(seconds: 8), () {
      unawaited(_persistTelemetry());
    });
  }

  Future<void> _persistTelemetry() async {
    if (selectedDevice.isEmpty) {
      return;
    }

    try {
      await api.saveTelemetry(deviceId: selectedDevice, temp: temp, hum: hum);
    } catch (_) {
      // History is best-effort and should not break the live dashboard.
    }
  }

  Future<void> _loadHistory() async {
    if (selectedDevice.isEmpty || _isHistoryLoading) {
      return;
    }

    _isHistoryLoading = true;
    try {
      final history = await api.getHistory(deviceId: selectedDevice, limit: 60);
      if (!mounted) {
        return;
      }

      setState(() {
        tempData
          ..clear()
          ..addAll(
            history.map((item) => ((item['temp'] as num?) ?? 0).toDouble()),
          );
        humData
          ..clear()
          ..addAll(
            history.map((item) => ((item['hum'] as num?) ?? 0).toDouble()),
          );
      });
    } catch (_) {
      // Live chart still works when backend history is unavailable.
    } finally {
      _isHistoryLoading = false;
    }
  }

  void _scheduleAiRefresh() {
    if (selectedDevice.isEmpty || tempData.length < 5 || humData.length < 5) {
      return;
    }

    _aiDebounce?.cancel();
    _aiDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_refreshAiRecommendation());
    });
  }

  Future<void> _refreshAiRecommendation() async {
    if (_isAiUpdating || selectedDevice.isEmpty) {
      return;
    }

    _isAiUpdating = true;
    try {
      final recommendation = await api.getAiRecommendation(
        deviceId: selectedDevice,
        tempHistory: tempData,
        humHistory: humData,
        targetTemp: tempRange.end,
      );

      if (!mounted) {
        return;
      }

      final clamped = recommendation.clamp(tempRange.start, 25.0);
      if ((clamped - tempRange.end).abs() < 0.1) {
        return;
      }

      setState(() {
        tempRange = RangeValues(tempRange.start, clamped);
        aiText = 'AI koryguje do ${clamped.toStringAsFixed(1)}°C';
      });

      mqtt.send('curing/set/temp_max', clamped.toStringAsFixed(1));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        aiText = 'AI chwilowo niedostępne';
      });
    } finally {
      _isAiUpdating = false;
    }
  }

  Future<void> _checkHumidityAlert() async {
    if (selectedDevice.isEmpty) {
      return;
    }

    if (hum <= 83) {
      _humidityAlertTriggered = false;
      return;
    }

    if (_humidityAlertTriggered || hum <= 85) {
      return;
    }

    _humidityAlertTriggered = true;
    try {
      await api.evaluateHumidityAlert(
        deviceId: selectedDevice,
        temp: temp,
        humidity: hum,
      );
    } catch (_) {
      _humidityAlertTriggered = false;
    }
  }

  Future<void> _applyScene(String scene) async {
    if (selectedDevice.isEmpty) {
      return;
    }

    try {
      final response = await api.applyScene(
        deviceId: selectedDevice,
        scene: scene,
        tempHistory: tempData,
      );
      final commands = Map<String, dynamic>.from(response['commands'] as Map);
      final sceneTemp = (commands['temp'] as num).toDouble();
      final sceneHum = (commands['hum'] as num).toDouble();

      setState(() {
        tempRange = RangeValues(
          tempRange.start,
          sceneTemp.clamp(tempRange.start, 25.0),
        );
        humRange = RangeValues(
          humRange.start,
          sceneHum.clamp(humRange.start, 100.0),
        );
        aiText = 'Scena ${response['scene']} aktywna';
      });

      mqtt.send('curing/set/temp_max', sceneTemp.toStringAsFixed(1));
      mqtt.send('curing/set/hum_max', sceneHum.toStringAsFixed(0));
      mqtt.send('curing/set/scene', scene);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się zastosować sceny')),
      );
    }
  }

  Future<void> loadDevices() async {
    setState(() => isLoadingDevices = true);

    try {
      final loadedDevices = await api.getDevices();
      if (!mounted) {
        return;
      }

      final hasCurrentSelection = loadedDevices.any(
        (device) => device['id'] == selectedDevice,
      );
      final fallbackDevice = loadedDevices.isEmpty
          ? ''
          : (hasCurrentSelection
                ? selectedDevice
                : (mqtt.selectedDevice.isNotEmpty &&
                          loadedDevices.any(
                            (device) => device['id'] == mqtt.selectedDevice,
                          )
                      ? mqtt.selectedDevice
                      : loadedDevices.first['id'] as String));

      selectedDevice = fallbackDevice;
      selectedDeviceName = loadedDevices
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (device) => device['id'] == selectedDevice,
            orElse: () => {'name': 'Brak urządzenia'},
          )['name']
          .toString();

      devices = loadedDevices;
      await mqtt.subscribeDevice(selectedDevice);
      await _loadHistory();

      setState(() {
        isLoadingDevices = false;
        if (devices.isEmpty) {
          aiText = 'Brak urządzeń w backendzie';
          isConnected = false;
          selectedDeviceName = 'Brak urządzenia';
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        isLoadingDevices = false;
        aiText = 'Nie udało się pobrać listy urządzeń';
      });
    }
  }

  Future<void> _selectDevice(String deviceId) async {
    final matchingDevice = devices.firstWhere(
      (device) => device['id'] == deviceId,
      orElse: () => {'id': deviceId, 'name': deviceId},
    );

    await mqtt.subscribeDevice(deviceId);
    if (!mounted) {
      return;
    }

    setState(() {
      selectedDevice = deviceId;
      selectedDeviceName = matchingDevice['name'].toString();
      deviceIp = '-';
      sensorConnected = false;
      wifiConnected = false;
      deviceOnline = false;
      tempData.clear();
      humData.clear();
      aiText = 'Wybrane urządzenie: $selectedDeviceName';
    });
    _humidityAlertTriggered = false;
    await _loadHistory();
    await _syncHomeWidget();
  }

  void _updateTargetTemp(double value) {
    setState(() {
      final newEnd = value.clamp(tempRange.start, 25.0);
      tempRange = RangeValues(tempRange.start, newEnd);
      _updateAiStatus();
    });
    mqtt.send('curing/set/temp_max', value.toStringAsFixed(1));
  }

  void _updateTargetHum(double value) {
    setState(() {
      final newEnd = value.clamp(humRange.start, 100.0);
      humRange = RangeValues(humRange.start, newEnd);
      _updateAiStatus();
    });
    mqtt.send('curing/set/hum_max', value.toStringAsFixed(0));
  }

  Future<void> _connect() async {
    if (isConnecting) {
      return;
    }

    if (selectedDevice.isEmpty) {
      await loadDevices();
      if (!mounted || selectedDevice.isEmpty) {
        return;
      }
    }

    setState(() => isConnecting = true);
    final connected = await mqtt.connect(_handleMessage);

    if (!mounted) {
      return;
    }

    setState(() {
      isConnecting = false;
      isConnected = connected || mqtt.isConnected;
      if (!isConnected) {
        aiText = 'Brak połączenia z brokerem MQTT';
      }
    });
  }

  void _handleMessage(String topic, String msg) {
    if (!mounted) {
      return;
    }

    setState(() {
      isConnected = true;

      if (topic == 'curing/mode') {
        mode = msg;
      }
      if (topic == 'curing/set/temp_min') {
        final minValue = (double.tryParse(msg) ?? tempRange.start).clamp(
          0.0,
          25.0,
        );
        tempRange = RangeValues(minValue, tempRange.end.clamp(minValue, 25.0));
      }
      if (topic == 'curing/set/temp_max') {
        final maxValue = (double.tryParse(msg) ?? tempRange.end).clamp(
          0.0,
          25.0,
        );
        tempRange = RangeValues(tempRange.start.clamp(0.0, maxValue), maxValue);
      }
      if (topic == 'curing/set/hum_min') {
        final minValue = (double.tryParse(msg) ?? humRange.start).clamp(
          50.0,
          100.0,
        );
        humRange = RangeValues(minValue, humRange.end.clamp(minValue, 100.0));
      }
      if (topic == 'curing/set/hum_max') {
        final maxValue = (double.tryParse(msg) ?? humRange.end).clamp(
          50.0,
          100.0,
        );
        humRange = RangeValues(humRange.start.clamp(50.0, maxValue), maxValue);
      }
      if (topic == 'curing/device/ip') {
        deviceIp = msg;
      }
      if (topic == 'curing/device/sensor') {
        sensorConnected = msg == 'true';
      }
      if (topic == 'curing/device/wifi') {
        wifiConnected = msg == 'true';
      }
    });
  }

  Widget _status(String name, bool ok) {
    return Column(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: ok ? Colors.green : Colors.red,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(height: 6),
        Text(name, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  Widget _statCard(String title, String value, IconData icon, Color accent) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Glow(
          color: accent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 28, color: accent),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white60),
                  ),
                  const SizedBox(height: 5),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: Text(
                      value,
                      key: ValueKey(value),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title == 'Temp'
                        ? 'Target ${tempRange.start.toStringAsFixed(1)}-${tempRange.end.toStringAsFixed(1)}°C'
                        : 'Target ${humRange.start.toStringAsFixed(0)}-${humRange.end.toStringAsFixed(0)}%',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _historyChart() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Live Chart', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Temperatura i wilgotność w czasie rzeczywistym',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white60),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: MultiChart(temp: tempData, hum: humData),
          ),
        ],
      ),
    );
  }

  Widget _sceneButton(String label, String scene) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          onPressed: () => _applyScene(scene),
          child: Text(label),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B0F1A), Color(0xFF121A2A), Color(0xFF0A0F18)],
          ),
        ),
        child: SafeArea(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            opacity: _contentVisible ? 1 : 0,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Dashboard',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    ScaleTransition(
                      scale: Tween(begin: 0.9, end: 1.2).animate(_pulse),
                      child: Icon(
                        Icons.circle,
                        color: deviceOnline ? Colors.green : Colors.orange,
                        size: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  selectedDeviceName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _status('WiFi', wifiConnected),
                      _status('MQTT', isConnected),
                      _status('ESP', deviceOnline),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device selector',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedDevice.isEmpty
                            ? null
                            : selectedDevice,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          hintText: 'Wybierz urządzenie',
                        ),
                        items: devices.map<DropdownMenuItem<String>>((device) {
                          return DropdownMenuItem<String>(
                            value: device['id'].toString(),
                            child: Text(device['name'].toString()),
                          );
                        }).toList(),
                        onChanged: isLoadingDevices
                            ? null
                            : (value) {
                                if (value != null) {
                                  _selectDevice(value);
                                }
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _statCard(
                      'Temp',
                      '${temp.toStringAsFixed(1)}°C',
                      Icons.thermostat,
                      const Color(0xFF00F0FF),
                    ),
                    _statCard(
                      'Hum',
                      '${hum.toStringAsFixed(0)}%',
                      Icons.water_drop,
                      const Color(0xFF8A5CFF),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'HomeKit Tiles',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TilesPage(
                        temperature: '${temp.toStringAsFixed(1)}°C',
                        humidity: '${hum.toStringAsFixed(0)}%',
                        aiMode: _isAiUpdating ? 'SYNC' : 'ON',
                        ventilation: mode,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _historyChart(),
                const SizedBox(height: 20),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sterowanie',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Miękkie, responsywne slidery wysyłające targety MQTT w czasie rzeczywistym.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.white60),
                      ),
                      ControlSlider(
                        label: 'Temperatura maksymalna',
                        value: tempRange.end,
                        min: 0,
                        max: 10,
                        icon: Icons.thermostat,
                        accent: const Color(0xFF00F0FF),
                        onChanged: _updateTargetTemp,
                      ),
                      ControlSlider(
                        label: 'Wilgotność maksymalna',
                        value: humRange.end,
                        min: 50,
                        max: 100,
                        icon: Icons.water_drop,
                        accent: const Color(0xFF8A5CFF),
                        onChanged: _updateTargetHum,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _sceneButton('Night', 'night'),
                          _sceneButton('Dry', 'dry'),
                          _sceneButton('Boost', 'boost'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Glow(
                  child: GlassCard(
                    child: Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFF00F0FF),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text('AI: $aiText')),
                        FilledButton(
                          onPressed: isConnecting ? null : _connect,
                          child: Text(isConnecting ? 'Łączenie...' : 'Połącz'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

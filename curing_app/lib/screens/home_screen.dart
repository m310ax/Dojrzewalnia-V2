import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../device_provider.dart';
import '../models/device.dart';
import '../mqtt_service.dart';
import '../services/api_service.dart';
import '../widgets/device_card.dart';
import '../widgets/lux_card.dart';
import '../widgets/slider_control.dart';
import '../widgets/status_bar.dart';
import 'control_screen.dart';
import 'devices_screen.dart';

enum _DashboardMode { auto, ai, manual }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.enableAutoConnect = true});

  final bool enableAutoConnect;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final api = ApiService();
  final mqtt = MqttService();

  List<Device> devices = [];
  String? selected;
  double temp = 0;
  double hum = 0;
  double targetTemp = 18;
  double targetHum = 75;
  bool autoMode = true;
  bool aiEnabled = false;
  bool wifiOk = false;
  bool mqttOk = false;
  bool espOk = false;
  bool loading = true;
  bool aiBusy = false;
  bool autotuneBusy = false;
  bool coolingQuick = false;
  bool humidifierQuick = false;
  List<Map<String, dynamic>> history = [];
  Timer? _pollTimer;
  String? _observedProviderDeviceId;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    mqtt.removeListener(_handleMqttMessage);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final providerDeviceId = context.watch<DeviceProvider>().selectedDeviceId;
    if (providerDeviceId == _observedProviderDeviceId) {
      return;
    }

    _observedProviderDeviceId = providerDeviceId;
    if (providerDeviceId == null || providerDeviceId.isEmpty) {
      return;
    }

    if (providerDeviceId != selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_selectDevice(providerDeviceId));
        }
      });
    }
  }

  Future<void> _initialize() async {
    if (widget.enableAutoConnect) {
      final connected = await mqtt.connect(_handleMqttMessage);
      mqttOk = connected || mqtt.isConnected;
    }

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshAll());
    });

    await loadDevices();
  }

  Future<void> _refreshAll() async {
    await loadData();
    await loadHistory();
  }

  Future<void> loadDevices() async {
    final provider = context.read<DeviceProvider>();

    try {
      final data = await api.getDevices();
      final loadedDevices = data.map(Device.fromJson).toList();
      final preferred = provider.selectedDeviceId ?? mqtt.selectedDevice;

      String? nextSelected;
      if (loadedDevices.isNotEmpty) {
        final known = loadedDevices.any((device) => device.id == preferred);
        nextSelected = known ? preferred : loadedDevices.first.id;
      }

      if (nextSelected != null) {
        await mqtt.subscribeDevice(nextSelected);
        provider.setDevice(nextSelected);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        devices = loadedDevices;
        selected = nextSelected;
        loading = false;
      });

      await _refreshAll();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  double _doubleValue(dynamic value, [double fallback = 0]) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  bool _boolValue(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'on';
    }
    return false;
  }

  void _applyModeValue(String rawMode) {
    final normalized = rawMode.trim().toLowerCase();
    autoMode = normalized == 'auto';
    if (normalized == 'ai') {
      aiEnabled = true;
      autoMode = false;
      return;
    }

    if (normalized == 'manual') {
      aiEnabled = false;
    }
  }

  Future<void> loadData() async {
    if (selected == null || selected!.isEmpty) {
      return;
    }

    try {
      final d = await api.getDeviceData(deviceId: selected!);
      final modeData = await api.getPidMode(deviceId: selected!);
      final snapshot = Map<String, dynamic>.from(d['data'] as Map);

      if (!mounted) {
        return;
      }

      setState(() {
        temp = _doubleValue(snapshot['temp'], temp);
        hum = _doubleValue(snapshot['humidity'] ?? snapshot['hum'], hum);
        targetTemp = _doubleValue(snapshot['temp_max'], targetTemp);
        targetHum = _doubleValue(
          snapshot['hum_max'] ?? snapshot['humidity'],
          targetHum,
        );
        wifiOk = _boolValue(snapshot['wifi']);
        mqttOk = true;
        espOk = snapshot['status']?.toString() == 'online';
        aiEnabled = _boolValue(snapshot['ai_enabled']);
        autoMode = (modeData['mode']?.toString() ?? 'manual') == 'auto';
        if ((modeData['mode']?.toString() ?? 'manual') == 'ai') {
          autoMode = false;
          aiEnabled = true;
        }
        coolingQuick = _boolValue(snapshot['cool']);
        humidifierQuick = _boolValue(snapshot['hum_control']);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => mqttOk = mqtt.isConnected);
    }
  }

  Future<void> loadHistory() async {
    if (selected == null || selected!.isEmpty) {
      return;
    }

    try {
      final result = await api.getHistory(deviceId: selected!, limit: 40);
      if (!mounted) {
        return;
      }
      setState(() => history = result);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => history = const []);
    }
  }

  void _handleMqttMessage(String topic, String msg) {
    if (!mounted) {
      return;
    }

    setState(() {
      mqttOk = true;
      if (topic == 'curing/temp') {
        temp = double.tryParse(msg) ?? temp;
      }
      if (topic == 'curing/humidity') {
        hum = double.tryParse(msg) ?? hum;
      }
      if (topic.contains('status')) {
        espOk = msg == 'online';
      }
      if (topic == 'curing/device/wifi') {
        wifiOk = _boolValue(msg);
      }
      if (topic == 'curing/mode') {
        _applyModeValue(msg);
      }
      if (topic == 'control/ai') {
        aiEnabled = _boolValue(msg);
        if (aiEnabled) {
          autoMode = false;
        }
      }
      if (topic == 'curing/set/temp_max') {
        targetTemp = _doubleValue(msg, targetTemp);
      }
      if (topic == 'curing/set/hum_max') {
        targetHum = _doubleValue(msg, targetHum);
      }
    });
  }

  Future<void> _selectDevice(String? value) async {
    if (value == null || value.isEmpty) {
      return;
    }

    await mqtt.subscribeDevice(value);
    if (!mounted) {
      return;
    }

    context.read<DeviceProvider>().setDevice(value);
    setState(() => selected = value);
    await _refreshAll();
  }

  Future<void> _setTempTarget(double value) async {
    setState(() => targetTemp = value);
    if (selected == null) {
      return;
    }

    if (autoMode) {
      await api.setPidMode(
        deviceId: selected!,
        mode: 'auto',
        targetTemp: value,
      );
      return;
    }

    await api.sendControlCommand(
      deviceId: selected!,
      topic: 'curing/set/temp_max',
      value: value.toStringAsFixed(1),
    );
  }

  Future<void> _setHumTarget(double value) async {
    setState(() => targetHum = value);
    if (selected == null) {
      return;
    }

    await api.sendControlCommand(
      deviceId: selected!,
      topic: 'curing/set/hum_max',
      value: value.toStringAsFixed(1),
    );
  }

  Future<void> _toggleAutoMode(bool value) async {
    if (selected == null) {
      return;
    }

    setState(() => autoMode = value);
    await api.setPidMode(
      deviceId: selected!,
      mode: value ? 'auto' : 'manual',
      targetTemp: value ? targetTemp : null,
    );
    if (!value && aiEnabled) {
      await api.applyScene(deviceId: selected!, scene: 'ai_off');
      if (mounted) {
        setState(() => aiEnabled = false);
      }
    }

    await _refreshAll();
  }

  Future<void> _runAiControl() async {
    if (selected == null || aiBusy) {
      return;
    }

    setState(() => aiBusy = true);
    try {
      final rec = await api.getAiRecommendation(
        deviceId: selected!,
        tempHistory: _tempHistory().isEmpty ? [temp] : _tempHistory(),
        humHistory: _humHistory().isEmpty ? [hum] : _humHistory(),
        targetTemp: targetTemp,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        targetTemp = rec;
        aiEnabled = true;
        autoMode = false;
      });

      await api.setPidMode(deviceId: selected!, mode: 'manual');
      await api.applyScene(
        deviceId: selected!,
        scene: 'ai_on',
        tempHistory: _tempHistory(),
      );
      await api.sendControlCommand(
        deviceId: selected!,
        topic: 'curing/set/temp_max',
        value: rec.toStringAsFixed(1),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() => aiBusy = false);
      }
    }
  }

  Future<void> _enableAiMode() async {
    if (selected == null || selected!.isEmpty) {
      return;
    }

    await api.sendControlCommand(
      deviceId: selected!,
      topic: 'mode',
      value: 'ai',
    );

    if (!mounted) {
      return;
    }

    setState(() {
      autoMode = false;
      aiEnabled = true;
    });

    await _refreshAll();
  }

  Future<void> _startAutotune() async {
    if (selected == null || selected!.isEmpty || autotuneBusy) {
      return;
    }

    setState(() => autotuneBusy = true);
    try {
      await api.sendControlCommand(
        deviceId: selected!,
        topic: 'autotune',
        value: true,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AUTO-TUNE PID zakończony')),
      );
      await _refreshAll();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() => autotuneBusy = false);
      }
    }
  }

  Future<void> _setMode(_DashboardMode mode) async {
    if (selected == null || selected!.isEmpty) {
      return;
    }

    switch (mode) {
      case _DashboardMode.auto:
        await api.applyScene(deviceId: selected!, scene: 'ai_off');
        await api.setPidMode(
          deviceId: selected!,
          mode: 'auto',
          targetTemp: targetTemp,
        );
        if (mounted) {
          setState(() {
            autoMode = true;
            aiEnabled = false;
          });
        }
        await _refreshAll();
      case _DashboardMode.ai:
        await api.setPidMode(deviceId: selected!, mode: 'manual');
        await api.applyScene(
          deviceId: selected!,
          scene: 'ai_on',
          tempHistory: _tempHistory(),
        );
        if (mounted) {
          setState(() {
            autoMode = false;
            aiEnabled = true;
          });
        }
        await _refreshAll();
      case _DashboardMode.manual:
        await api.applyScene(deviceId: selected!, scene: 'ai_off');
        await api.setPidMode(deviceId: selected!, mode: 'manual');
        if (mounted) {
          setState(() {
            autoMode = false;
            aiEnabled = false;
          });
        }
        await _refreshAll();
    }
  }

  Future<void> _toggleQuickAction({
    required String topic,
    required bool nextValue,
    required void Function() updateLocalState,
  }) async {
    if (selected == null || selected!.isEmpty) {
      return;
    }

    setState(updateLocalState);

    try {
      await api.sendControlCommand(
        deviceId: selected!,
        topic: topic,
        value: nextValue ? 'on' : 'off',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      await _refreshAll();
    }
  }

  List<double> _tempHistory() {
    return history.map((entry) => _doubleValue(entry['temp'])).toList();
  }

  List<double> _humHistory() {
    return history.map((entry) => _doubleValue(entry['hum'])).toList();
  }

  _DashboardMode get _currentMode {
    if (aiEnabled) {
      return _DashboardMode.ai;
    }
    if (autoMode) {
      return _DashboardMode.auto;
    }
    return _DashboardMode.manual;
  }

  String get _selectedDeviceName {
    final match = devices.where((device) => device.id == selected);
    if (match.isEmpty) {
      return 'Brak urządzenia';
    }
    return match.first.name;
  }

  Widget _buildChart() {
    final tempSpots = history.asMap().entries.map((entry) {
      return FlSpot(
        entry.key.toDouble(),
        _doubleValue(entry.value['temp']).clamp(-20, 80).toDouble(),
      );
    }).toList();
    final humSpots = history.asMap().entries.map((entry) {
      return FlSpot(
        entry.key.toDouble(),
        _doubleValue(entry.value['hum']).clamp(0, 100).toDouble(),
      );
    }).toList();

    if (tempSpots.isEmpty && humSpots.isEmpty) {
      return const Center(child: Text('Brak historii pomiarów'));
    }

    return LineChart(
      LineChartData(
        minY: 0,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.white.withValues(alpha: 0.08),
            strokeWidth: 1,
          ),
        ),
        titlesData: const FlTitlesData(
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: tempSpots,
            isCurved: true,
            color: const Color(0xFFFF9F43),
            barWidth: 3,
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: humSpots,
            isCurved: true,
            color: const Color(0xFF54A0FF),
            barWidth: 3,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }

  Widget _buildModeChip(_DashboardMode mode, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _currentMode == mode,
      onSelected: selected == null ? null : (_) => unawaited(_setMode(mode)),
    );
  }

  Future<void> _openDevicesScreen() async {
    final added = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => DevicesScreen(api: api)),
    );

    await loadDevices();
    if (!mounted || added == null || added.isEmpty) {
      return;
    }

    await _selectDevice(added);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dojrzewalnia LUX'),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices),
            onPressed: _openDevicesScreen,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SizedBox(height: 8),
                  LuxCard(
                    child: DeviceStatusBar(
                      wifiOk: wifiOk,
                      mqttOk: mqttOk,
                      espOk: espOk,
                    ),
                  ),
                  LuxCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aktywna dojrzewalnia',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(selected),
                          initialValue: selected,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            hintText: 'Wybierz urządzenie',
                          ),
                          items: devices.map((d) {
                            return DropdownMenuItem(
                              value: d.id,
                              child: Text(d.name),
                            );
                          }).toList(),
                          onChanged: _selectDevice,
                        ),
                      ],
                    ),
                  ),
                  if (devices.isNotEmpty)
                    SizedBox(
                      height: 140,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: devices.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          return SizedBox(
                            width: 184,
                            child: DeviceCard(
                              device: device,
                              selected: device.id == selected,
                              onTap: () => unawaited(_selectDevice(device.id)),
                            ),
                          );
                        },
                      ),
                    ),
                  LuxCard(
                    child: Column(
                      children: [
                        Text(
                          _selectedDeviceName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '🌡 ${temp.toStringAsFixed(1)}°C',
                          style: const TextStyle(fontSize: 40),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '💧 ${hum.toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 32),
                        ),
                      ],
                    ),
                  ),
                  LuxCard(
                    child: SizedBox(height: 220, child: _buildChart()),
                  ),
                  LuxCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Suwaki docelowe',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        SliderControl(
                          label: 'Temperatura',
                          value: targetTemp,
                          min: 10,
                          max: 30,
                          suffix: '°C',
                          onChanged: (v) => unawaited(_setTempTarget(v)),
                        ),
                        SliderControl(
                          label: 'Wilgotność',
                          value: targetHum,
                          min: 30,
                          max: 90,
                          suffix: '%',
                          onChanged: (v) => unawaited(_setHumTarget(v)),
                        ),
                      ],
                    ),
                  ),
                  LuxCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tryb pracy',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _buildModeChip(_DashboardMode.auto, 'AUTO'),
                            _buildModeChip(_DashboardMode.ai, 'AI'),
                            _buildModeChip(_DashboardMode.manual, 'MANUAL'),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('AUTO'),
                          value: autoMode,
                          onChanged: selected == null
                              ? null
                              : (v) => unawaited(_toggleAutoMode(v)),
                        ),
                        ElevatedButton(
                          onPressed: selected == null || aiBusy
                              ? null
                              : _runAiControl,
                          child: Text(
                            aiBusy ? 'Liczenie AI...' : 'AI CONTROL',
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: selected == null ? null : _enableAiMode,
                          child: const Text('AI MODE'),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: selected == null || autotuneBusy
                              ? null
                              : _startAutotune,
                          child: Text(
                            autotuneBusy
                                ? 'AUTO-TUNE PID...'
                                : 'AUTO-TUNE PID',
                          ),
                        ),
                      ],
                    ),
                  ),
                  LuxCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quick actions',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton.filledTonal(
                              onPressed: selected == null
                                  ? null
                                  : () => unawaited(
                                      _toggleQuickAction(
                                        topic: 'control/cool',
                                        nextValue: !coolingQuick,
                                        updateLocalState: () {
                                          coolingQuick = !coolingQuick;
                                        },
                                      ),
                                    ),
                              icon: Icon(
                                Icons.ac_unit,
                                color: coolingQuick
                                    ? const Color(0xFF54A0FF)
                                    : Colors.white,
                              ),
                              tooltip: 'Chłodzenie',
                            ),
                            IconButton.filledTonal(
                              onPressed: selected == null
                                  ? null
                                  : () => unawaited(
                                      _toggleQuickAction(
                                        topic: 'control/humidifier',
                                        nextValue: !humidifierQuick,
                                        updateLocalState: () {
                                          humidifierQuick = !humidifierQuick;
                                        },
                                      ),
                                    ),
                              icon: Icon(
                                Icons.water_drop,
                                color: humidifierQuick
                                    ? const Color(0xFF7ED6DF)
                                    : Colors.white,
                              ),
                              tooltip: 'Wilgotność',
                            ),
                            IconButton.filledTonal(
                              onPressed: selected == null
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ControlScreen(
                                            api: api,
                                            deviceId: selected!,
                                          ),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.tune),
                              tooltip: 'Pełne sterowanie',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
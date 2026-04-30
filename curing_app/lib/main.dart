import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const panelBaseUrl = 'http://maluch2.mikr.us:30345';
const panelUser = String.fromEnvironment('PANEL_USER', defaultValue: 'admin');
const panelPassword = String.fromEnvironment('PANEL_PASSWORD');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CuringApp());
}

class CuringApp extends StatelessWidget {
  const CuringApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dojrzewalnia',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF17634F),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F0EA),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _client = http.Client();
  Timer? _timer;
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _history = [];
  List<CuringDevice> _devices = const [
    CuringDevice(id: 'dojrzewalnia-01', name: 'Dojrzewalnia 1'),
    CuringDevice(id: 'dojrzewalnia-02', name: 'Dojrzewalnia 2'),
  ];
  String _selectedDeviceId = 'dojrzewalnia-01';
  bool _brokerConnected = false;
  bool _loading = true;
  String? _error;

  String get _authHeader {
    final token = base64Encode(utf8.encode('$panelUser:$panelPassword'));
    return 'Basic $token';
  }

  Map<String, String> get _headers => {
    'Authorization': _authHeader,
    'Content-Type': 'application/json',
  };

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  double _numValue(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? double.nan;
    return double.nan;
  }

  bool _boolValue(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.toLowerCase().trim();
      return normalized == 'true' || normalized == '1' || normalized == 'on';
    }
    return false;
  }

  Future<void> _refresh() async {
    try {
      final encodedDevice = Uri.encodeQueryComponent(_selectedDeviceId);
      final statusResponse = await _client
          .get(
            Uri.parse('$panelBaseUrl/api/status?device=$encodedDevice'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 6));
      final historyResponse = await _client
          .get(
            Uri.parse(
              '$panelBaseUrl/api/history?device=$encodedDevice&limit=120',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 6));

      if (statusResponse.statusCode != 200 ||
          historyResponse.statusCode != 200) {
        throw Exception(
          'HTTP ${statusResponse.statusCode}/${historyResponse.statusCode}',
        );
      }

      final statusPayload =
          jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final historyPayload = jsonDecode(historyResponse.body) as List<dynamic>;
      final serverDevices = (statusPayload['devices'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map(
            (item) => CuringDevice(
              id: (item['id'] ?? '').toString(),
              name: (item['name'] ?? item['id'] ?? '').toString(),
            ),
          )
          .where((device) => device.id.isNotEmpty);

      if (!mounted) return;
      setState(() {
        _brokerConnected = _boolValue(statusPayload['brokerConnected']);
        _devices = _mergeDevices(_devices, serverDevices).take(2).toList();
        _status = statusPayload['status'] is Map
            ? Map<String, dynamic>.from(statusPayload['status'] as Map)
            : null;
        _history = historyPayload
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Brak polaczenia z panelem';
      });
    }
  }

  Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      final payload = {'deviceId': _selectedDeviceId, ...body};
      final response = await _client
          .post(
            Uri.parse('$panelBaseUrl$path'),
            headers: _headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udalo sie wyslac komendy')),
      );
    }
  }

  Future<void> _setMode(String mode) => _post('/api/mode', {'mode': mode});

  Future<void> _toggleRelay(String key) async {
    final relays = Map<String, dynamic>.from(
      (_status?['relays'] as Map?) ?? {},
    );
    final next = !_boolValue(relays[key]);
    await _post('/api/manual', {key: next});
  }

  List<CuringDevice> _mergeDevices(
    Iterable<CuringDevice> first,
    Iterable<CuringDevice> second,
  ) {
    final result = <String, CuringDevice>{};
    for (final device in [...first, ...second]) {
      if (device.id.trim().isEmpty) continue;
      result[device.id.trim()] = device;
    }
    return result.values.toList();
  }

  Future<void> _selectDevice(String id) async {
    setState(() {
      _selectedDeviceId = id;
      _loading = true;
    });
    await _refresh();
  }

  Future<void> _showDeviceDialog({CuringDevice? editing}) async {
    final idController = TextEditingController(text: editing?.id ?? '');
    final nameController = TextEditingController(text: editing?.name ?? '');

    final result = await showDialog<CuringDevice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          editing == null ? 'Dodaj dojrzewalnie' : 'Edytuj dojrzewalnie',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Nazwa'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                labelText: 'Device ID ESP',
                hintText: 'np. dojrzewalnia-02',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () {
              final id = idController.text.trim();
              if (id.isEmpty) return;
              Navigator.pop(
                context,
                CuringDevice(
                  id: id,
                  name: nameController.text.trim().isEmpty
                      ? id
                      : nameController.text.trim(),
                ),
              );
            },
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );

    idController.dispose();
    nameController.dispose();
    if (result == null) return;

    setState(() {
      final next = _devices
          .where((device) => device.id != editing?.id && device.id != result.id)
          .toList();
      if (editing == null && next.length >= 2) {
        next.removeLast();
      }
      next.add(result);
      _devices = next.take(2).toList();
      _selectedDeviceId = result.id;
      _loading = true;
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final temp = _numValue(status?['temperature']);
    final hum = _numValue(status?['humidity']);
    final relays = Map<String, dynamic>.from((status?['relays'] as Map?) ?? {});
    final mode = (status?['mode'] ?? 'auto').toString();
    final alarm = _boolValue(status?['alarm']);

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedDeviceName),
        actions: [
          IconButton(
            onPressed: _devices.length >= 2 ? null : () => _showDeviceDialog(),
            icon: const Icon(Icons.add_home_work_outlined),
            tooltip: 'Dodaj dojrzewalnie',
          ),
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Odswiez',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  if (_error != null)
                    _Banner(text: _error!, color: Colors.red.shade700),
                  _DevicePicker(
                    devices: _devices,
                    selectedDeviceId: _selectedDeviceId,
                    onChanged: _selectDevice,
                    onEdit: (device) => _showDeviceDialog(editing: device),
                    onAdd: _devices.length >= 2
                        ? null
                        : () => _showDeviceDialog(),
                  ),
                  const SizedBox(height: 12),
                  _ConnectionRow(
                    wifi: _boolValue(status?['wifiConnected']),
                    mqtt: _boolValue(status?['mqttConnected']),
                    broker: _brokerConnected,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _MetricCard(
                          label: 'Temperatura',
                          value: temp.isFinite
                              ? temp.toStringAsFixed(1)
                              : '--.-',
                          suffix: 'C',
                          color: const Color(0xFFC24B3A),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricCard(
                          label: 'Wilgotnosc',
                          value: hum.isFinite ? hum.toStringAsFixed(1) : '--.-',
                          suffix: '%',
                          color: const Color(0xFF2F7BBD),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Banner(
                    text: alarm
                        ? (status?['alarmMessage']?.toString() ??
                              'Alarm aktywny')
                        : 'Brak alarmu',
                    color: alarm
                        ? Colors.red.shade700
                        : const Color(0xFF17634F),
                  ),
                  const SizedBox(height: 12),
                  _Panel(
                    title: 'Tryb pracy',
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'auto', label: Text('Auto')),
                        ButtonSegment(value: 'manual', label: Text('Manual')),
                        ButtonSegment(value: 'pid', label: Text('PID')),
                      ],
                      selected: {mode},
                      onSelectionChanged: (selection) =>
                          _setMode(selection.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Panel(
                    title: 'Przekazniki',
                    child: GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.8,
                      children: [
                        _RelayButton(
                          label: 'Chlodzenie',
                          icon: Icons.ac_unit,
                          active: _boolValue(relays['cooling']),
                          onTap: () => _toggleRelay('cooling'),
                        ),
                        _RelayButton(
                          label: 'Nawilzacz',
                          icon: Icons.water_drop,
                          active: _boolValue(relays['humidifier']),
                          onTap: () => _toggleRelay('humidifier'),
                        ),
                        _RelayButton(
                          label: 'Osuszacz',
                          icon: Icons.air,
                          active: _boolValue(relays['dehumidifier']),
                          onTap: () => _toggleRelay('dehumidifier'),
                        ),
                        _RelayButton(
                          label: 'Wentylator',
                          icon: Icons.mode_fan_off,
                          active: _boolValue(relays['fan']),
                          onTap: () => _toggleRelay('fan'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Panel(
                    title: 'Historia',
                    child: SizedBox(
                      height: 230,
                      child: CustomPaint(
                        painter: _HistoryPainter(_history),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class CuringDevice {
  const CuringDevice({required this.id, required this.name});

  final String id;
  final String name;
}

extension _SelectedDeviceName on _DashboardPageState {
  String get _selectedDeviceName {
    for (final device in _devices) {
      if (device.id == _selectedDeviceId) {
        return device.name;
      }
    }
    return 'Dojrzewalnia';
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({
    required this.devices,
    required this.selectedDeviceId,
    required this.onChanged,
    required this.onEdit,
    required this.onAdd,
  });

  final List<CuringDevice> devices;
  final String selectedDeviceId;
  final ValueChanged<String> onChanged;
  final ValueChanged<CuringDevice> onEdit;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue:
                    devices.any((device) => device.id == selectedDeviceId)
                    ? selectedDeviceId
                    : devices.first.id,
                decoration: const InputDecoration(
                  labelText: 'Dojrzewalnia',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: devices
                    .map(
                      (device) => DropdownMenuItem(
                        value: device.id,
                        child: Text('${device.name}  (${device.id})'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) onChanged(value);
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: () {
                final match = devices.where(
                  (device) => device.id == selectedDeviceId,
                );
                onEdit(match.isEmpty ? devices.first : match.first);
              },
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edytuj',
            ),
            IconButton.filledTonal(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              tooltip: 'Dodaj',
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.wifi,
    required this.mqtt,
    required this.broker,
  });

  final bool wifi;
  final bool mqtt;
  final bool broker;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatusChip(label: 'Wi-Fi', active: wifi),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatusChip(label: 'MQTT', active: mqtt),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatusChip(label: 'VPS', active: broker),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF17634F) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF17634F) : Colors.black12,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            active ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.suffix,
    required this.color,
  });

  final String label;
  final String value;
  final String suffix;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            FittedBox(
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 48,
                      height: .95,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 5, bottom: 5),
                    child: Text(
                      suffix,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
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

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _RelayButton extends StatelessWidget {
  const _RelayButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: active
            ? const Color(0xFF17634F)
            : const Color(0xFFEAF0EC),
        foregroundColor: active ? Colors.white : const Color(0xFF12221E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter(this.history);

  final List<Map<String, dynamic>> history;

  double _value(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? double.nan;
    return double.nan;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFFBFCFB);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      bg,
    );

    final grid = Paint()
      ..color = const Color(0xFFD8DED9)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final data = history.length > 100
        ? history.sublist(history.length - 100)
        : history;
    if (data.length < 2) return;

    void drawLine(String key, Color color, double min, double max) {
      final path = Path();
      for (var i = 0; i < data.length; i++) {
        final raw = _value(data[i], key);
        if (!raw.isFinite) continue;
        final x = size.width * i / math.max(1, data.length - 1);
        final y =
            size.height -
            (size.height * ((raw - min) / math.max(1, max - min)));
        if (path.getBounds().isEmpty && i == 0) {
          path.moveTo(x, y.clamp(0, size.height));
        } else {
          path.lineTo(x, y.clamp(0, size.height));
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    drawLine('humidity', const Color(0xFF2F7BBD), 0, 100);
    drawLine('temperature', const Color(0xFFC24B3A), 0, 40);
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter oldDelegate) =>
      oldDelegate.history != history;
}

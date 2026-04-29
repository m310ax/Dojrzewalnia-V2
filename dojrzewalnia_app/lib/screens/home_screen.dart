import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/api_service.dart';
import '../widgets/chart_widget.dart';
import '../widgets/lux_card.dart';
import 'control_screen.dart';
import 'devices_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService api = ApiService();

  List<Device> devices = const [];
  String? selectedDeviceId;
  double temp = 0;
  double hum = 0;
  List<Map<String, dynamic>> history = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({String? forcedSelection}) async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final loadedDevices = await api.getDevices();
      final fallbackSelection = loadedDevices.isNotEmpty ? loadedDevices.first.id : null;
      final nextSelection = forcedSelection ??
          (loadedDevices.any((device) => device.id == selectedDeviceId)
              ? selectedDeviceId
              : fallbackSelection);

      Map<String, dynamic>? latestData;
      List<Map<String, dynamic>> loadedHistory = const [];

      if (nextSelection != null) {
        latestData = await api.getDeviceData(nextSelection);
        loadedHistory = await api.getHistory(nextSelection);
      }

      if (!mounted) {
        return;
      }

      final payload = latestData?['data'];
      final telemetry = payload is Map<String, dynamic> ? payload : const <String, dynamic>{};

      setState(() {
        devices = loadedDevices;
        selectedDeviceId = nextSelection;
        temp = (telemetry['temp'] as num?)?.toDouble() ?? 0;
        hum = (telemetry['hum'] as num?)?.toDouble() ?? 0;
        history = loadedHistory;
      });
    } catch (exception) {
      if (!mounted) {
        return;
      }

      setState(() {
        error = exception.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dojrzewalnia LUX'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final added = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => DevicesScreen(api: api),
                ),
              );
              if (added == true) {
                await load();
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              LuxCard(child: Text(error!))
            else if (devices.isEmpty)
              const LuxCard(
                child: Text('Brak dodanych urzadzen. Uzyj przycisku +, aby dodac ESP.'),
              )
            else ...[
              DropdownButtonFormField<String>(
                initialValue: selectedDeviceId,
                decoration: const InputDecoration(
                  labelText: 'Urzadzenie',
                  border: OutlineInputBorder(),
                ),
                items: devices.map((device) {
                  return DropdownMenuItem<String>(
                    value: device.id,
                    child: Text(device.id),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  load(forcedSelection: value);
                },
              ),
              LuxCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${temp.toStringAsFixed(1)} °C',
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${hum.toStringAsFixed(1)} % RH',
                      style: const TextStyle(fontSize: 28),
                    ),
                  ],
                ),
              ),
              LuxCard(
                child: SizedBox(
                  height: 240,
                  child: ChartWidget(data: history),
                ),
              ),
              ElevatedButton.icon(
                onPressed: selectedDeviceId == null
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ControlScreen(
                              api: api,
                              deviceId: selectedDeviceId!,
                            ),
                          ),
                        );
                      },
                icon: const Icon(Icons.tune),
                label: const Text('Sterowanie'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
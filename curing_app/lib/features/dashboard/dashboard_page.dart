import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage(this.api, {super.key});

  final Api api;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic>? status;
  List<Map<String, dynamic>> history = const [];
  final String deviceId = 'dojrzewalnia-01';

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> load() async {
    final s = await widget.api.getStatus(deviceId);
    final h = await widget.api.getHistory(deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      status = s['status'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(s['status'] as Map<String, dynamic>)
          : s;
      history = h;
    });
  }

  @override
  Widget build(BuildContext context) {
    final temp = status?['temperature'] ?? status?['temp'];
    final hum = status?['humidity'] ?? status?['hum'];

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Temperatura: $temp°C', style: const TextStyle(fontSize: 28)),
                Text('Wilgotnosc: $hum%', style: const TextStyle(fontSize: 28)),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => widget.api.setMode(deviceId, 'auto'),
                  child: const Text('AUTO'),
                ),
                ElevatedButton(
                  onPressed: () => widget.api.setMode(deviceId, 'manual'),
                  child: const Text('MANUAL'),
                ),
                ElevatedButton(
                  onPressed: () => widget.api.setMode(deviceId, 'ai'),
                  child: const Text('AI'),
                ),
                const SizedBox(height: 20),
                Text('Historia: ${history.length} probek'),
              ],
            ),
    );
  }
}
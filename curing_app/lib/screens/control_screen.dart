import 'package:flutter/material.dart';

import '../services/api_service.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({
    super.key,
    required this.api,
    required this.deviceId,
  });

  final ApiService api;
  final String deviceId;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  bool cooling = false;
  bool humidifier = false;

  Future<void> _send(String topic, bool value) async {
    await widget.api.sendControlCommand(
      deviceId: widget.deviceId,
      topic: topic,
      value: value ? 'on' : 'off',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Sterowanie ${widget.deviceId}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Cooling'),
            value: cooling,
            onChanged: (v) async {
              setState(() => cooling = v);
              await _send('control/cool', v);
            },
          ),
          SwitchListTile(
            title: const Text('Humidifier'),
            value: humidifier,
            onChanged: (v) async {
              setState(() => humidifier = v);
              await _send('control/humidifier', v);
            },
          ),
        ],
      ),
    );
  }
}
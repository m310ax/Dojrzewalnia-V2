import 'package:flutter/material.dart';

import '../services/api_service.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<DeviceInfo> _devices = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await widget.api.getDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Urzadzenia')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final device in _devices)
                  Card(
                    child: ListTile(
                      title: Text(device.name),
                      subtitle: Text(device.id),
                    ),
                  ),
              ],
            ),
    );
  }
}
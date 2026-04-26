import 'package:flutter/material.dart';

import '../api_service.dart';

class DiscoveredDevicesScreen extends StatefulWidget {
  const DiscoveredDevicesScreen({super.key});

  @override
  State<DiscoveredDevicesScreen> createState() =>
      _DiscoveredDevicesScreenState();
}

class _DiscoveredDevicesScreenState extends State<DiscoveredDevicesScreen> {
  final ApiService api = ApiService();

  List<Map<String, dynamic>> devices = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  Future<void> loadDevices() async {
    try {
      final result = await api.getDiscoveredDevices();
      if (!mounted) {
        return;
      }

      setState(() {
        devices = result;
        loading = false;
      });
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

  Future<void> addDevice(String id) async {
    try {
      await api.addDevice(id);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Dodano $id')));
      await loadDevices();
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  String _formatFirstSeen(dynamic value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(
        value * 1000,
      ).toLocal().toString();
    }
    return value?.toString() ?? '-';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wykryte urządzenia'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => loading = true);
              loadDevices();
            },
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : devices.isEmpty
          ? const Center(child: Text('Brak wykrytych ESP'))
          : ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                final id = device['id'].toString();

                return Card(
                  margin: const EdgeInsets.all(8),
                  child: ListTile(
                    title: Text(id),
                    subtitle: Text(
                      'Wykryto: ${_formatFirstSeen(device['first_seen'])}',
                    ),
                    trailing: ElevatedButton(
                      onPressed: () => addDevice(id),
                      child: const Text('Dodaj'),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

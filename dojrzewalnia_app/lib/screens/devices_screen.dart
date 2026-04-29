import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../widgets/lux_card.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<String> discoveredDevices = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final result = await widget.api.getDiscovered();
      if (!mounted) {
        return;
      }

      setState(() {
        discoveredDevices = result;
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
      appBar: AppBar(title: const Text('Wykryte ESP')),
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
              LuxCard(
                child: Text(error!),
              )
            else if (discoveredDevices.isEmpty)
              const LuxCard(
                child: Text('Brak nowych urzadzen w sieci.'),
              )
            else
              ...discoveredDevices.map(
                (deviceId) => LuxCard(
                  child: Row(
                    children: [
                      Expanded(child: Text(deviceId)),
                      ElevatedButton(
                        onPressed: () async {
                          final navigator = Navigator.of(context);
                          await widget.api.addDevice(deviceId);
                          if (!mounted) {
                            return;
                          }
                          navigator.pop(true);
                        },
                        child: const Text('Dodaj'),
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
}
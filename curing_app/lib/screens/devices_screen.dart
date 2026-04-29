import 'package:flutter/material.dart';

import '../services/api_service.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<String> discovered = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final d = await widget.api.getDiscovered();
      if (!mounted) {
        return;
      }
      setState(() {
        discovered = d;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wykryte ESP')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: discovered.isEmpty
                    ? const [
                        Padding(
                          padding: EdgeInsets.only(top: 32),
                          child: Center(child: Text('Brak wykrytych urządzeń')),
                        ),
                      ]
                    : discovered.map((id) {
                        return Card(
                          child: ListTile(
                            title: Text(id),
                            trailing: ElevatedButton(
                              child: const Text('Dodaj'),
                              onPressed: () async {
                                await widget.api.addDevice(id);
                                if (!context.mounted) {
                                  return;
                                }
                                Navigator.pop(context, id);
                              },
                            ),
                          ),
                        );
                      }).toList(),
              ),
            ),
    );
  }
}
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.deviceId});

  final String? deviceId;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final _api = ApiService();

  DeviceSnapshot? _snapshot;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DevicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId) {
      _load();
    }
  }

  Future<void> _load() async {
    final deviceId = widget.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      setState(() {
        _snapshot = null;
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final snapshot = await _api.getDeviceData(deviceId: deviceId);
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.deviceId == null) {
      return const Center(child: Text('Najpierw wybierz urzadzenie na dashboardzie.'));
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final snapshot = _snapshot;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device page', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(widget.deviceId!, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                if (_error != null)
                  Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.warn),
                  )
                else if (snapshot == null)
                  Text(
                    'Brak danych live dla wybranego urzadzenia.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final entry in snapshot.data.entries)
                        Container(
                          width: 220,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.panelAlt,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppTheme.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.key, style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 6),
                              Text(
                                entry.value.toString(),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
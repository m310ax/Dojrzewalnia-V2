import 'package:flutter/material.dart';

import 'api_service.dart';

class DeviceSelector extends StatefulWidget {
  const DeviceSelector({super.key, this.onChanged});

  final ValueChanged<String>? onChanged;

  @override
  State<DeviceSelector> createState() => _DeviceSelectorState();
}

class _DeviceSelectorState extends State<DeviceSelector> {
  final _api = ApiService();

  List<DeviceInfo> _devices = const [];
  String? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await _api.getDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _selected = devices.isEmpty ? null : devices.first.id;
      });
      if (_selected != null) {
        widget.onChanged?.call(_selected!);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = const [];
        _selected = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_devices.isEmpty) {
      return const Text('Brak urzadzen');
    }

    return DropdownButtonFormField<String>(
      initialValue: _selected,
      items: [
        for (final device in _devices)
          DropdownMenuItem<String>(
            value: device.id,
            child: Text(device.name),
          ),
      ],
      onChanged: (value) {
        if (value == null) {
          return;
        }
        setState(() => _selected = value);
        widget.onChanged?.call(value);
      },
      decoration: const InputDecoration(labelText: 'Urzadzenie'),
    );
  }
}
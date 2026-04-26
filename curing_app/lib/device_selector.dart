import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api_service.dart';
import 'device_provider.dart';

class DeviceSelector extends StatefulWidget {
  const DeviceSelector({super.key, this.onChanged});

  final ValueChanged<String>? onChanged;

  @override
  State<DeviceSelector> createState() => _DeviceSelectorState();
}

class _DeviceSelectorState extends State<DeviceSelector> {
  final api = ApiService();

  List<Map<String, dynamic>> devices = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  Future<void> loadDevices() async {
    try {
      final result = await api.getDevices();
      if (!mounted) {
        return;
      }

      setState(() {
        devices = result;
        loading = false;
      });

      _ensureSelection(result);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => loading = false);
    }
  }

  void _ensureSelection(List<Map<String, dynamic>> loadedDevices) {
    final provider = context.read<DeviceProvider>();

    if (loadedDevices.isEmpty) {
      provider.setDevice(null);
      return;
    }

    final ids = loadedDevices
        .map((device) => device['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final currentId = provider.selectedDeviceId;
    final fallbackId = currentId != null && ids.contains(currentId)
        ? currentId
        : loadedDevices.first['id']?.toString();

    if (fallbackId != null && fallbackId.isNotEmpty && currentId != fallbackId) {
      provider.setDevice(fallbackId);
      widget.onChanged?.call(fallbackId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DeviceProvider>();

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (devices.isEmpty) {
      return const Text('Brak urządzeń');
    }

    final availableIds = devices
        .map((device) => device['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final selectedId = provider.selectedDeviceId != null &&
            availableIds.contains(provider.selectedDeviceId)
        ? provider.selectedDeviceId
        : devices.first['id']?.toString();

    return DropdownButtonFormField<String>(
      key: ValueKey(selectedId),
      initialValue: selectedId,
      isExpanded: true,
      decoration: const InputDecoration(hintText: 'Wybierz urządzenie'),
      items: devices.map((device) {
        final deviceId = device['id']?.toString() ?? '';
        final deviceName = device['name']?.toString() ?? deviceId;
        return DropdownMenuItem<String>(
          value: deviceId,
          child: Text(deviceName),
        );
      }).toList(),
      onChanged: (value) {
        if (value == null || value.isEmpty) {
          return;
        }

        provider.setDevice(value);
        widget.onChanged?.call(value);
      },
    );
  }
}
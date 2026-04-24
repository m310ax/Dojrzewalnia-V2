import 'package:flutter/material.dart';

import '../api_service.dart';
import '../mqtt_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.onDevicesChanged});

  final VoidCallback onDevicesChanged;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _api = ApiService();
  final _mqtt = MqttService();

  bool _isLoading = false;
  bool _contentVisible = false;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _contentVisible = true);
      }
    });
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    try {
      final devices = await _api.getDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się pobrać urządzeń')),
      );
    }
  }

  Future<void> _showAddDeviceDialog() async {
    final idController = TextEditingController();
    final nameController = TextEditingController();

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dodaj urządzenie'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: 'ID urządzenia'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Nazwa urządzenia'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Dodaj'),
          ),
        ],
      ),
    );

    final id = idController.text.trim();
    final name = nameController.text.trim();
    idController.dispose();
    nameController.dispose();

    if (shouldSave != true) {
      return;
    }

    if (id.isEmpty || name.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Podaj ID i nazwę urządzenia')),
      );
      return;
    }

    try {
      await _api.addDevice(id, name);
      await _mqtt.subscribeDevice(id);
      await _loadDevices();
      widget.onDevicesChanged();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się dodać urządzenia')),
      );
    }
  }

  Future<void> _deleteDevice(String id) async {
    try {
      await _api.deleteDevice(id);
      if (_mqtt.selectedDevice == id) {
        await _mqtt.subscribeDevice('');
      }
      await _loadDevices();
      widget.onDevicesChanged();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się usunąć urządzenia')),
      );
    }
  }

  Future<void> _selectDevice(String id, String name) async {
    await _mqtt.subscribeDevice(id);
    widget.onDevicesChanged();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Wybrano urządzenie $name')));
    setState(() {});
  }

  Widget _deviceCard(Map<String, dynamic> device) {
    final id = device['id'].toString();
    final name = device['name'].toString();
    final isSelected = _mqtt.selectedDevice == id;
    final online = isSelected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glow(
        color: isSelected ? const Color(0xFF00F0FF) : const Color(0xFF8A5CFF),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: GlassCard(
            child: ListTile(
              onTap: () => _selectDevice(id, name),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.circle,
                color: online ? Colors.green : Colors.red,
                size: 14,
              ),
              title: Text(name),
              subtitle: Text(id, style: const TextStyle(color: Colors.white60)),
              trailing: IconButton(
                onPressed: () => _deleteDevice(id),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDeviceDialog,
        child: const Icon(Icons.add),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B0F1A), Color(0xFF121A2A), Color(0xFF0A0F18)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            opacity: _contentVisible ? 1 : 0,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  'Devices',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Premium lista komór z szybkim wyborem aktywnego urządzenia.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _mqtt.selectedDevice.isEmpty
                              ? 'Brak aktywnego urządzenia'
                              : 'Aktywne: ${_mqtt.selectedDevice}',
                        ),
                      ),
                      IconButton(
                        onPressed: _isLoading ? null : _loadDevices,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_devices.isEmpty && !_isLoading)
                  const GlassCard(
                    child: Text('Brak urządzeń. Dodaj pierwsze urządzenie.'),
                  )
                else
                  ..._devices.map(_deviceCard),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

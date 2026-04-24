import 'package:flutter/material.dart';

import '../mqtt_service.dart';
import '../widgets/glass_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final mqtt = MqttService();
  late final TextEditingController hostController;
  late final TextEditingController portController;

  double airTime = 10;
  double airInterval = 10;
  String profile = 'AUTO';
  bool _contentVisible = false;

  @override
  void initState() {
    super.initState();
    hostController = TextEditingController(text: mqtt.server);
    portController = TextEditingController(text: mqtt.port.toString());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _contentVisible = true);
      }
    });
  }

  @override
  void dispose() {
    hostController.dispose();
    portController.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final connected = mqtt.isConnected || await mqtt.connect();

    if (!mounted) {
      return;
    }

    if (!connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak połączenia z kontrolerem')),
      );
      return;
    }

    mqtt.send('curing/set/air_time', airTime.toString());
    mqtt.send('curing/set/air_interval', airInterval.toString());
    mqtt.send('curing/set/profile', profile);

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Zapisano')));
    setState(() {});
  }

  Future<void> saveConnectionSettings() async {
    final port = int.tryParse(portController.text.trim());
    final updated = await mqtt.configure(
      server: hostController.text,
      port: port ?? -1,
    );

    if (!mounted) {
      return;
    }

    if (!updated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Podaj poprawny adres brokera MQTT i port'),
        ),
      );
      return;
    }

    final connected = await mqtt.connect();

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          connected
              ? 'Połączono z brokerem ${mqtt.server}:${mqtt.port}'
              : 'Ustawienia zapisane, ale połączenie z brokerem nieudane',
        ),
      ),
    );
    setState(() {});
  }

  Widget _sliderField({
    required String label,
    required String value,
    required double sliderValue,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text(value)],
        ),
        Slider(value: sliderValue, min: min, max: max, onChanged: onChanged),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 500),
          opacity: _contentVisible ? 1 : 0,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(
                'Ustawienia',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Profile, parametry i konfiguracja połączenia.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Broker MQTT',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: hostController,
                      decoration: const InputDecoration(
                        labelText: 'Adres brokera MQTT',
                        hintText: 'np. broker.hivemq.cloud',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: saveConnectionSettings,
                      icon: const Icon(Icons.wifi_find_outlined),
                      label: const Text('ZAPISZ I POŁĄCZ'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Profile',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: profile,
                      items: ['AUTO', 'MANUAL', 'DRYING', 'AGING']
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => profile = value!),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Parametry',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    _sliderField(
                      label: 'Czas przewietrzania',
                      value: '${airTime.toStringAsFixed(0)} s',
                      sliderValue: airTime,
                      min: 5,
                      max: 60,
                      onChanged: (value) => setState(() => airTime = value),
                    ),
                    _sliderField(
                      label: 'Interwał',
                      value: '${airInterval.toStringAsFixed(0)} min',
                      sliderValue: airInterval,
                      min: 5,
                      max: 60,
                      onChanged: (value) => setState(() => airInterval = value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: send,
                icon: const Icon(Icons.save_outlined),
                label: const Text('ZAPISZ'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

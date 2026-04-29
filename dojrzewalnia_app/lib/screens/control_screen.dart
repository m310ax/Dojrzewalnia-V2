import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../widgets/lux_card.dart';

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
  bool busy = false;

  Future<void> toggleControl({
    required String topic,
    required bool value,
  }) async {
    setState(() {
      busy = true;
      if (topic == 'cooling') {
        cooling = value;
      } else {
        humidifier = value;
      }
    });

    try {
      await widget.api.sendControl(widget.deviceId, topic, value);
    } catch (exception) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(exception.toString())),
      );
      setState(() {
        if (topic == 'cooling') {
          cooling = !value;
        } else {
          humidifier = !value;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.deviceId)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          LuxCard(
            child: Column(
              children: [
                SwitchListTile(
                  value: cooling,
                  onChanged: busy
                      ? null
                      : (value) => toggleControl(topic: 'cooling', value: value),
                  title: const Text('Cooling'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: humidifier,
                  onChanged: busy
                      ? null
                      : (value) =>
                            toggleControl(topic: 'humidifier', value: value),
                  title: const Text('Humidifier'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
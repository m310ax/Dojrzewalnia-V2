import 'package:flutter/material.dart';

class DeviceStatusBar extends StatelessWidget {
  const DeviceStatusBar({
    super.key,
    required this.wifiOk,
    required this.mqttOk,
    required this.espOk,
  });

  final bool wifiOk;
  final bool mqttOk;
  final bool espOk;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _StatusPill(label: 'WiFi', ok: wifiOk),
        _StatusPill(label: 'MQTT', ok: mqttOk),
        _StatusPill(label: 'ESP', ok: espOk),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF2ED47A) : const Color(0xFFFF6B6B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 18, color: color),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}
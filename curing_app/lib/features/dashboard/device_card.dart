import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';

class DashboardDeviceCard extends StatelessWidget {
  const DashboardDeviceCard({
    super.key,
    required this.device,
    required this.selected,
    required this.temperature,
    required this.humidity,
    required this.quality,
    required this.mode,
    required this.online,
    required this.onTap,
  });

  final DeviceInfo device;
  final bool selected;
  final double temperature;
  final double humidity;
  final int quality;
  final String mode;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.panelAlt : AppTheme.panel,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: selected ? AppTheme.accent : AppTheme.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(device.name, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(device.id, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  _ModeChip(mode: mode),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _SmallMetric(
                      label: 'Temp',
                      value: '${temperature.isFinite ? temperature.toStringAsFixed(1) : '--.-'} C',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SmallMetric(
                      label: 'RH',
                      value: '${humidity.isFinite ? humidity.toStringAsFixed(0) : '--'}%',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SmallMetric(label: 'Siec', value: '$quality%'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: online ? AppTheme.accentSoft : const Color(0xFF3D2325),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    online ? 'online' : 'offline',
                    style: TextStyle(
                      color: online ? AppTheme.accent : const Color(0xFFFF9671),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final normalized = mode.toLowerCase();
    final color = switch (normalized) {
      'ai' => const Color(0xFF8C7BFF),
      'manual' => AppTheme.warn,
      _ => AppTheme.accent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}

class _SmallMetric extends StatelessWidget {
  const _SmallMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
import 'package:flutter/material.dart';

class TilesPage extends StatelessWidget {
  const TilesPage({
    super.key,
    required this.temperature,
    required this.humidity,
    required this.aiMode,
    required this.ventilation,
  });

  final String temperature;
  final String humidity;
  final String aiMode;
  final String ventilation;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      childAspectRatio: 1.18,
      children: [
        _tile('Temperatura', temperature, Icons.thermostat),
        _tile('Wilgotność', humidity, Icons.water_drop),
        _tile('AI Mode', aiMode, Icons.auto_awesome),
        _tile('Wentylacja', ventilation, Icons.air),
      ],
    );
  }

  Widget _tile(String title, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 32, color: Colors.cyan),
          const SizedBox(height: 10),
          Text(title),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(fontSize: 20)),
        ],
      ),
    );
  }
}

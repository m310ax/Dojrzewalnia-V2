import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class MultiChart extends StatelessWidget {
  const MultiChart({super.key, required this.temp, required this.hum});

  final List<double> temp;
  final List<double> hum;

  List<FlSpot> _spots(List<double> values) {
    if (values.isEmpty) {
      return const [FlSpot(0, 0), FlSpot(1, 0)];
    }

    return values
        .asMap()
        .entries
        .map((entry) => FlSpot(entry.key.toDouble(), entry.value))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final tempSpots = _spots(temp);
    final humSpots = _spots(hum);
    final maxX = [
      tempSpots.last.x,
      humSpots.last.x,
    ].reduce((value, element) => value > element ? value : element);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX <= 0 ? 1 : maxX,
        minY: 0,
        maxY: 100,
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: false),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            spots: tempSpots,
            gradient: const LinearGradient(colors: [Colors.cyan, Colors.blue]),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  Colors.cyan.withValues(alpha: 0.20),
                  Colors.transparent,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            dotData: const FlDotData(show: false),
            barWidth: 3,
          ),
          LineChartBarData(
            isCurved: true,
            spots: humSpots,
            gradient: const LinearGradient(
              colors: [Colors.purple, Colors.pink],
            ),
            dotData: const FlDotData(show: false),
            barWidth: 3,
          ),
        ],
      ),
    );
  }
}

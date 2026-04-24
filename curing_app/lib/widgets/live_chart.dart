import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class LiveChart extends StatefulWidget {
  const LiveChart({super.key, required this.data});

  final List<double> data;

  @override
  State<LiveChart> createState() => _LiveChartState();
}

class _LiveChartState extends State<LiveChart> {
  @override
  Widget build(BuildContext context) {
    final points = widget.data.isEmpty
        ? const [FlSpot(0, 0), FlSpot(1, 0)]
        : widget.data
              .asMap()
              .entries
              .map((entry) => FlSpot(entry.key.toDouble(), entry.value))
              .toList();

    return LineChart(
      LineChartData(
        minX: points.first.x,
        maxX: points.last.x <= points.first.x
            ? points.first.x + 1
            : points.last.x,
        minY: 0,
        maxY: 25,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            spots: points,
            dotData: const FlDotData(show: false),
            barWidth: 3,
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  Colors.cyan.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            gradient: const LinearGradient(colors: [Colors.cyan, Colors.blue]),
          ),
        ],
      ),
    );
  }
}

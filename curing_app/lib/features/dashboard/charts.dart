import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';

class TelemetryChart extends StatelessWidget {
  const TelemetryChart({
    super.key,
    required this.history,
    required this.showHumidityOnly,
  });

  final List<HistorySample> history;
  final bool showHumidityOnly;

  @override
  Widget build(BuildContext context) {
    if (history.length < 2) {
      return Center(
        child: Text(
          'Za malo danych do wykresu',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.muted),
        ),
      );
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: history.length.toDouble() - 1,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => const FlLine(color: AppTheme.line, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 42)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: history.length > 18 ? 6 : 3,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= history.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    history[index].label,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 10),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            tooltipRoundedRadius: 14,
            getTooltipColor: (_) => AppTheme.panelAlt,
          ),
        ),
        lineBarsData: [
          if (!showHumidityOnly)
            LineChartBarData(
              spots: [
                for (final point in history)
                  FlSpot(point.index, point.temperature.isFinite ? point.temperature : 0),
              ],
              isCurved: true,
              barWidth: 3,
              color: AppTheme.warn,
              dotData: const FlDotData(show: false),
            ),
          LineChartBarData(
            spots: [
              for (final point in history)
                FlSpot(point.index, point.humidity.isFinite ? point.humidity : 0),
            ],
            isCurved: true,
            barWidth: showHumidityOnly ? 4 : 3,
            color: AppTheme.info,
            belowBarData: BarAreaData(
              show: showHumidityOnly,
              gradient: LinearGradient(
                colors: [
                  AppTheme.info.withValues(alpha: 0.35),
                  AppTheme.info.withValues(alpha: 0.02),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );
  }
}
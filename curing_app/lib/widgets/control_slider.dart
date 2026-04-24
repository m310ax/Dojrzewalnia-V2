import 'package:flutter/material.dart';

class ControlSlider extends StatefulWidget {
  const ControlSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.icon = Icons.tune,
    this.accent = Colors.cyan,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final IconData icon;
  final Color accent;

  @override
  State<ControlSlider> createState() => _ControlSliderState();
}

class _ControlSliderState extends State<ControlSlider> {
  late double val;

  @override
  void initState() {
    super.initState();
    val = widget.value;
  }

  @override
  void didUpdateWidget(covariant ControlSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      val = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white60),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  val.toStringAsFixed(1),
                  key: ValueKey(val.toStringAsFixed(1)),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Icon(widget.icon, color: widget.accent),
            ],
          ),
          Slider(
            value: val.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            activeColor: widget.accent,
            onChanged: (value) {
              setState(() => val = value);
              widget.onChanged(value);
            },
          ),
        ],
      ),
    );
  }
}

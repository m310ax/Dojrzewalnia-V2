import 'package:flutter/material.dart';

class Glow extends StatelessWidget {
  const Glow({
    super.key,
    required this.child,
    this.color = const Color(0xFF00F0FF),
  });

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.28),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: child,
    );
  }
}

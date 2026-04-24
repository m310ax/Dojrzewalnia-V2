import 'package:flutter/material.dart';
import 'package:introduction_screen/introduction_screen.dart';

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return IntroductionScreen(
      globalBackgroundColor: const Color(0xFF0B0F1A),
      pages: [
        PageViewModel(
          title: 'Sterowanie IoT',
          body: 'Kontroluj swoje urządzenia z każdego miejsca',
          image: const Icon(Icons.devices, size: 100, color: Colors.cyan),
          decoration: _decoration,
        ),
        PageViewModel(
          title: 'Realtime',
          body: 'Dane na żywo przez MQTT',
          image: const Icon(Icons.show_chart, size: 100, color: Colors.cyan),
          decoration: _decoration,
        ),
        PageViewModel(
          title: 'AI Control',
          body: 'Automatyczne dostosowanie warunków',
          image: const Icon(Icons.auto_awesome, size: 100, color: Colors.cyan),
          decoration: _decoration,
        ),
      ],
      done: const Text('Start'),
      next: const Icon(Icons.arrow_forward),
      skip: const Text('Pomiń'),
      showSkipButton: true,
      onDone: onDone,
      onSkip: onDone,
      dotsDecorator: const DotsDecorator(
        activeColor: Colors.cyan,
        color: Colors.white24,
      ),
    );
  }

  static const PageDecoration _decoration = PageDecoration(
    titleTextStyle: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      color: Colors.white,
    ),
    bodyTextStyle: TextStyle(fontSize: 16, color: Colors.white70),
    pageColor: Color(0xFF0B0F1A),
    imagePadding: EdgeInsets.only(top: 48),
  );
}

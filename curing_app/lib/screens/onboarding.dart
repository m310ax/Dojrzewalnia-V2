import 'package:flutter/material.dart';

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Dojrzewalnia', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 12),
            Text(
              'Nowy onboarding zostal uproszczony podczas refaktoru. Wejdz od razu do panelu i zaloguj sie JWT.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onDone, child: const Text('Start')),
          ],
        ),
      ),
    );
  }
}
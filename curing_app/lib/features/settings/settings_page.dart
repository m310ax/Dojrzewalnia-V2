import 'package:flutter/material.dart';

import '../../core/auth.dart';
import '../../core/theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.onLogout});

  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ustawienia', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 12),
                Text(
                  'API base URL: ${AuthService.defaultBaseUrl}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Firebase Messaging jest podpiety po stronie kodu, ale w repo nie ma jeszcze plikow google-services.json ani GoogleService-Info.plist.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.muted),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () async => onLogout(),
                  icon: const Icon(Icons.logout),
                  label: const Text('Wyloguj'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
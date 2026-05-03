import 'package:flutter/material.dart';

import '../services/api_service.dart';

class ControlScreen extends StatelessWidget {
  const ControlScreen({
    super.key,
    required this.api,
    required this.deviceId,
  });

  final ApiService api;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Sterowanie $deviceId')),
      body: const Center(
        child: Text('Manualne sterowanie zostalo przeniesione do nowego dashboardu.'),
      ),
    );
  }
}
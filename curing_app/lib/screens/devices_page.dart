import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'devices_screen.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.onDevicesChanged});

  final VoidCallback onDevicesChanged;

  @override
  Widget build(BuildContext context) {
    return DevicesScreen(api: ApiService());
  }
}
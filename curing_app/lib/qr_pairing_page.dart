import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api_service.dart';

class QrPairingPage extends StatelessWidget {
  const QrPairingPage({super.key, required this.api});

  final ApiService api;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skanuj ESP')),
      body: MobileScanner(
        onDetect: (capture) async {
          final value = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
          if (value == null) {
            return;
          }

          try {
            final data = jsonDecode(value);
            final id = data['id']?.toString();
            final name = data['name']?.toString();

            if (id == null || id.isEmpty) {
              return;
            }

            await api.addDevice(id, name: name);

            if (context.mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Przypisano $id')),
              );
            }
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nieprawidłowy QR')),
              );
            }
          }
        },
      ),
    );
  }
}
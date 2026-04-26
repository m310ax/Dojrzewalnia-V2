import 'package:flutter/material.dart';

class DeviceProvider extends ChangeNotifier {
  DeviceProvider({String? initialDeviceId})
    : selectedDeviceId = _normalize(initialDeviceId);

  String? selectedDeviceId;

  void setDevice(String? id) {
    final normalizedId = _normalize(id);
    if (selectedDeviceId == normalizedId) {
      return;
    }

    selectedDeviceId = normalizedId;
    notifyListeners();
  }

  static String? _normalize(String? id) {
    final normalizedId = id?.trim() ?? '';
    if (normalizedId.isEmpty) {
      return null;
    }

    return normalizedId;
  }
}
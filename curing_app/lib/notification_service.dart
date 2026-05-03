import 'package:flutter/foundation.dart';

class NotificationService {
  factory NotificationService() => _instance;

  NotificationService._internal();

  static final NotificationService _instance = NotificationService._internal();

  bool _initialized = false;
  final messages = const Stream<Object?>.empty();

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    debugPrint('NotificationService.initialize skipped: Firebase dependencies removed from pubspec.yaml');
    _initialized = true;
  }
}

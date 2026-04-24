import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_service.dart';
import 'auth_service.dart';

class NotificationService {
  factory NotificationService() => _instance;

  NotificationService._internal();

  static final NotificationService _instance = NotificationService._internal();

  bool _initialized = false;
  final messages = Stream<RemoteMessage>.multi((controller) {
    FirebaseMessaging.onMessage.listen((message) {
      controller.add(message);
    });
  });

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    try {
      await Firebase.initializeApp();
      await FirebaseMessaging.instance.requestPermission();

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty && AuthService().token != null) {
        await ApiService().registerFcmToken(token);
      }

      FirebaseMessaging.onMessage.listen((message) {
        print('Push: ${message.notification?.title}');
      });

      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }
}

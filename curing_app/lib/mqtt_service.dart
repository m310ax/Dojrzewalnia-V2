import 'dart:async';

class MqttService {
  factory MqttService() => _instance;

  MqttService._internal();

  static final MqttService _instance = MqttService._internal();

  final tempStream = StreamController<double>.broadcast();
  final humStream = StreamController<double>.broadcast();
  final statusStream = StreamController<bool>.broadcast();

  String get server => 'yasmin345.mikrus.xyz';
  int get port => 20345;
  String get selectedDevice => '';
  bool get isConnected => false;

  Future<void> loadSettings() async {}
  Future<void> connect() async {}
  Future<void> disconnect() async {}
  Future<void> saveBroker(String server, int port) async {}
  Future<void> setSelectedDevice(String deviceId) async {}
  Future<void> publish(String topic, String message) async {}
  void addListener(void Function(String topic, String msg) listener) {}
  void removeListener(void Function(String topic, String msg) listener) {}
}

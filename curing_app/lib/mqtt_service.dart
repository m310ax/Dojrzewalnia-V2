import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MqttService {
  factory MqttService() => _instance;

  MqttService._internal();

  static final MqttService _instance = MqttService._internal();

  static const String defaultServer =
      'd4a0e9aff5804eb4bb95c4032b227373.s1.eu.hivemq.cloud';
  static const int defaultPort = 8883;
  static const String _username = 'maiek929';
  static const String _password = 'M#Je08hRnSK';
  static const String _serverPrefsKey = 'mqtt_broker_server';
  static const String _portPrefsKey = 'mqtt_broker_port';
  static const String _devicePrefsKey = 'mqtt_selected_device';

  final tempStream = StreamController<double>.broadcast();
  final humStream = StreamController<double>.broadcast();
  final statusStream = StreamController<bool>.broadcast();

  final List<void Function(String topic, String msg)> _listeners = [];
  bool _isConnecting = false;
  bool _connected = false;
  String _server = defaultServer;
  int _port = defaultPort;
  bool _settingsLoaded = false;
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
  _updatesSubscription;
  late final String _clientIdentifier =
      'curing-app-${DateTime.now().millisecondsSinceEpoch}';
  String _selectedDevice = '';

  String get server => _server;
  int get port => _port;
  String get selectedDevice => _selectedDevice;

  bool get isConnected => _connected;

  Future<void> loadSettings() async {
    if (_settingsLoaded) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _server = prefs.getString(_serverPrefsKey) ?? defaultServer;
    _port = prefs.getInt(_portPrefsKey) ?? defaultPort;
    _selectedDevice = prefs.getString(_devicePrefsKey) ?? '';
    _settingsLoaded = true;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverPrefsKey, _server);
    await prefs.setInt(_portPrefsKey, _port);
  }

  Future<void> _saveSelectedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_devicePrefsKey, _selectedDevice);
  }

  void _emit(String topic, dynamic value) {
    final message = value.toString();
    for (final listener in List.of(_listeners)) {
      listener(topic, message);
    }
  }

  String _deviceTopicPrefix(String deviceId) => 'devices/$deviceId/';

  String _deviceTopicFilter(String deviceId) =>
      '${_deviceTopicPrefix(deviceId)}curing/#';

  String? _logicalTopic(String incomingTopic) {
    if (_selectedDevice.isEmpty) {
      return null;
    }

    final prefix = _deviceTopicPrefix(_selectedDevice);
    if (!incomingTopic.startsWith(prefix)) {
      return null;
    }

    return incomingTopic.substring(prefix.length);
  }

  String? _scopedTopic(String logicalTopic) {
    if (_selectedDevice.isEmpty) {
      return null;
    }
    return '${_deviceTopicPrefix(_selectedDevice)}$logicalTopic';
  }

  void _subscribeCurrentDevice(MqttServerClient client) {
    if (_selectedDevice.isEmpty) {
      return;
    }
    client.subscribe(_deviceTopicFilter(_selectedDevice), MqttQos.atLeastOnce);
  }

  MqttServerClient _createClient() {
    final client = MqttServerClient.withPort(_server, _clientIdentifier, _port);
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.secure = true;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.setProtocolV311();
    client.onConnected = () => _connected = true;
    client.onDisconnected = () => _connected = false;
    client.onAutoReconnect = () => _connected = false;
    client.onAutoReconnected = () {
      _connected = true;
      _subscribeCurrentDevice(client);
    };
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(_clientIdentifier)
        .authenticateAs(_username, _password)
        .startClean();
    return client;
  }

  void _handleUpdates(List<MqttReceivedMessage<MqttMessage>>? events) {
    if (events == null) {
      return;
    }

    for (final event in events) {
      final logicalTopic = _logicalTopic(event.topic);
      if (logicalTopic == null) {
        continue;
      }

      final payload = event.payload as MqttPublishMessage;
      final message = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );

      if (logicalTopic == 'curing/temp') {
        tempStream.add(double.tryParse(message) ?? 0);
      }
      if (logicalTopic == 'curing/humidity') {
        humStream.add(double.tryParse(message) ?? 0);
      }
      if (logicalTopic.contains('status')) {
        statusStream.add(message == 'online');
      }

      _emit(logicalTopic, message);
    }
  }

  bool _publish(String topic, String value) {
    final client = _client;
    final scopedTopic = _scopedTopic(topic);
    if (client == null || !isConnected || scopedTopic == null) {
      return false;
    }

    final builder = MqttClientPayloadBuilder()..addString(value);
    client.publishMessage(scopedTopic, MqttQos.atLeastOnce, builder.payload!);
    return true;
  }

  bool sendRange({
    required String minKey,
    required String maxKey,
    required double minValue,
    required double maxValue,
  }) {
    if (!isConnected) {
      return false;
    }

    final minSent = _publish('curing/set/$minKey', minValue.toString());
    final maxSent = _publish('curing/set/$maxKey', maxValue.toString());
    return minSent && maxSent;
  }

  Future<void> subscribeDevice(String deviceId) async {
    await loadSettings();

    final normalizedId = deviceId.trim();
    final client = _client;
    final previousDevice = _selectedDevice;

    if (client != null &&
        previousDevice.isNotEmpty &&
        previousDevice != normalizedId) {
      client.unsubscribe(_deviceTopicFilter(previousDevice));
    }

    _selectedDevice = normalizedId;
    await _saveSelectedDevice();

    if (client != null &&
        client.connectionStatus?.state == MqttConnectionState.connected) {
      _subscribeCurrentDevice(client);
    }
  }

  Future<bool> configure({required String server, required int port}) async {
    await loadSettings();

    final normalizedServer = server.trim();
    if (normalizedServer.isEmpty || port <= 0 || port > 65535) {
      return false;
    }

    final needsReconnect = normalizedServer != _server || port != _port;

    if (!needsReconnect) {
      return true;
    }

    disconnect();
    _server = normalizedServer;
    _port = port;
    await _saveSettings();
    return true;
  }

  Future<bool> connect([
    void Function(String topic, String msg)? onData,
  ]) async {
    await loadSettings();

    if (onData != null && !_listeners.contains(onData)) {
      _listeners.add(onData);
    }

    if (isConnected) {
      return true;
    }

    if (_isConnecting) {
      return false;
    }

    _isConnecting = true;

    try {
      final client = _createClient();
      _client = client;
      await _updatesSubscription?.cancel();

      await client.connect(_username, _password);
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        disconnect();
        return false;
      }

      _updatesSubscription = client.updates?.listen(_handleUpdates);
      _subscribeCurrentDevice(client);
      _connected = true;
      return true;
    } catch (_) {
      disconnect();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  void removeListener(void Function(String topic, String msg) onData) {
    _listeners.remove(onData);
  }

  void disconnect() {
    unawaited(_updatesSubscription?.cancel());
    _updatesSubscription = null;
    _client?.disconnect();
    _client = null;
    _connected = false;
    _isConnecting = false;
  }

  bool send(String topic, String value) {
    return _publish(topic, value);
  }
}

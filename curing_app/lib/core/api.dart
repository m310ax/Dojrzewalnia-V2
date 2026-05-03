import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart';

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DeviceInfo {
  const DeviceInfo({required this.id, required this.name});

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString();
    return DeviceInfo(id: id, name: (json['name'] ?? id).toString());
  }

  final String id;
  final String name;
}

class DeviceSnapshot {
  const DeviceSnapshot({
    required this.deviceId,
    required this.topic,
    required this.time,
    required this.data,
  });

  factory DeviceSnapshot.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    return DeviceSnapshot(
      deviceId: (json['device_id'] ?? '').toString(),
      topic: json['topic']?.toString(),
      time: _parseDate(json['time']),
      data: rawData is Map ? Map<String, dynamic>.from(rawData) : const {},
    );
  }

  final String deviceId;
  final String? topic;
  final DateTime? time;
  final Map<String, dynamic> data;

  dynamic operator [](String key) {
    switch (key) {
      case 'device_id':
        return deviceId;
      case 'topic':
        return topic;
      case 'time':
        return time;
      case 'data':
        return data;
      default:
        return data[key];
    }
  }

  static DateTime? _parseDate(dynamic raw) {
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(
        raw * 1000,
        isUtc: true,
      ).toLocal();
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        raw.toInt() * 1000,
        isUtc: true,
      ).toLocal();
    }
    if (raw is String) {
      return DateTime.tryParse(raw)?.toLocal();
    }
    return null;
  }

  double number(String key, [double fallback = double.nan]) {
    final value = data[key];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  bool boolean(String key) {
    final value = data[key];
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'on';
    }
    return false;
  }
}

class HistorySample {
  const HistorySample({
    required this.index,
    required this.label,
    required this.temperature,
    required this.humidity,
  });

  factory HistorySample.fromJson(Map<String, dynamic> json, int index) {
    double parse(dynamic value) {
      if (value is num) {
        return value.toDouble();
      }
      if (value is String) {
        return double.tryParse(value) ?? double.nan;
      }
      return double.nan;
    }

    final rawLabel =
        json['time'] ?? json['label'] ?? json['timestamp'] ?? '$index';
    return HistorySample(
      index: index.toDouble(),
      label: rawLabel.toString(),
      temperature: parse(json['temp'] ?? json['temperature']),
      humidity: parse(json['hum'] ?? json['humidity']),
    );
  }

  final double index;
  final String label;
  final double temperature;
  final double humidity;

  dynamic operator [](String key) {
    switch (key) {
      case 'temp':
      case 'temperature':
        return temperature;
      case 'hum':
      case 'humidity':
        return humidity;
      case 'label':
      case 'time':
      case 'created_at':
        return label;
      default:
        return null;
    }
  }
}

class Api {
  Api(this.baseUrl, [this.token]);

  static const Duration _requestTimeout = Duration(seconds: 6);
  static const String _tokenKey = 'auth_token';

  final String baseUrl;
  String? token;

  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (token != null && token!.isNotEmpty) 'Authorization': 'Basic $token',
  };

  Future<void> loadToken() async {
    final preferences = await SharedPreferences.getInstance();
    token = preferences.getString(_tokenKey);
  }

  Future<bool> login(String email, String password) async {
    final basicToken = base64Encode(utf8.encode('$email:$password'));
    final response = await http
        .get(
          Uri.parse('$baseUrl/api/devices'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Basic $basicToken',
          },
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      return false;
    }

    token = basicToken;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_tokenKey, basicToken);
    return true;
  }

  Future<void> logout() async {
    token = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
  }

  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    final response = await http
        .get(
          Uri.parse('$baseUrl/api/status?device=$deviceId'),
          headers: headers,
        )
        .timeout(_requestTimeout);
    return decodeMap(response, 'Nie udalo sie pobrac statusu urzadzenia');
  }

  Future<List<Map<String, dynamic>>> getHistory(
    String deviceId, {
    int limit = 50,
  }) async {
    final response = await http
        .get(
          Uri.parse('$baseUrl/api/history?device=$deviceId&limit=$limit'),
          headers: headers,
        )
        .timeout(_requestTimeout);
    return decodeList(response, 'Nie udalo sie pobrac historii');
  }

  Future<void> setMode(String deviceId, String mode) async {
    await http
        .post(
          Uri.parse('$baseUrl/api/mode'),
          headers: headers,
          body: jsonEncode({'device_id': deviceId, 'mode': mode}),
        )
        .timeout(_requestTimeout);
  }

  Future<void> setModeAdvanced(
    String deviceId,
    String mode, {
    double? targetTemp,
  }) async {
    final payload = <String, dynamic>{'device_id': deviceId, 'mode': mode};
    if (targetTemp != null) {
      payload['target_temp'] = targetTemp;
    }

    final response = await http
        .post(
          Uri.parse('$baseUrl/mode'),
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(_requestTimeout);
    ensureSuccess(response, 'Nie udalo sie zapisac trybu pracy');
  }

  Future<void> setManual(String deviceId, String topic, Object value) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/control'),
          headers: headers,
          body: jsonEncode({
            'device_id': deviceId,
            'topic': topic,
            'value': value,
          }),
        )
        .timeout(_requestTimeout);
    ensureSuccess(response, 'Nie udalo sie wyslac komendy manualnej');
  }
}

void ensureSuccess(http.Response response, String message) {
  if (response.statusCode == 200) {
    return;
  }

  final trimmed = response.body.trimLeft();
  if (trimmed.startsWith('<')) {
    throw ApiException('Serwer zwrocil HTML zamiast odpowiedzi API');
  }

  try {
    final payload = jsonDecode(response.body);
    if (payload is Map<String, dynamic>) {
      final error = payload['error'] ?? payload['message'];
      if (error is String && error.isNotEmpty) {
        throw ApiException(error);
      }
    }
  } on FormatException {
    throw ApiException('$message (${response.statusCode})');
  }

  throw ApiException('$message (${response.statusCode})');
}

Map<String, dynamic> decodeMap(http.Response response, String message) {
  ensureSuccess(response, message);
  try {
    final payload = jsonDecode(response.body);
    if (payload is Map<String, dynamic>) {
      return payload;
    }
  } on FormatException {
    throw ApiException('Serwer zwrocil nieprawidlowy JSON');
  }
  throw ApiException(message);
}

List<Map<String, dynamic>> decodeList(http.Response response, String message) {
  ensureSuccess(response, message);
  try {
    final payload = jsonDecode(response.body);
    if (payload is List<dynamic>) {
      return payload
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    }
  } on FormatException {
    throw ApiException('Serwer zwrocil nieprawidlowy JSON');
  }
  throw ApiException(message);
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class ApiService {
  ApiService({String? baseUrl, AuthService? auth})
    : baseUrl = AuthService.normalizeBaseUrl(
        baseUrl ?? AuthService.defaultBaseUrl,
      ),
      _auth = auth ?? AuthService();

  static const Duration _requestTimeout = Duration(seconds: 6);

  final String baseUrl;
  final AuthService _auth;

  Api _client() {
    final token = _auth.token;
    if (token == null || token.isEmpty) {
      throw ApiException('Brak tokenu logowania');
    }
    return Api(baseUrl, token);
  }

  Map<String, String> get _headers => Api(baseUrl, _auth.token).headers;

  Map<String, dynamic> _normalizePanelStatus(Map<String, dynamic> status) {
    final temperature = status['temp'] ?? status['temperature'];
    final humidity = status['hum'] ?? status['humidity'];
    final targetTemp =
        status['target_temp'] ??
        status['targetTemp'] ??
        status['targetTemperature'];
    final targetHumidity =
        status['target_humidity'] ??
        status['targetHum'] ??
        status['targetHumidity'] ??
        status['humidityTarget'];
    final tempHysteresis =
        status['temp_hysteresis'] ?? status['tempHysteresis'];
    final humHysteresis = status['hum_hysteresis'] ?? status['humHysteresis'];
    return {
      ...status,
      'temp': temperature,
      'temperature': temperature,
      'hum': humidity,
      'humidity': humidity,
      'target_temp': targetTemp,
      'targetTemp': targetTemp,
      'target_humidity': targetHumidity,
      'targetHum': targetHumidity,
      'temp_hysteresis': tempHysteresis,
      'tempHysteresis': tempHysteresis,
      'hum_hysteresis': humHysteresis,
      'humHysteresis': humHysteresis,
      'wifi': status['wifi'] ?? status['wifiOk'],
      'mqtt': status['mqtt'] ?? status['brokerConnected'],
    };
  }

  Future<List<DeviceInfo>> getDevices() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/devices'),
      headers: _headers,
    );
    final decoded = decodeList(response, 'Nie udalo sie pobrac urzadzen');
    return decoded.map(DeviceInfo.fromJson).toList();
  }

  Future<DeviceSnapshot> getDeviceData({required String deviceId}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/status?device=$deviceId'),
      headers: _headers,
    );
    final decoded = decodeMap(
      response,
      'Nie udalo sie pobrac danych live urzadzenia',
    );
    final rawStatus = decoded['status'];
    final normalized = rawStatus is Map<String, dynamic>
        ? _normalizePanelStatus(rawStatus)
        : <String, dynamic>{};
    return DeviceSnapshot(
      deviceId: deviceId,
      topic: 'api/status',
      time: DateTime.now(),
      data: normalized,
    );
  }

  Future<List<HistorySample>> getHistory({
    required String deviceId,
    int limit = 60,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/history?device=$deviceId&limit=$limit'),
      headers: _headers,
    );
    final decoded = decodeList(response, 'Nie udalo sie pobrac historii');
    return [
      for (var index = 0; index < decoded.length; index++)
        HistorySample.fromJson({
          'temp': decoded[index]['temp'] ?? decoded[index]['temperature'],
          'hum': decoded[index]['hum'] ?? decoded[index]['humidity'],
          'time': decoded[index]['created_at'] ?? decoded[index]['ts'],
        }, index),
    ];
  }

  Future<Map<String, dynamic>> getPidMode({required String deviceId}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/mode?device_id=$deviceId'),
      headers: _client().headers,
    );
    return decodeMap(response, 'Nie udalo sie pobrac trybu pracy');
  }

  Future<void> setMode({
    required String deviceId,
    required String mode,
    double? targetTemp,
  }) {
    return http
        .post(
          Uri.parse('$baseUrl/api/mode'),
          headers: _headers,
          body: jsonEncode({'deviceId': deviceId, 'mode': mode}),
        )
        .then(
          (response) =>
              ensureSuccess(response, 'Nie udalo sie zapisac trybu pracy'),
        );
  }

  Future<void> setRelay({
    required String deviceId,
    required String topic,
    required Object value,
  }) {
    final body = <String, dynamic>{'deviceId': deviceId, topic: value};
    return http
        .post(
          Uri.parse('$baseUrl/api/manual'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .then(
          (response) =>
              ensureSuccess(response, 'Nie udalo sie wyslac komendy manualnej'),
        );
  }

  Future<void> saveTargets({
    required String deviceId,
    required double targetTemp,
    required double targetHumidity,
    double? tempHysteresis,
    double? humHysteresis,
  }) async {
    final payload = <String, dynamic>{
      'deviceId': deviceId,
      'targetTemp': targetTemp,
      'targetHumidity': targetHumidity,
    };
    if (tempHysteresis != null) {
      payload['tempHysteresis'] = tempHysteresis;
    }
    if (humHysteresis != null) {
      payload['humHysteresis'] = humHysteresis;
    }

    final response = await http.post(
      Uri.parse('$baseUrl/api/targets'),
      headers: _headers,
      body: jsonEncode(payload),
    ).timeout(_requestTimeout);
    ensureSuccess(response, 'Nie udalo sie zapisac wartosci zadanych');
  }

  Future<double> getAiRecommendation({
    required String deviceId,
    required List<double> tempHistory,
    required List<double> humHistory,
    required double targetTemp,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/ai/control'),
      headers: _client().headers,
      body: jsonEncode({
        'device_id': deviceId,
        'temp_history': tempHistory,
        'hum_history': humHistory,
        'target_temp': targetTemp,
      }),
    );
    final decoded = decodeMap(response, 'Nie udalo sie pobrac rekomendacji AI');
    return (decoded['recommended_target'] as num).toDouble();
  }

  Future<bool> evaluateHumidityAlert({
    required String deviceId,
    required double temp,
    required double humidity,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/alerts/evaluate'),
      headers: _client().headers,
      body: jsonEncode({
        'device_id': deviceId,
        'temp': temp,
        'humidity': humidity,
      }),
    );
    final decoded = decodeMap(response, 'Nie udalo sie zweryfikowac alertu');
    return decoded['alert_sent'] == true;
  }

  Future<void> registerFcmToken(String token) async {
    final response = await http.post(
      Uri.parse('$baseUrl/fcm/token'),
      headers: _client().headers,
      body: jsonEncode({'token': token}),
    );
    ensureSuccess(response, 'Nie udalo sie zapisac tokenu FCM');
  }

  Future<void> setPidMode({required String deviceId, required String mode}) {
    return setMode(deviceId: deviceId, mode: mode);
  }

  Future<void> sendControlCommand({
    required String deviceId,
    required String topic,
    required Object value,
  }) {
    return setRelay(deviceId: deviceId, topic: topic, value: value);
  }

  Future<List<Map<String, dynamic>>> getAvailableDevices() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/devices'),
      headers: _headers,
    );
    return decodeList(
      response,
      'Nie udalo sie pobrac listy wykrytych urzadzen',
    );
  }

  Future<void> addDevice(String deviceId, {String? name}) async {
    throw ApiException(
      'Panel VPS nie wymaga recznego dodawania ESP. Urzadzenie pojawia sie automatycznie po wyslaniu danych.',
    );
  }

  Stream<Map<String, dynamic>> streamDevice(String deviceId) async* {
    final request = http.Request('GET', Uri.parse('$baseUrl/api/events'));

    request.headers.addAll(_headers);

    final client = http.Client();
    try {
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw ApiException('Realtime niedostępny (${response.statusCode})');
      }

      var buffer = '';

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;

        while (buffer.contains('\n\n')) {
          final index = buffer.indexOf('\n\n');
          final event = buffer.substring(0, index).replaceAll('\r', '');
          buffer = buffer.substring(index + 2);

          final eventType = event
              .split('\n')
              .where((line) => line.startsWith('event: '))
              .map((line) => line.replaceFirst('event: ', ''))
              .firstOrNull;

          final dataLine = event
              .split('\n')
              .where((line) => line.startsWith('data: '))
              .firstOrNull;

          if (dataLine == null) {
            continue;
          }

          final jsonText = dataLine.replaceFirst('data: ', '');
          if (jsonText.trim().isEmpty || jsonText == '{}') {
            continue;
          }

          final decoded = jsonDecode(jsonText);
          if (decoded is! Map<String, dynamic>) {
            continue;
          }

          if (eventType == 'status') {
            final currentDeviceId =
                decoded['deviceId']?.toString() ??
                decoded['device_id']?.toString();
            if (currentDeviceId == deviceId) {
              yield {'data': _normalizePanelStatus(decoded)};
            }
          }

          if (eventType == 'devices') {
            yield {'devices': decoded};
          }
        }
      }
    } finally {
      client.close();
    }
  }
}

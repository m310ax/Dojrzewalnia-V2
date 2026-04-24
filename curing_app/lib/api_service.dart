import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_service.dart';

class ApiService {
  ApiService({this.baseUrl = defaultBaseUrl});

  static const String defaultBaseUrl = AuthService.defaultBaseUrl;

  final String baseUrl;
  final AuthService _auth = AuthService();

  Map<String, String> _headers({bool includeJson = false}) {
    final token = _auth.token;
    final headers = <String, String>{};

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    if (includeJson) {
      headers['Content-Type'] = 'application/json';
    }

    return headers;
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    final response = await http.get(
      Uri.parse('$baseUrl/devices'),
      headers: _headers(),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się pobrać urządzeń');
    }

    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
  }

  Future<void> addDevice(String id, String name) async {
    final response = await http.post(
      Uri.parse('$baseUrl/devices'),
      headers: _headers(includeJson: true),
      body: jsonEncode({'id': id, 'name': name}),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się dodać urządzenia');
    }
  }

  Future<void> deleteDevice(String id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/devices/$id'),
      headers: _headers(),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się usunąć urządzenia');
    }
  }

  Future<void> registerFcmToken(String token) async {
    final response = await http.post(
      Uri.parse('$baseUrl/fcm/token'),
      headers: _headers(includeJson: true),
      body: jsonEncode({'token': token}),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się zapisać tokenu FCM');
    }
  }

  Future<double> getAiRecommendation({
    required String deviceId,
    required List<double> tempHistory,
    required List<double> humHistory,
    required double targetTemp,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/ai/control'),
      headers: _headers(includeJson: true),
      body: jsonEncode({
        'device_id': deviceId,
        'temp_history': tempHistory,
        'hum_history': humHistory,
        'target_temp': targetTemp,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się pobrać rekomendacji AI');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return (decoded['recommended_target'] as num).toDouble();
  }

  Future<Map<String, dynamic>> applyScene({
    required String deviceId,
    required String scene,
    List<double>? tempHistory,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/scenes/apply'),
      headers: _headers(includeJson: true),
      body: jsonEncode({
        'device_id': deviceId,
        'scene': scene,
        if (tempHistory != null) 'temp_history': tempHistory,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się zastosować sceny');
    }

    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<bool> evaluateHumidityAlert({
    required String deviceId,
    required double temp,
    required double humidity,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/alerts/evaluate'),
      headers: _headers(includeJson: true),
      body: jsonEncode({
        'device_id': deviceId,
        'temp': temp,
        'humidity': humidity,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się zweryfikować alertu wilgotności');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['alert_sent'] == true;
  }

  Future<void> saveTelemetry({
    required String deviceId,
    required double temp,
    required double hum,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/telemetry'),
      headers: _headers(includeJson: true),
      body: jsonEncode({'device_id': deviceId, 'temp': temp, 'hum': hum}),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się zapisać telemetrii');
    }
  }

  Future<List<Map<String, dynamic>>> getHistory({
    required String deviceId,
    int limit = 60,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/history?device=$deviceId&limit=$limit'),
      headers: _headers(),
    );

    if (response.statusCode != 200) {
      throw Exception('Nie udało się pobrać historii');
    }

    final decoded = jsonDecode(response.body) as List<dynamic>;
    return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiService {
  ApiService({this.baseUrl = defaultBaseUrl});

  static const String defaultBaseUrl = AuthService.defaultBaseUrl;
  static const Duration _requestTimeout = Duration(seconds: 5);

  final String baseUrl;
  final AuthService _auth = AuthService();

  Future<http.Response> _send(
    Future<http.Response> request,
    String operation,
  ) async {
    try {
      final response = await request.timeout(_requestTimeout);
      debugPrint('API $operation status: ${response.statusCode}');
      debugPrint('API $operation body: ${response.body}');
      return response;
    } on TimeoutException catch (error) {
      debugPrint('API $operation timeout: $error');
      throw ApiException('Serwer nie odpowiedział na czas');
    } on Exception catch (error) {
      debugPrint('API $operation error: $error');
      throw ApiException('Brak połączenia z serwerem');
    }
  }

  String? _extractErrorMessage(String body) {
    try {
      final payload = jsonDecode(body);
      if (payload is Map<String, dynamic>) {
        final error = payload['error'] ?? payload['message'];
        if (error is String && error.isNotEmpty) {
          return error;
        }
      }
    } on FormatException {
      return null;
    }

    return null;
  }

  void _ensureSuccess(http.Response response, String fallbackMessage) {
    if (response.statusCode == 200) {
      return;
    }

    final body = response.body.trimLeft();
    if (body.startsWith('<')) {
      throw ApiException('Serwer zwrócił HTML zamiast odpowiedzi API');
    }

    throw ApiException(
      _extractErrorMessage(response.body) ??
          '$fallbackMessage (${response.statusCode})',
    );
  }

  Map<String, dynamic> _decodeMap(String body, String fallbackMessage) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) {
      throw ApiException('Serwer zwrócił HTML zamiast odpowiedzi API');
    }

    try {
      final payload = jsonDecode(body);
      if (payload is Map<String, dynamic>) {
        return payload;
      }
    } on FormatException {
      throw ApiException('Serwer zwrócił nieprawidłowy JSON');
    }

    throw ApiException(fallbackMessage);
  }

  List<Map<String, dynamic>> _decodeList(String body, String fallbackMessage) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) {
      throw ApiException('Serwer zwrócił HTML zamiast odpowiedzi API');
    }

    try {
      final payload = jsonDecode(body);
      if (payload is List<dynamic>) {
        return payload
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
      }
    } on FormatException {
      throw ApiException('Serwer zwrócił nieprawidłowy JSON');
    }

    throw ApiException(fallbackMessage);
  }

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
    final response = await _send(
      http.get(
        Uri.parse('$baseUrl/devices'),
        headers: _headers(),
      ),
      'GET /devices',
    );
    _ensureSuccess(response, 'Nie udało się pobrać urządzeń');
    return _decodeList(response.body, 'Nieprawidłowa lista urządzeń');
  }

  Future<void> addDevice(String id, [String? name]) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/devices'),
        headers: _headers(includeJson: true),
        body: jsonEncode({
          'id': id,
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        }),
      ),
      'POST /devices',
    );
    _ensureSuccess(response, 'Nie udało się dodać urządzenia');
  }

  Future<void> deleteDevice(String id) async {
    final response = await _send(
      http.delete(
        Uri.parse('$baseUrl/devices/$id'),
        headers: _headers(),
      ),
      'DELETE /devices/$id',
    );
    _ensureSuccess(response, 'Nie udało się usunąć urządzenia');
  }

  Future<void> registerFcmToken(String token) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/fcm/token'),
        headers: _headers(includeJson: true),
        body: jsonEncode({'token': token}),
      ),
      'POST /fcm/token',
    );
    _ensureSuccess(response, 'Nie udało się zapisać tokenu FCM');
  }

  Future<Map<String, dynamic>> getDeviceData({required String deviceId}) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/device_data'),
        headers: _headers(includeJson: true),
        body: jsonEncode({'device_id': deviceId}),
      ),
      'POST /device_data',
    );
    _ensureSuccess(response, 'Nie udało się pobrać danych urządzenia');
    final decoded = _decodeMap(
      response.body,
      'Nieprawidłowa odpowiedź danych urządzenia',
    );
    return Map<String, dynamic>.from(decoded['data'] as Map);
  }

  Future<void> sendControlCommand({
    required String deviceId,
    required String topic,
    required Object value,
  }) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/control'),
        headers: _headers(includeJson: true),
        body: jsonEncode({
          'device_id': deviceId,
          'topic': topic,
          'value': value,
        }),
      ),
      'POST /control',
    );
    _ensureSuccess(response, 'Nie udało się wysłać komendy do urządzenia');
  }

  Future<double> getAiRecommendation({
    required String deviceId,
    required List<double> tempHistory,
    required List<double> humHistory,
    required double targetTemp,
  }) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/ai/control'),
        headers: _headers(includeJson: true),
        body: jsonEncode({
          'device_id': deviceId,
          'temp_history': tempHistory,
          'hum_history': humHistory,
          'target_temp': targetTemp,
        }),
      ),
      'POST /ai/control',
    );
    _ensureSuccess(response, 'Nie udało się pobrać rekomendacji AI');
    final decoded = _decodeMap(
      response.body,
      'Nieprawidłowa odpowiedź rekomendacji AI',
    );
    return (decoded['recommended_target'] as num).toDouble();
  }

  Future<Map<String, dynamic>> applyScene({
    required String deviceId,
    required String scene,
    List<double>? tempHistory,
  }) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/scenes/apply'),
        headers: _headers(includeJson: true),
        body: jsonEncode({
          'device_id': deviceId,
          'scene': scene,
          'temp_history': tempHistory,
        }),
      ),
      'POST /scenes/apply',
    );
    _ensureSuccess(response, 'Nie udało się zastosować sceny');
    return _decodeMap(response.body, 'Nieprawidłowa odpowiedź sceny');
  }

  Future<bool> evaluateHumidityAlert({
    required String deviceId,
    required double temp,
    required double humidity,
  }) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/alerts/evaluate'),
        headers: _headers(includeJson: true),
        body: jsonEncode({
          'device_id': deviceId,
          'temp': temp,
          'humidity': humidity,
        }),
      ),
      'POST /alerts/evaluate',
    );
    _ensureSuccess(response, 'Nie udało się zweryfikować alertu wilgotności');
    final decoded = _decodeMap(
      response.body,
      'Nieprawidłowa odpowiedź alertu wilgotności',
    );
    return decoded['alert_sent'] == true;
  }

  Future<void> saveTelemetry({
    required String deviceId,
    required double temp,
    required double hum,
  }) async {
    final response = await _send(
      http.post(
        Uri.parse('$baseUrl/telemetry'),
        headers: _headers(includeJson: true),
        body: jsonEncode({'device_id': deviceId, 'temp': temp, 'hum': hum}),
      ),
      'POST /telemetry',
    );
    _ensureSuccess(response, 'Nie udało się zapisać telemetrii');
  }

  Future<List<Map<String, dynamic>>> getHistory({
    required String deviceId,
    int limit = 60,
  }) async {
    final response = await _send(
      http.get(
        Uri.parse('$baseUrl/history?device=$deviceId&limit=$limit'),
        headers: _headers(),
      ),
      'GET /history',
    );
    _ensureSuccess(response, 'Nie udało się pobrać historii');
    return _decodeList(response.body, 'Nieprawidłowa odpowiedź historii');
  }
}

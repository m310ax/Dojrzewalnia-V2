import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device.dart';

class ApiService {
  ApiService({http.Client? client}) : _client = client ?? http.Client();

  static const String _baseUrl = 'http://yasmin345.mikrus.xyz:20345';
  final http.Client _client;

  Future<List<Device>> getDevices() async {
    final response = await _get('/devices');
    final decoded = _decodeJson(response);
    if (decoded is! List) {
      throw const FormatException('Nieprawidlowy format listy urzadzen.');
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Device.fromJson)
        .where((device) => device.id.isNotEmpty)
        .toList();
  }

  Future<void> addDevice(String id) async {
    final response = await _post(
      '/devices',
      body: {'id': id},
    );
    _ensureSuccess(response);
  }

  Future<List<String>> getDiscovered() async {
    final response = await _get('/discovered');
    final decoded = _decodeJson(response);
    if (decoded is! List) {
      throw const FormatException('Nieprawidlowy format listy wykrytych urzadzen.');
    }

    return decoded.map((value) => value.toString()).toList();
  }

  Future<Map<String, dynamic>> getDeviceData(String id) async {
    final response = await _get('/latest?device_id=$id');
    final decoded = _decodeJson(response);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Nieprawidlowy format danych urzadzenia.');
    }
    return decoded;
  }

  Future<List<Map<String, dynamic>>> getHistory(String id) async {
    final response = await _get('/history?device=$id');
    final decoded = _decodeJson(response);
    if (decoded is! List) {
      throw const FormatException('Nieprawidlowy format historii.');
    }

    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> sendControl(String id, String topic, dynamic value) async {
    final response = await _post(
      '/control',
      body: {
        'device_id': id,
        'topic': topic,
        'value': value,
      },
    );
    _ensureSuccess(response);
  }

  Future<http.Response> _get(String path) async {
    final response = await _client
        .get(Uri.parse('$_baseUrl$path'))
        .timeout(const Duration(seconds: 12));
    _ensureSuccess(response);
    return response;
  }

  Future<http.Response> _post(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));
    return response;
  }

  dynamic _decodeJson(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const FormatException('Serwer zwrocil niepoprawny JSON.');
    }
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw StateError(
      'Blad API ${response.statusCode}: ${response.reasonPhrase ?? 'nieznany blad'}',
    );
  }
}
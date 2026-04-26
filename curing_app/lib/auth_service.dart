import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum AuthFailureReason {
  timeout,
  connection,
  htmlResponse,
  invalidJson,
  missingToken,
  serverResponse,
}

class AuthService {
  factory AuthService() => _instance;

  AuthService._internal();

  static final AuthService _instance = AuthService._internal();

  static const String defaultBaseUrl = 'http://yasmin345.mikrus.xyz:20345';
  static const String _tokenPrefsKey = 'auth_token';
  static const Duration _requestTimeout = Duration(seconds: 5);

  String? token;
  String? lastErrorMessage;
  AuthFailureReason? lastFailureReason;

  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString(_tokenPrefsKey);
  }

  Future<void> _saveToken(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenPrefsKey, value);
  }

  Future<void> logout() async {
    token = null;
    lastErrorMessage = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenPrefsKey);
  }

  Future<http.Response?> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    lastErrorMessage = null;
    lastFailureReason = null;

    try {
      final response = await http
          .post(
            Uri.parse('$defaultBaseUrl/$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);

      debugPrint('Auth $path status: ${response.statusCode}');
      debugPrint('Auth $path body: ${response.body}');
      return response;
    } on TimeoutException catch (error) {
      lastFailureReason = AuthFailureReason.timeout;
      lastErrorMessage = 'Serwer nie odpowiedział w wymaganym czasie';
      debugPrint('Auth $path timeout: $error');
      return null;
    } on Exception catch (error) {
      lastFailureReason = AuthFailureReason.connection;
      lastErrorMessage = 'Brak połączenia z serwerem';
      debugPrint('Auth $path error: $error');
      return null;
    }
  }

  String? _extractServerError(String body) {
    try {
      final payload = jsonDecode(body);
      if (payload is! Map<String, dynamic>) {
        return null;
      }

      final error = payload['error'] ?? payload['message'];
      return error is String && error.isNotEmpty ? error : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> login(String email, String pass) async {
    final response = await _postJson('login', {
      'email': email,
      'password': pass,
    });

    if (response == null) {
      return false;
    }

    if (response.statusCode != 200) {
      final body = response.body.trimLeft();
      if (body.startsWith('<')) {
        lastFailureReason = AuthFailureReason.htmlResponse;
        lastErrorMessage = 'Serwer zwrócił HTML zamiast odpowiedzi API';
        return false;
      }

      lastFailureReason = AuthFailureReason.serverResponse;
      lastErrorMessage =
          _extractServerError(response.body) ??
          'Logowanie nieudane (${response.statusCode})';
      return false;
    }

    final body = response.body.trimLeft();
    if (body.startsWith('<')) {
      lastFailureReason = AuthFailureReason.htmlResponse;
      lastErrorMessage = 'Serwer zwrócił HTML zamiast odpowiedzi API';
      debugPrint('Auth login HTML body: ${response.body}');
      return false;
    }

    late final Map<String, dynamic> decoded;
    try {
      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) {
        lastFailureReason = AuthFailureReason.invalidJson;
        lastErrorMessage = 'Nieprawidłowa odpowiedź serwera';
        return false;
      }
      decoded = payload;
    } on FormatException {
      lastFailureReason = AuthFailureReason.invalidJson;
      lastErrorMessage = 'Serwer zwrócił nieprawidłową odpowiedź';
      debugPrint('Auth login invalid JSON body: ${response.body}');
      return false;
    }

    final rawToken = decoded['access_token'] ?? decoded['token'];
    if (rawToken is! String || rawToken.isEmpty) {
      lastFailureReason = AuthFailureReason.missingToken;
      lastErrorMessage = 'Serwer nie zwrócił tokenu logowania';
      debugPrint('Auth login missing token field in body: ${response.body}');
      return false;
    }

    token = rawToken;
    await _saveToken(token!);
    return true;
  }

  Future<bool> register(String email, String pass) async {
    final response = await _postJson('register', {
      'email': email,
      'password': pass,
    });

    if (response == null) {
      return false;
    }

    if (response.statusCode != 200) {
      final body = response.body.trimLeft();
      if (body.startsWith('<')) {
        lastFailureReason = AuthFailureReason.htmlResponse;
        lastErrorMessage = 'Serwer zwrócił HTML zamiast odpowiedzi API';
        return false;
      }

      lastFailureReason = AuthFailureReason.serverResponse;
      lastErrorMessage =
          _extractServerError(response.body) ??
          'Rejestracja nieudana (${response.statusCode})';
      return false;
    }

    return true;
  }
}

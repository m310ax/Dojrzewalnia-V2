import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  factory AuthService() => _instance;

  AuthService._internal();

  static final AuthService _instance = AuthService._internal();

  static const String defaultBaseUrl = 'http://srv22.mikr.us:20551';
  static const String _tokenPrefsKey = 'auth_token';
  static const Duration _requestTimeout = Duration(seconds: 5);

  String? token;
  String? lastErrorMessage;

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
    } on Exception catch (error) {
      lastErrorMessage = 'Brak połączenia z serwerem';
      debugPrint('Auth $path error: $error');
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
      lastErrorMessage = 'Logowanie nieudane (${response.statusCode})';
      return false;
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = decoded['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      lastErrorMessage = 'Serwer nie zwrócił tokenu logowania';
      return false;
    }

    token = accessToken;
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
      lastErrorMessage = 'Rejestracja nieudana (${response.statusCode})';
      return false;
    }

    return true;
  }
}

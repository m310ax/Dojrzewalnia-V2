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
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://yasmin345.mikrus.xyz:30345',
  );
  static const Duration _requestTimeout = Duration(seconds: 6);
  static const _tokenKey = 'auth_token';
  static const bool supportsRegistration = true;

  static String normalizeBaseUrl(String rawBaseUrl) {
    final trimmed = rawBaseUrl.trim();
    if (trimmed.isEmpty) {
      return defaultBaseUrl;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return trimmed;
    }

    final needsPanelPort =
        uri.host == 'yasmin345.mikrus.xyz' &&
        ((uri.scheme == 'http' && uri.port == 80) ||
            (uri.scheme == 'https' && uri.port == 443));
    final normalized = needsPanelPort ? uri.replace(port: 30345) : uri;
    return normalized.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  static String? normalizeStoredToken(String? rawToken) {
    if (rawToken == null) {
      return null;
    }

    var normalized = rawToken.trim();
    if (normalized.isEmpty) {
      return null;
    }

    if (normalized.toLowerCase().startsWith('basic ')) {
      normalized = normalized.substring(6).trim();
    }

    return _looksLikeBasicToken(normalized) ? normalized : null;
  }

  static bool _looksLikeBasicToken(String token) {
    try {
      final decoded = utf8.decode(base64Decode(token), allowMalformed: false);
      return decoded.contains(':');
    } on FormatException {
      return false;
    }
  }

  String? token;
  String? lastErrorMessage;
  AuthFailureReason? lastFailureReason;

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  Future<void> loadToken() async {
    final preferences = await SharedPreferences.getInstance();
    final storedToken = preferences.getString(_tokenKey);
    final normalizedToken = normalizeStoredToken(storedToken);

    if (normalizedToken == null) {
      token = null;
      if (storedToken != null) {
        await preferences.remove(_tokenKey);
      }
      return;
    }

    token = normalizedToken;
    if (normalizedToken != storedToken) {
      await preferences.setString(_tokenKey, normalizedToken);
    }
  }

  Future<void> _saveToken(String value) async {
    final normalizedToken = normalizeStoredToken(value);
    if (normalizedToken == null) {
      throw const FormatException('Invalid auth token');
    }

    token = normalizedToken;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_tokenKey, normalizedToken);
  }

  Future<void> logout() async {
    token = null;
    lastErrorMessage = null;
    lastFailureReason = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
  }

  Future<bool> login(String email, String password) async {
    try {
      lastErrorMessage = null;
      lastFailureReason = null;
      final baseUrl = normalizeBaseUrl(defaultBaseUrl);

      final basicToken = base64Encode(utf8.encode('$email:$password'));
      final response = await http
          .get(
            Uri.parse('$baseUrl/api/status?device=dojrzewalnia-01'),
            headers: {'Authorization': 'Basic $basicToken'},
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 401) {
        lastFailureReason = AuthFailureReason.serverResponse;
        lastErrorMessage = 'Nieprawidlowy login lub haslo';
        return false;
      }

      if (response.statusCode != 200) {
        lastFailureReason = AuthFailureReason.serverResponse;
        lastErrorMessage =
            'Panel nie odpowiedzial poprawnie (${response.statusCode})';
        return false;
      }

      await _saveToken(basicToken);
      return true;
    } on TimeoutException catch (error) {
      debugPrint('Auth panel timeout: $error');
      lastFailureReason = AuthFailureReason.timeout;
      lastErrorMessage = 'Panel nie odpowiedzial w wymaganym czasie';
      return false;
    } on Exception catch (error) {
      debugPrint('Auth panel error: $error');
      lastFailureReason = AuthFailureReason.connection;
      lastErrorMessage = 'Brak polaczenia z panelem';
      return false;
    }
  }

  Future<bool> register(String email, String password) async {
    try {
      lastErrorMessage = null;
      lastFailureReason = null;
      final baseUrl = normalizeBaseUrl(defaultBaseUrl);

      final response = await http
          .post(
            Uri.parse('$baseUrl/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        return true;
      }

      lastFailureReason = AuthFailureReason.serverResponse;
      final trimmed = response.body.trimLeft();
      if (!trimmed.startsWith('<')) {
        try {
          final payload = jsonDecode(response.body);
          if (payload is Map<String, dynamic>) {
            final error = payload['error'];
            if (error is String && error.isNotEmpty) {
              lastErrorMessage = error;
              return false;
            }
          }
        } on FormatException {
          // Fall through to generic error below.
        }
      }

      lastErrorMessage = 'Rejestracja nieudana (${response.statusCode})';
      return false;
    } on TimeoutException catch (error) {
      debugPrint('Register timeout: $error');
      lastFailureReason = AuthFailureReason.timeout;
      lastErrorMessage = 'Serwer nie odpowiedzial w wymaganym czasie';
      return false;
    } on Exception catch (error) {
      debugPrint('Register error: $error');
      lastFailureReason = AuthFailureReason.connection;
      lastErrorMessage = 'Brak polaczenia z serwerem';
      return false;
    }
  }
}

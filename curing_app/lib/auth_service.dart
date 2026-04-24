import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  factory AuthService() => _instance;

  AuthService._internal();

  static final AuthService _instance = AuthService._internal();

  static const String defaultBaseUrl = 'http://192.168.68.122:5000';
  static const String _tokenPrefsKey = 'auth_token';

  String? token;

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenPrefsKey);
  }

  Future<bool> login(String email, String pass) async {
    final response = await http.post(
      Uri.parse('$defaultBaseUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': pass}),
    );

    if (response.statusCode != 200) {
      return false;
    }

    token = jsonDecode(response.body)['access_token'] as String;
    await _saveToken(token!);
    return true;
  }

  Future<bool> register(String email, String pass) async {
    final response = await http.post(
      Uri.parse('$defaultBaseUrl/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': pass}),
    );

    return response.statusCode == 200;
  }
}

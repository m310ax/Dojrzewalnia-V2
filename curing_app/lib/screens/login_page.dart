import 'package:flutter/material.dart';

import '../core/api.dart';
import '../features/auth/login_page.dart' as modern;

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.api, this.onLoggedIn});

  final Api api;
  final VoidCallback? onLoggedIn;

  @override
  Widget build(BuildContext context) {
    return modern.LoginPage(api);
  }
}
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../dashboard/dashboard_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage(this.api, {super.key});

  final Api api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final pass = TextEditingController();

  bool loading = false;

  @override
  void dispose() {
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> login() async {
    setState(() => loading = true);
    final ok = await widget.api.login(email.text, pass.text);

    if (!mounted) {
      return;
    }

    setState(() => loading = false);

    if (ok) {
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => DashboardPage(widget.api)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Dojrzewalnia PRO',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: AppTheme.text,
                          ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: email,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pass,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Haslo'),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: loading ? null : login,
                      child: Text(loading ? 'Logowanie...' : 'Zaloguj'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
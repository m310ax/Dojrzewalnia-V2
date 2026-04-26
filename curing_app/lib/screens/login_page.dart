import 'package:flutter/material.dart';

import '../auth_service.dart';
import '../notification_service.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onLoggedIn});

  final VoidCallback onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _auth = AuthService();

  bool _isSubmitting = false;
  String? _errorMessage;
  AuthFailureReason? _errorReason;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _errorReason = null;
    });

    final success = await _auth.login(
      _emailController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) {
      return;
    }

    setState(() => _isSubmitting = false);

    if (!success) {
      setState(() {
        _errorMessage = _auth.lastErrorMessage ?? 'Logowanie nieudane';
        _errorReason = _auth.lastFailureReason;
      });
      return;
    }

    await NotificationService().initialize();
    widget.onLoggedIn();
  }

  String _errorTitle(AuthFailureReason? reason) {
    switch (reason) {
      case AuthFailureReason.timeout:
        return 'Przekroczono czas odpowiedzi serwera';
      case AuthFailureReason.connection:
        return 'Brak połączenia z backendem';
      case AuthFailureReason.htmlResponse:
        return 'Zamiast API wrócił HTML';
      case AuthFailureReason.invalidJson:
        return 'Serwer zwrócił błędny JSON';
      case AuthFailureReason.missingToken:
        return 'W odpowiedzi brakuje tokenu';
      case AuthFailureReason.serverResponse:
        return 'Backend odrzucił logowanie';
      case null:
        return 'Logowanie nieudane';
    }
  }

  String? _errorHint(AuthFailureReason? reason) {
    switch (reason) {
      case AuthFailureReason.timeout:
        return 'Sprawdź, czy serwer działa i czy port 40222 jest osiągalny.';
      case AuthFailureReason.connection:
        return 'Aplikacja nie mogła połączyć się z adresem API.';
      case AuthFailureReason.htmlResponse:
        return 'To zwykle oznacza zły adres albo brak właściwego portu API.';
      case AuthFailureReason.invalidJson:
        return 'Backend odpowiedział, ale format odpowiedzi nie jest zgodny z aplikacją.';
      case AuthFailureReason.missingToken:
        return 'Logowanie wygląda na poprawne, ale payload nie zawiera access_token ani token.';
      case AuthFailureReason.serverResponse:
        return 'Sprawdź treść błędu z backendu poniżej.';
      case null:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Logowanie',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Hasło',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _isSubmitting ? null : _login,
                      child: Text(_isSubmitting ? 'Logowanie...' : 'Zaloguj'),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _errorMessage == null
                          ? const SizedBox.shrink()
                          : Container(
                              key: ValueKey<String>(_errorMessage!),
                              margin: const EdgeInsets.only(top: 16),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF5C1F24),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFFF8A80),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _errorTitle(_errorReason),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(color: Colors.white),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _errorMessage!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.white),
                                  ),
                                  if (_errorHint(_errorReason) case final hint?) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      hint,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: Colors.white70),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const RegisterPage(),
                                ),
                              );
                            },
                      child: const Text('Nie masz konta? Zarejestruj się'),
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

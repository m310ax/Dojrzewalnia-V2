import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dojrzewalnia LUX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7ED957),
          secondary: Color(0xFF5EC2B7),
          surface: Color(0xFF111827),
        ),
        scaffoldBackgroundColor: const Color(0xFF060C12),
      ),
      home: const HomeScreen(),
    );
  }
}

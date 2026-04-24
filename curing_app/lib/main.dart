import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'mqtt_service.dart';
import 'notification_service.dart';
import 'screens/onboarding.dart';
import 'theme.dart';
import 'screens/devices_page.dart';
import 'screens/home_page.dart';
import 'screens/login_page.dart';
import 'screens/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService().loadToken();
  await MqttService().loadSettings();
  await NotificationService().initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.enableAutoConnect = true});

  final bool enableAutoConnect;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: AppEntry(enableAutoConnect: enableAutoConnect),
    );
  }
}

class AppEntry extends StatefulWidget {
  const AppEntry({super.key, required this.enableAutoConnect});

  final bool enableAutoConnect;

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  static const _onboardingPrefsKey = 'seen_onboarding';

  bool? _hasSeenOnboarding;

  @override
  void initState() {
    super.initState();
    _loadOnboardingFlag();
  }

  Future<void> _loadOnboardingFlag() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _hasSeenOnboarding = prefs.getBool(_onboardingPrefsKey) ?? false;
    });
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingPrefsKey, true);
    if (!mounted) {
      return;
    }
    setState(() => _hasSeenOnboarding = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_hasSeenOnboarding == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_hasSeenOnboarding == false) {
      return OnboardingPage(onDone: _completeOnboarding);
    }

    return MainScreen(enableAutoConnect: widget.enableAutoConnect);
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.enableAutoConnect = true});

  final bool enableAutoConnect;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _auth = AuthService();
  int index = 0;
  int deviceRevision = 0;

  void _handleLoggedIn() {
    setState(() {});
  }

  void _handleDevicesChanged() {
    setState(() => deviceRevision++);
  }

  @override
  Widget build(BuildContext context) {
    if (_auth.token == null || _auth.token!.isEmpty) {
      return LoginPage(onLoggedIn: _handleLoggedIn);
    }

    final pages = [
      HomePage(
        key: ValueKey('home-$deviceRevision'),
        enableAutoConnect: widget.enableAutoConnect,
        deviceRevision: deviceRevision,
      ),
      DevicesPage(
        key: ValueKey('devices-$deviceRevision'),
        onDevicesChanged: _handleDevicesChanged,
      ),
      const SettingsPage(),
    ];

    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (i) => setState(() => index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.devices), label: 'Devices'),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

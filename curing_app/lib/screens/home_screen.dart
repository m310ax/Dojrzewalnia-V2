import 'package:flutter/material.dart';

import '../core/api.dart';
import '../features/dashboard/dashboard_page.dart';
import '../core/auth.dart';

class HomeScreen extends StatefulWidget {
  HomeScreen({super.key, this.enableAutoConnect = true, Api? api})
    : api = api ?? Api(AuthService.defaultBaseUrl);

  final bool enableAutoConnect;
  final Api api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return DashboardPage(widget.api);
  }
}

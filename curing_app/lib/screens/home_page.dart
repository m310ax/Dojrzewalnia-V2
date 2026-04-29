import 'package:flutter/material.dart';

import 'home_screen.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.enableAutoConnect = true,
    this.deviceRevision = 0,
  });

  final bool enableAutoConnect;
  final int deviceRevision;

  @override
  Widget build(BuildContext context) {
    return HomeScreen(
      key: ValueKey('home-screen-$deviceRevision'),
      enableAutoConnect: enableAutoConnect,
    );
  }
}
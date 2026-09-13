import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const VoxaApp());
}

class VoxaApp extends StatelessWidget {
  const VoxaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voxa',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

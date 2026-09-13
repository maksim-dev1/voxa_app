import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';

void main() {
  runApp(const VoxaApp());
}

class VoxaApp extends StatefulWidget {
  const VoxaApp({super.key});

  @override
  State<VoxaApp> createState() => _VoxaAppState();
}

class _VoxaAppState extends State<VoxaApp> {
  final ApiClient _api = ApiClient();
  late final AuthService _auth = AuthService(_api);
  late final Future<void> _restoring = _auth.restore();

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

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
      home: FutureBuilder<void>(
        future: _restoring,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              return _auth.isLoggedIn
                  ? HomeScreen(auth: _auth, api: _api)
                  : LoginScreen(auth: _auth);
            },
          );
        },
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'logger.dart';

const _tag = 'Auth';
const _tokenKey = 'voxa_auth_token';

/// Owns the JWT: persists it in the platform Keychain and exposes the
/// current login state as a [ChangeNotifier] so screens can react to
/// login/logout without polling.
class AuthService extends ChangeNotifier {
  AuthService(this._api) : _storage = const FlutterSecureStorage();

  final ApiClient _api;
  final FlutterSecureStorage _storage;

  String? _token;
  String? get token => _token;
  bool get isLoggedIn => _token != null;

  Future<void> restore() async {
    _token = await _storage.read(key: _tokenKey);
    Log.i(_tag, 'restored session: ${_token != null}');
    notifyListeners();
  }

  Future<void> register(String email, String password) async {
    final token = await _api.register(email, password);
    await _setToken(token);
  }

  Future<void> login(String email, String password) async {
    final token = await _api.login(email, password);
    await _setToken(token);
  }

  Future<void> logout() async {
    Log.i(_tag, 'logout');
    _token = null;
    await _storage.delete(key: _tokenKey);
    notifyListeners();
  }

  Future<void> _setToken(String token) async {
    _token = token;
    await _storage.write(key: _tokenKey, value: token);
    Log.i(_tag, 'session established');
    notifyListeners();
  }
}

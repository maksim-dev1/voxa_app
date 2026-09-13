import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'logger.dart';

const _tag = 'Auth';

/// Owns the JWT: persists it in a local file and exposes the current
/// login state as a [ChangeNotifier] so screens can react to
/// login/logout without polling.
///
/// Not stored in the platform Keychain: on macOS, writing to Keychain
/// with an access group (which flutter_secure_storage requires) needs
/// the app signed with a real Team ID/provisioning profile — ad-hoc
/// local builds fail with errSecMissingEntitlement (-34018) regardless
/// of App Sandbox. voxa isn't distributed through the App Store, so a
/// plain file in the app's support directory is an acceptable trade-off
/// for a personal single-user desktop app rather than fighting Xcode
/// provisioning for local dev builds.
class AuthService extends ChangeNotifier {
  AuthService(this._api);

  final ApiClient _api;

  String? _token;
  String? get token => _token;
  bool get isLoggedIn => _token != null;

  Future<File> _tokenFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/auth_token.txt');
  }

  Future<void> restore() async {
    try {
      final file = await _tokenFile();
      if (await file.exists()) {
        final content = (await file.readAsString()).trim();
        _token = content.isEmpty ? null : content;
      }
    } catch (e, st) {
      Log.e(_tag, 'failed to restore session', e, st);
    }
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
    try {
      final file = await _tokenFile();
      if (await file.exists()) await file.delete();
    } catch (e, st) {
      Log.e(_tag, 'failed to clear token file', e, st);
    }
    notifyListeners();
  }

  Future<void> _setToken(String token) async {
    _token = token;
    final file = await _tokenFile();
    await file.writeAsString(token);
    Log.i(_tag, 'session established');
    notifyListeners();
  }
}

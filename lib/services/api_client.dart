import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/transcript_segment.dart';
import '../models/transcription_job.dart';
import 'logger.dart';

const _tag = 'ApiClient';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'ApiException($statusCode, $message)';
}

/// Talks to voxa-api (deployed on Pi, reachable at voxa.pixelio.tech).
/// Stateless beyond the base URL — callers pass their own token.
class ApiClient {
  ApiClient({this.baseUrl = 'https://voxa.pixelio.tech'});

  final String baseUrl;
  final http.Client _client = http.Client();

  /// Runs an HTTP call and rethrows connect/DNS failures as
  /// [NetworkException] instead of a raw SocketException — every public
  /// method below goes through this so call sites get one exception type
  /// for "couldn't even reach the server".
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SocketException catch (e) {
      Log.w(_tag, 'network unreachable: $e');
      throw NetworkException(e);
    }
  }

  Future<String> register(String email, String password) => _guard(() async {
        final resp = await _client.post(
          Uri.parse('$baseUrl/auth/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        );
        return _extractToken(resp, 'register');
      });

  Future<String> login(String email, String password) => _guard(() async {
        final resp = await _client.post(
          Uri.parse('$baseUrl/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        );
        return _extractToken(resp, 'login');
      });

  String _extractToken(http.Response resp, String action) {
    if (resp.statusCode >= 400) {
      final message = _errorMessage(resp);
      Log.w(_tag, '$action failed: ${resp.statusCode} $message');
      throw ApiException(resp.statusCode, message);
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['token'] as String;
  }

  Future<String> uploadRecording(String token, String filePath) => _guard(() async {
        Log.i(_tag, 'uploading $filePath');
        final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/jobs'))
          ..headers['Authorization'] = 'Bearer $token'
          ..files.add(await http.MultipartFile.fromPath('audio', filePath));

        final streamed = await _client.send(request);
        final resp = await http.Response.fromStream(streamed);
        if (resp.statusCode >= 400) {
          final message = _errorMessage(resp);
          Log.w(_tag, 'upload failed: ${resp.statusCode} $message');
          throw ApiException(resp.statusCode, message);
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final jobId = body['job_id'] as String;
        Log.i(_tag, 'uploaded, job_id=$jobId');
        return jobId;
      });

  Future<TranscriptionJob> getJob(String token, String jobId) => _guard(() async {
        final resp = await _client.get(
          Uri.parse('$baseUrl/jobs/$jobId'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (resp.statusCode >= 400) {
          throw ApiException(resp.statusCode, _errorMessage(resp));
        }
        return TranscriptionJob.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      });

  Future<List<TranscriptSegment>> getResult(String token, String jobId) => _guard(() async {
        final resp = await _client.get(
          Uri.parse('$baseUrl/jobs/$jobId/result'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (resp.statusCode >= 400) {
          throw ApiException(resp.statusCode, _errorMessage(resp));
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final segments = body['segments'] as List<dynamic>;
        return segments
            .map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  String _errorMessage(http.Response resp) {
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['error'] as String? ?? resp.body;
    } catch (_) {
      return resp.body.isEmpty ? 'HTTP ${resp.statusCode}' : resp.body;
    }
  }
}

/// Thrown when there's no network path to the server at all (DNS/connect
/// failure), distinct from a server-side error response ([ApiException]).
class NetworkException implements Exception {
  NetworkException(this.cause);
  final Object cause;

  @override
  String toString() => 'Нет соединения с сервером: $cause';
}

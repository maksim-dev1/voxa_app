import 'dart:io';

import 'package:record/record.dart';

import 'logger.dart';
import 'recordings_repository.dart';
import 'system_audio_recorder.dart';

const _tag = 'Session';

/// Drives one recording session: mic capture always, system audio capture
/// when the platform supports it (macOS 13+ today). On stop(), both tracks
/// are mixed down into a single file so a call with several people on
/// either end still ends up as one track to transcribe.
class RecordingSession {
  RecordingSession(this._repository);

  final RecordingsRepository _repository;
  final AudioRecorder _micRecorder = AudioRecorder();
  final SystemAudioRecorder _systemRecorder = SystemAudioRecorder.instance;

  bool _systemAudioAvailable = false;
  bool get systemAudioAvailable => _systemAudioAvailable;

  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;

  Directory? _sessionDir;

  /// Requests (or checks) every permission the session needs and only then
  /// starts writing files. Nothing is recorded before the user has decided.
  ///
  /// Throws [StateError] if the microphone permission is refused — without
  /// it there is nothing to record. System audio is optional: if screen
  /// recording permission is refused, the session falls back to mic-only
  /// and [systemAudioAvailable] reports that.
  Future<void> start() async {
    Log.i(_tag, 'start() requested');

    final micGranted = await _micRecorder.hasPermission();
    Log.i(_tag, 'mic permission granted=$micGranted');
    if (!micGranted) {
      Log.w(_tag, 'aborting start(): no mic permission');
      throw StateError('Нет разрешения на микрофон');
    }

    final wantsSystemAudio = await _systemRecorder.isSupported();
    Log.i(_tag, 'system audio supported on this platform=$wantsSystemAudio');
    _systemAudioAvailable =
        wantsSystemAudio && await _systemRecorder.requestPermission();
    Log.i(_tag, 'systemAudioAvailable=$_systemAudioAvailable');

    final startedAt = DateTime.now();
    _startedAt = startedAt;
    final dir = await _repository.createSessionDir(startedAt);
    _sessionDir = dir;
    Log.i(_tag, 'session dir=${dir.path}');

    await _micRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 48000),
      path: _repository.rawMicPath(dir),
    );
    Log.i(_tag, 'mic recorder started');

    if (_systemAudioAvailable) {
      try {
        await _systemRecorder.start(_repository.rawSystemPath(dir));
        Log.i(_tag, 'system audio recorder started');
      } catch (e, st) {
        // Permission was granted but capture still failed to start (e.g.
        // no shareable display). Keep the mic recording going regardless.
        Log.e(_tag, 'system audio failed to start, continuing mic-only', e, st);
        _systemAudioAvailable = false;
      }
    }
  }

  /// Current mic input level (0..1), for a live meter while recording.
  Stream<double> micLevelStream() {
    return _micRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 150))
        .map((amp) {
      // Amplitude is in dBFS (roughly -45..0); normalize to 0..1.
      const minDb = -45.0;
      final clamped = amp.current.clamp(minDb, 0.0);
      return (clamped - minDb) / -minDb;
    });
  }

  Future<double> systemLevel() => _systemRecorder.currentLevel();

  /// Stops both recorders and mixes them into a single output file.
  /// Returns the final recording path.
  Future<String> stop() async {
    final dir = _sessionDir;
    if (dir == null) {
      Log.w(_tag, 'stop() called without an active session');
      throw StateError('Session was not started');
    }
    Log.i(_tag, 'stop() requested, dir=${dir.path}');

    await _micRecorder.stop();
    Log.i(_tag, 'mic recorder stopped');
    if (_systemAudioAvailable) {
      await _systemRecorder.stop();
      Log.i(_tag, 'system audio recorder stopped');
    }

    final micPath = _repository.rawMicPath(dir);
    final systemPath = _repository.rawSystemPath(dir);
    final outputPath = _repository.finalPath(dir);

    final hasSystemTrack = _systemAudioAvailable && await File(systemPath).exists();
    Log.i(_tag, 'hasSystemTrack=$hasSystemTrack');

    if (hasSystemTrack) {
      final micSize = await File(micPath).length();
      final sysSize = await File(systemPath).length();
      Log.i(_tag, 'mic file size=$micSize bytes, system file size=$sysSize bytes');
      // Only reached on platforms with a system-audio implementation
      // (macOS today), so the native mixDown call is always available here.
      await _systemRecorder.mixDown(
        micPath: micPath,
        systemPath: systemPath,
        outputPath: outputPath,
      );
      // Keep the raw mic/system tracks around (not just the mix) so either
      // side of the call can be played back separately.
      Log.i(_tag, 'mixdown complete, output=$outputPath (raw tracks kept)');
    } else {
      // No second track to mix in — the mic recording already is the
      // final file, just move it into place.
      await File(micPath).rename(outputPath);
      Log.i(_tag, 'mic-only recording finalized at $outputPath');
    }

    _startedAt = null;
    _sessionDir = null;
    return outputPath;
  }

  Future<void> cancel() async {
    if (_sessionDir == null) return;
    Log.w(_tag, 'cancel() called, delegating to stop()');
    await stop();
  }

  void dispose() {
    _micRecorder.dispose();
  }
}

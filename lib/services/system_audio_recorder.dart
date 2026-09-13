import 'package:flutter/services.dart';

import 'logger.dart';

const _tag = 'SystemAudio';

/// Bridges to the native (macOS) ScreenCaptureKit-based system audio
/// recorder. No-op / unsupported on platforms without a native
/// implementation yet (Windows/Linux/mobile).
class SystemAudioRecorder {
  SystemAudioRecorder._();
  static final SystemAudioRecorder instance = SystemAudioRecorder._();

  static const MethodChannel _channel = MethodChannel('voxa/system_audio');

  Future<bool> isSupported() async {
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      Log.d(_tag, 'isSupported -> $supported');
      return supported ?? false;
    } on MissingPluginException {
      Log.d(_tag, 'isSupported -> false (no native implementation)');
      return false;
    }
  }

  Future<bool> checkPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkScreenRecordingPermission');
      Log.d(_tag, 'checkPermission -> $granted');
      return granted ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Shows the system Screen Recording prompt (only fires once per user
  /// decision) and waits briefly for the answer to land.
  Future<bool> requestPermission() async {
    Log.i(_tag, 'requesting screen recording permission');
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestScreenRecordingPermission');
      Log.i(_tag, 'requestPermission -> $granted');
      return granted ?? false;
    } on MissingPluginException {
      Log.w(_tag, 'requestPermission: no native implementation on this platform');
      return false;
    }
  }

  Future<void> start(String path) async {
    Log.i(_tag, 'start($path)');
    try {
      await _channel.invokeMethod<void>('start', {'path': path});
      Log.i(_tag, 'start() succeeded');
    } catch (e, st) {
      Log.e(_tag, 'start() failed', e, st);
      rethrow;
    }
  }

  Future<void> stop() async {
    Log.i(_tag, 'stop()');
    try {
      await _channel.invokeMethod<void>('stop');
      Log.i(_tag, 'stop() succeeded');
    } catch (e, st) {
      Log.e(_tag, 'stop() failed', e, st);
      rethrow;
    }
  }

  /// Current peak level (0..1) of the system audio being captured, for a
  /// live meter. Returns 0 when nothing is being captured.
  Future<double> currentLevel() async {
    try {
      final level = await _channel.invokeMethod<double>('currentSystemLevel');
      return level ?? 0;
    } on MissingPluginException {
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// Offline-mixes the mic and (optional) system track into one file.
  Future<void> mixDown({
    required String micPath,
    String? systemPath,
    required String outputPath,
  }) async {
    Log.i(_tag, 'mixDown mic=$micPath system=$systemPath -> $outputPath');
    try {
      await _channel.invokeMethod<void>('mixDown', {
        'micPath': micPath,
        'systemPath': systemPath,
        'outputPath': outputPath,
      });
      Log.i(_tag, 'mixDown succeeded');
    } catch (e, st) {
      Log.e(_tag, 'mixDown failed', e, st);
      rethrow;
    }
  }

  /// Peak-amplitude waveform for [path], downsampled to [buckets] points
  /// in the 0..1 range, for a static preview in the recordings list.
  Future<List<double>> extractWaveform(String path, {int buckets = 120}) async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'extractWaveform',
        {'path': path, 'buckets': buckets},
      );
      return result?.map((e) => (e as num).toDouble()).toList() ?? [];
    } on MissingPluginException {
      return [];
    } catch (e, st) {
      Log.e(_tag, 'extractWaveform failed', e, st);
      return [];
    }
  }
}

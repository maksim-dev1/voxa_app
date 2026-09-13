import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/recording.dart';
import '../services/logger.dart';
import '../services/recording_session.dart';
import '../services/recordings_repository.dart';
import '../services/system_audio_recorder.dart';
import '../widgets/level_meter.dart';
import '../widgets/waveform_view.dart';

const _tag = 'HomeScreen';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RecordingsRepository _repository = RecordingsRepository();
  late final RecordingSession _session = RecordingSession(_repository);
  final AudioPlayer _player = AudioPlayer();

  List<Recording> _recordings = [];
  final Map<String, List<double>> _waveforms = {};

  bool _isRecording = false;
  bool _isProcessing = false;
  bool _loading = true;
  String? _error;

  Timer? _elapsedTimer;
  Duration _elapsed = Duration.zero;

  StreamSubscription<double>? _micLevelSub;
  Timer? _systemLevelTimer;
  double _micLevel = 0;
  double _systemLevel = 0;

  String? _playingId;
  bool _playerBusy = false;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _playerPositionSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _playingId = null;
          _playerBusy = false;
          _playbackPosition = Duration.zero;
        });
        _player.stop();
      } else {
        setState(() => _playerBusy = state.playing);
      }
    });
    _playerPositionSub = _player.positionStream.listen((pos) {
      setState(() => _playbackPosition = pos);
    });
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _micLevelSub?.cancel();
    _systemLevelTimer?.cancel();
    _playerStateSub?.cancel();
    _playerPositionSub?.cancel();
    _player.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final recordings = await _repository.listRecordings();
    Log.i(_tag, 'loaded ${recordings.length} recordings');
    setState(() {
      _recordings = recordings;
      _loading = false;
    });
    for (final r in recordings) {
      if (_waveforms.containsKey(r.id)) continue;
      SystemAudioRecorder.instance.extractWaveform(r.path).then((wf) {
        if (!mounted) return;
        setState(() => _waveforms[r.id] = wf);
      });
    }
  }

  Future<void> _toggleRecording() async {
    setState(() => _error = null);
    if (_isRecording) {
      Log.i(_tag, 'user pressed stop');
      _elapsedTimer?.cancel();
      _micLevelSub?.cancel();
      _systemLevelTimer?.cancel();
      setState(() {
        _isRecording = false;
        _isProcessing = true;
        _elapsed = Duration.zero;
        _micLevel = 0;
        _systemLevel = 0;
      });
      try {
        final path = await _session.stop();
        Log.i(_tag, 'recording finalized at $path');
      } catch (e, st) {
        Log.e(_tag, 'stop() failed', e, st);
        setState(() => _error = 'Не удалось свести запись: $e');
      }
      setState(() => _isProcessing = false);
      await _refresh();
      return;
    }

    Log.i(_tag, 'user pressed record');
    try {
      // start() itself requests every permission it needs and only begins
      // writing once the user has answered; nothing is recorded before that.
      await _session.start();
      setState(() => _isRecording = true);
      if (!_session.systemAudioAvailable) {
        setState(() => _error =
            'Записываю только микрофон — доступ к записи экрана не выдан.');
      }
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
      _micLevelSub = _session.micLevelStream().listen((level) {
        setState(() => _micLevel = level);
      });
      _systemLevelTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
        final level = await _session.systemLevel();
        if (mounted) setState(() => _systemLevel = level);
      });
    } catch (e, st) {
      Log.e(_tag, 'start() failed', e, st);
      setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(Recording recording) async {
    if (_playingId == recording.id) {
      await _player.stop();
      setState(() => _playingId = null);
    }
    await _repository.delete(recording);
    setState(() => _waveforms.remove(recording.id));
    await _refresh();
  }

  Future<void> _togglePlay(Recording recording) async {
    if (_playingId == recording.id) {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    setState(() {
      _playingId = recording.id;
      _playbackPosition = Duration.zero;
    });
    try {
      final duration = await _player.setFilePath(recording.path);
      setState(() => _playbackDuration = duration ?? recording.duration);
      await _player.play();
    } catch (e, st) {
      Log.e(_tag, 'playback failed for ${recording.path}', e, st);
      setState(() {
        _playingId = null;
        _error = 'Не удалось воспроизвести запись: $e';
      });
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('voxa')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _toggleRecording,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(
                    _isProcessing
                        ? 'Свожу запись…'
                        : _isRecording
                            ? 'Стоп'
                            : 'Записать',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.red : null,
                    foregroundColor: _isRecording ? Colors.white : null,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                ),
                if (_isRecording) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 12),
                    child: Text(
                      _formatDuration(_elapsed),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Column(
                      children: [
                        LevelMeter(label: 'Мик', level: _micLevel, color: Colors.deepPurple),
                        const SizedBox(height: 6),
                        if (_session.systemAudioAvailable)
                          LevelMeter(label: 'Система', level: _systemLevel, color: Colors.teal),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _recordings.isEmpty
                    ? const Center(child: Text('Записей пока нет'))
                    : ListView.builder(
                        itemCount: _recordings.length,
                        itemBuilder: (context, index) {
                          final r = _recordings[index];
                          final playing = _playingId == r.id;
                          final waveform = _waveforms[r.id];
                          final progress = playing && _playbackDuration.inMilliseconds > 0
                              ? _playbackPosition.inMilliseconds /
                                  _playbackDuration.inMilliseconds
                              : null;

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            child: Column(
                              children: [
                                ListTile(
                                  leading: IconButton(
                                    icon: Icon(
                                      playing && _playerBusy
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_fill,
                                    ),
                                    iconSize: 32,
                                    onPressed: () => _togglePlay(r),
                                  ),
                                  title: Text(DateFormat('d MMM, HH:mm').format(r.startedAt)),
                                  subtitle: Text(_formatDuration(r.duration)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(r),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                                  child: waveform == null
                                      ? const SizedBox(height: 36)
                                      : WaveformView(samples: waveform, progress: progress),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

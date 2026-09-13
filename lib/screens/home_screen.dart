import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/recording.dart';
import '../services/logger.dart';
import '../services/recording_session.dart';
import '../services/recordings_repository.dart';
import '../services/system_audio_recorder.dart';
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

  // Rolling window of recent levels, rendered as a live scrolling waveform
  // while recording — the clearest "yes, it's actually capturing sound"
  // signal, much more so than a single numeric bar.
  static const _liveHistoryLength = 120;
  final List<double> _micHistory = [];
  final List<double> _systemHistory = [];

  void _pushLevel(List<double> history, double level) {
    history.add(level);
    if (history.length > _liveHistoryLength) {
      history.removeAt(0);
    }
  }

  // Composite key "<recordingId>:<track>" (track is "mix"/"mic"/"system")
  // identifying which of the up-to-three tracks per recording is loaded.
  String? _playingKey;
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
          _playingKey = null;
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
        _micHistory.clear();
        _systemHistory.clear();
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
      _micHistory.clear();
      _systemHistory.clear();
      setState(() => _isRecording = true);
      if (!_session.systemAudioAvailable) {
        setState(() => _error =
            'Записываю только микрофон — доступ к записи экрана не выдан.');
      }
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
      _micLevelSub = _session.micLevelStream().listen((level) {
        setState(() {
          _micLevel = level;
          _pushLevel(_micHistory, level);
        });
      });
      _systemLevelTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
        final level = await _session.systemLevel();
        if (mounted) {
          setState(() {
            _systemLevel = level;
            _pushLevel(_systemHistory, level);
          });
        }
      });
    } catch (e, st) {
      Log.e(_tag, 'start() failed', e, st);
      setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(Recording recording) async {
    if (_playingKey?.startsWith('${recording.id}:') ?? false) {
      await _player.stop();
      setState(() => _playingKey = null);
    }
    await _repository.delete(recording);
    setState(() => _waveforms.remove(recording.id));
    await _refresh();
  }

  Future<void> _togglePlay(Recording recording, {required String track, required String path}) async {
    final key = '${recording.id}:$track';
    if (_playingKey == key) {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    setState(() {
      _playingKey = key;
      _playbackPosition = Duration.zero;
    });
    try {
      final duration = await _player.setFilePath(path);
      setState(() => _playbackDuration = duration ?? recording.duration);
      await _player.play();
    } catch (e, st) {
      Log.e(_tag, 'playback failed for $path', e, st);
      setState(() {
        _playingKey = null;
        _error = 'Не удалось воспроизвести запись: $e';
      });
    }
  }

  Widget _liveTrackRow({
    required String label,
    required double level,
    required List<double> history,
    required Color color,
  }) {
    // A silent recording still needs to visibly prove it's capturing —
    // a flat waveform reads as "broken", so a small pulsing dot next to
    // the label confirms the pipeline is live even at zero level.
    final isLive = level > 0.02;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isLive ? color : color.withValues(alpha: 0.25),
                ),
              ),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: history.isEmpty
              ? SizedBox(
                  height: 32,
                  child: Center(
                    child: Text(
                      '…',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: color.withValues(alpha: 0.5)),
                    ),
                  ),
                )
              : WaveformView(samples: history, height: 32, color: color),
        ),
      ],
    );
  }

  Widget _trackChip({
    required String label,
    required Recording recording,
    required String track,
    required String path,
  }) {
    final key = '${recording.id}:$track';
    final playing = _playingKey == key;
    return ActionChip(
      avatar: Icon(
        playing && _playerBusy ? Icons.pause : Icons.play_arrow,
        size: 18,
      ),
      label: Text(label),
      onPressed: () => _togglePlay(recording, track: track, path: path),
    );
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
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      children: [
                        _liveTrackRow(
                          label: 'Мик',
                          level: _micLevel,
                          history: _micHistory,
                          color: Colors.deepPurple,
                        ),
                        if (_session.systemAudioAvailable) ...[
                          const SizedBox(height: 10),
                          _liveTrackRow(
                            label: 'Система',
                            level: _systemLevel,
                            history: _systemHistory,
                            color: Colors.teal,
                          ),
                        ],
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
                          final mixKey = '${r.id}:mix';
                          final playingMix = _playingKey == mixKey;
                          final waveform = _waveforms[r.id];
                          final progress = playingMix && _playbackDuration.inMilliseconds > 0
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
                                      playingMix && _playerBusy
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_fill,
                                    ),
                                    iconSize: 32,
                                    tooltip: 'Свод (мик + система)',
                                    onPressed: () =>
                                        _togglePlay(r, track: 'mix', path: r.path),
                                  ),
                                  title: Text(DateFormat('d MMM, HH:mm').format(r.startedAt)),
                                  subtitle: Text(_formatDuration(r.duration)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _delete(r),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
                                  child: waveform == null
                                      ? const SizedBox(height: 36)
                                      : WaveformView(samples: waveform, progress: progress),
                                ),
                                if (r.micPath != null || r.systemPath != null)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                                    child: Row(
                                      children: [
                                        if (r.micPath != null)
                                          _trackChip(
                                            label: 'Мик',
                                            recording: r,
                                            track: 'mic',
                                            path: r.micPath!,
                                          ),
                                        if (r.micPath != null && r.systemPath != null)
                                          const SizedBox(width: 8),
                                        if (r.systemPath != null)
                                          _trackChip(
                                            label: 'Система',
                                            recording: r,
                                            track: 'system',
                                            path: r.systemPath!,
                                          ),
                                      ],
                                    ),
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

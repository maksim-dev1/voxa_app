import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/recording.dart';
import '../models/transcription_job.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/logger.dart';
import '../services/recording_session.dart';
import '../services/recordings_repository.dart';
import '../services/system_audio_recorder.dart';
import '../widgets/recording_indicator.dart';
import '../widgets/waveform_view.dart';
import 'transcript_screen.dart';

const _tag = 'HomeScreen';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.auth, required this.api});

  final AuthService auth;
  final ApiClient api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RecordingsRepository _repository = RecordingsRepository();
  late final RecordingSession _session = RecordingSession(_repository);
  final AudioPlayer _player = AudioPlayer();

  List<Recording> _recordings = [];
  final Map<String, List<double>> _waveforms = {};
  // Recording id -> latest known job (status + error), separate from
  // Recording.jobId which is just the id persisted on disk.
  final Map<String, TranscriptionJob> _jobs = {};
  final Set<String> _uploading = {};
  bool _loading = true;

  Timer? _pollTimer;

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
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollPendingJobs());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
    unawaited(_pollPendingJobs());
  }

  /// Checks status for every recording that has a job but isn't known to
  /// be done/failed yet. Cheap no-op when nothing is pending.
  Future<void> _pollPendingJobs() async {
    final token = widget.auth.token;
    if (token == null) return;

    for (final r in _recordings) {
      final jobId = r.jobId;
      if (jobId == null) continue;
      final known = _jobs[r.id];
      if (known != null && known.status != JobStatus.queued && known.status != JobStatus.processing) {
        continue;
      }
      try {
        final job = await widget.api.getJob(token, jobId);
        if (!mounted) return;
        setState(() => _jobs[r.id] = job);
      } catch (e, st) {
        Log.e(_tag, 'failed to poll job $jobId', e, st);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _delete(Recording recording) async {
    if (_playingKey?.startsWith('${recording.id}:') ?? false) {
      await _player.stop();
      setState(() => _playingKey = null);
    }
    await _repository.delete(recording);
    setState(() {
      _waveforms.remove(recording.id);
      _jobs.remove(recording.id);
    });
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
      setState(() => _playingKey = null);
      _showError('Не удалось воспроизвести запись: $e');
    }
  }

  Future<void> _upload(Recording recording) async {
    final token = widget.auth.token;
    if (token == null) return;

    setState(() => _uploading.add(recording.id));
    try {
      final jobId = await widget.api.uploadRecording(token, recording.path);
      await _repository.saveJobId(recording, jobId);
      if (!mounted) return;
      setState(() => _jobs[recording.id] = TranscriptionJob(id: jobId, status: JobStatus.queued));
      await _refresh();
    } on NetworkException catch (e) {
      _showError(e.toString());
    } on ApiException catch (e) {
      Log.w(_tag, 'upload failed: $e');
      _showError('Не удалось отправить запись: ${e.message}');
    } finally {
      if (mounted) setState(() => _uploading.remove(recording.id));
    }
  }

  Future<void> _openTranscript(Recording recording, String jobId) async {
    final token = widget.auth.token;
    if (token == null) return;
    try {
      final segments = await widget.api.getResult(token, jobId);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TranscriptScreen(segments: segments)),
      );
    } on NetworkException catch (e) {
      _showError(e.toString());
    } on ApiException catch (e) {
      _showError('Не удалось загрузить транскрипт: ${e.message}');
    }
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

  Widget _transcriptionStatus(Recording recording) {
    final uploading = _uploading.contains(recording.id);
    if (uploading) {
      return const Chip(
        avatar: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('Отправляю…'),
      );
    }

    final job = _jobs[recording.id];
    if (job == null) {
      return ActionChip(
        avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
        label: const Text('На транскрипцию'),
        onPressed: () => _upload(recording),
      );
    }

    switch (job.status) {
      case JobStatus.queued:
      case JobStatus.processing:
        return Chip(
          avatar: const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: Text(job.status == JobStatus.queued ? 'В очереди…' : 'Обрабатывается…'),
        );
      case JobStatus.done:
        return ActionChip(
          avatar: const Icon(Icons.description_outlined, size: 18),
          label: const Text('Транскрипт'),
          onPressed: () => _openTranscript(recording, job.id),
        );
      case JobStatus.failed:
        return ActionChip(
          avatar: Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
          label: const Text('Ошибка'),
          onPressed: () => _showError(job.error ?? 'Транскрипция не удалась'),
        );
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
      appBar: AppBar(
        title: const Text('voxa'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: widget.auth.logout,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: RecordingIndicator(
              session: _session,
              onFinished: (path) {
                Log.i(_tag, 'recording finalized at $path');
                _refresh();
              },
              onProcessingChanged: (_) {},
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
                                Padding(
                                  padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      if (r.micPath != null)
                                        _trackChip(
                                          label: 'Мик',
                                          recording: r,
                                          track: 'mic',
                                          path: r.micPath!,
                                        ),
                                      if (r.systemPath != null)
                                        _trackChip(
                                          label: 'Система',
                                          recording: r,
                                          track: 'system',
                                          path: r.systemPath!,
                                        ),
                                      _transcriptionStatus(r),
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

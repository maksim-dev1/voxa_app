import 'dart:async';

import 'package:flutter/material.dart';

import '../services/logger.dart';
import '../services/recording_session.dart';
import 'waveform_view.dart';

const _tag = 'RecordingIndicator';

/// Owns the entire live-recording UI: the record/stop button, elapsed
/// timer, and live mic/system waveforms. Deliberately its own widget with
/// its own State — the level meters tick every ~150ms, and if that lived
/// in the parent screen's State, every tick would rebuild the whole
/// recordings list (waveform painters and all) along with it.
class RecordingIndicator extends StatefulWidget {
  const RecordingIndicator({
    super.key,
    required this.session,
    required this.onFinished,
    required this.onProcessingChanged,
  });

  final RecordingSession session;

  /// Called with the final mixed-down recording path once stop() +
  /// mixdown succeed, so the parent can refresh its list.
  final ValueChanged<String> onFinished;

  /// Called with true right when mixdown starts and false once it settles,
  /// so the parent can disable other actions (e.g. deleting) meanwhile if
  /// it wants to — currently unused for gating, just for awareness.
  final ValueChanged<bool> onProcessingChanged;

  @override
  State<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator> {
  bool _isRecording = false;
  bool _isProcessing = false;
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

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _micLevelSub?.cancel();
    _systemLevelTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
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
      widget.onProcessingChanged(true);

      try {
        final path = await widget.session.stop();
        Log.i(_tag, 'recording finalized at $path');
        widget.onFinished(path);
      } catch (e, st) {
        Log.e(_tag, 'stop() failed', e, st);
        if (mounted) setState(() => _error = 'Не удалось свести запись: $e');
      }
      if (mounted) setState(() => _isProcessing = false);
      widget.onProcessingChanged(false);
      return;
    }

    Log.i(_tag, 'user pressed record');
    try {
      // start() itself requests every permission it needs and only begins
      // writing once the user has answered; nothing is recorded before that.
      await widget.session.start();
      _micHistory.clear();
      _systemHistory.clear();
      setState(() => _isRecording = true);
      if (!widget.session.systemAudioAvailable) {
        setState(() => _error =
            'Записываю только микрофон — доступ к записи экрана не выдан.');
      }
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
      _micLevelSub = widget.session.micLevelStream().listen((level) {
        setState(() {
          _micLevel = level;
          _pushLevel(_micHistory, level);
        });
      });
      _systemLevelTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
        final level = await widget.session.systemLevel();
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
          width: 82,
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
    return Column(
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
          onPressed: _isProcessing ? null : _toggle,
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
                if (widget.session.systemAudioAvailable) ...[
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
    );
  }
}

import 'package:flutter/material.dart';

/// Static peak-amplitude waveform, drawn as a bar chart from precomputed
/// 0..1 samples (see SystemAudioRecorder.extractWaveform).
class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.samples,
    this.height = 36,
    this.progress,
    this.color,
  });

  final List<double> samples;
  final double height;

  /// 0..1 playback progress; painted bars before this point are highlighted.
  final double? progress;

  /// Overrides the theme's primary color, e.g. to match a per-track color
  /// (mic vs system) in a live meter.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return SizedBox(height: height);
    }
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(samples: samples, color: color, progress: progress),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.samples, required this.color, this.progress});

  final List<double> samples;
  final Color color;
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final barWidth = size.width / samples.length;
    final playedColor = color;
    final unplayedColor = color.withValues(alpha: 0.35);
    final playedUntil = progress != null ? (samples.length * progress!).round() : -1;

    for (var i = 0; i < samples.length; i++) {
      final amplitude = samples[i].clamp(0.0, 1.0);
      final barHeight = (amplitude * size.height).clamp(2.0, size.height);
      final left = i * barWidth;
      final rect = Rect.fromLTWH(
        left,
        (size.height - barHeight) / 2,
        (barWidth - 1).clamp(1.0, barWidth),
        barHeight,
      );
      final paint = Paint()
        ..color = i <= playedUntil ? playedColor : unplayedColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.samples != samples || oldDelegate.progress != progress;
  }
}

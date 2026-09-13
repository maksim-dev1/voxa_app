import 'package:flutter/material.dart';

/// Thin horizontal bar showing a live 0..1 audio level, e.g. mic or
/// system-audio input while recording.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.label, required this.level, required this.color});

  final String label;
  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: level.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../models/transcript_segment.dart';

class TranscriptScreen extends StatelessWidget {
  const TranscriptScreen({super.key, required this.segments});

  final List<TranscriptSegment> segments;

  String _formatTime(double seconds) {
    final d = Duration(milliseconds: (seconds * 1000).round());
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Транскрипт')),
      body: segments.isEmpty
          ? const Center(child: Text('Пусто — речь не распознана'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: segments.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final seg = segments[index];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        _formatTime(seg.start),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (seg.speaker != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                seg.speaker!,
                                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          Text(seg.text),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

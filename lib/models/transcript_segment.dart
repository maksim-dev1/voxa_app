class TranscriptSegment {
  TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
  });

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      start: (json['start'] as num).toDouble(),
      end: (json['end'] as num).toDouble(),
      text: json['text'] as String,
      speaker: json['speaker'] as String?,
    );
  }

  final double start;
  final double end;
  final String text;
  final String? speaker;
}

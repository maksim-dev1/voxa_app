class Recording {
  Recording({
    required this.id,
    required this.startedAt,
    required this.path,
    required this.duration,
  });

  final String id;
  final DateTime startedAt;
  final String path;
  final Duration duration;
}

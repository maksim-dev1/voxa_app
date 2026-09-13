class Recording {
  Recording({
    required this.id,
    required this.startedAt,
    required this.path,
    required this.duration,
    this.micPath,
    this.systemPath,
  });

  final String id;
  final DateTime startedAt;

  /// The mixed (mic + system) track — what plays by default.
  final String path;
  final Duration duration;

  /// Raw mic-only track, kept alongside the mix so either side of a call
  /// can be listened to separately. Null if it was cleaned up already.
  final String? micPath;

  /// Raw system-only track. Null when the recording was mic-only (no
  /// screen-recording permission) or the file was cleaned up.
  final String? systemPath;
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';

/// Owns the on-disk layout for recordings: one folder per session under
/// `<app documents>/voxa_recordings/<timestamp>/`. During recording it holds
/// raw mic.m4a / system.m4a; once mixed down, only recording.m4a remains
/// (the raw tracks are deleted) — that's the single file the rest of the
/// app deals with.
class RecordingsRepository {
  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/voxa_recordings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> createSessionDir(DateTime startedAt) async {
    final root = await _rootDir();
    final id = startedAt.millisecondsSinceEpoch.toString();
    final dir = Directory('${root.path}/$id');
    await dir.create(recursive: true);
    return dir;
  }

  String rawMicPath(Directory sessionDir) => '${sessionDir.path}/mic.m4a';
  String rawSystemPath(Directory sessionDir) => '${sessionDir.path}/system.m4a';
  String finalPath(Directory sessionDir) => '${sessionDir.path}/recording.m4a';

  Future<List<Recording>> listRecordings() async {
    final root = await _rootDir();
    if (!await root.exists()) return [];

    final entries = await root.list().toList();
    final sessions = entries.whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    final result = <Recording>[];
    for (final dir in sessions) {
      final file = File(finalPath(dir));
      if (!await file.exists()) continue;

      final id = dir.path.split('/').last;
      final startedAt = DateTime.fromMillisecondsSinceEpoch(
        int.tryParse(id) ?? 0,
      );

      result.add(
        Recording(
          id: id,
          startedAt: startedAt,
          path: file.path,
          duration: Duration(milliseconds: await _estimateDurationMs(file)),
        ),
      );
    }
    return result;
  }

  Future<void> delete(Recording recording) async {
    final dir = File(recording.path).parent;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Rough duration estimate from file size (AAC ~128kbps stereo); good
  /// enough for a list label until playback metadata is wired up.
  Future<int> _estimateDurationMs(File file) async {
    try {
      final bytes = await file.length();
      const bytesPerSecond = 128000 / 8;
      return ((bytes / bytesPerSecond) * 1000).round();
    } catch (_) {
      return 0;
    }
  }
}

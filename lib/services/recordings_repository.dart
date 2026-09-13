import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/recording.dart';

/// Owns the on-disk layout for recordings: one folder per session under
/// `<app documents>/voxa_recordings/<timestamp>/`, holding recording.m4a
/// (the mix, what plays by default) alongside the raw mic.m4a / system.m4a
/// it was built from — kept around so either side of a call can be played
/// back separately.
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
  String _jobMetaPath(Directory sessionDir) => '${sessionDir.path}/job.json';

  /// Persists the server job id for a recording so it survives an app
  /// restart — upload status isn't re-derivable from the audio file alone.
  Future<void> saveJobId(Recording recording, String jobId) async {
    final dir = File(recording.path).parent;
    await File(_jobMetaPath(dir)).writeAsString(jsonEncode({'job_id': jobId}));
  }

  Future<String?> _loadJobId(Directory sessionDir) async {
    final file = File(_jobMetaPath(sessionDir));
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return data['job_id'] as String?;
    } catch (_) {
      return null;
    }
  }

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

      final micFile = File(rawMicPath(dir));
      final systemFile = File(rawSystemPath(dir));

      result.add(
        Recording(
          id: id,
          startedAt: startedAt,
          path: file.path,
          duration: Duration(milliseconds: await _estimateDurationMs(file)),
          micPath: await micFile.exists() ? micFile.path : null,
          systemPath: await systemFile.exists() ? systemFile.path : null,
          jobId: await _loadJobId(dir),
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

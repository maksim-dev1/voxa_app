enum JobStatus { queued, processing, done, failed }

JobStatus jobStatusFromString(String s) {
  switch (s) {
    case 'queued':
      return JobStatus.queued;
    case 'processing':
      return JobStatus.processing;
    case 'done':
      return JobStatus.done;
    case 'failed':
      return JobStatus.failed;
    default:
      throw ArgumentError('Unknown job status: $s');
  }
}

class TranscriptionJob {
  TranscriptionJob({required this.id, required this.status, this.error});

  factory TranscriptionJob.fromJson(Map<String, dynamic> json) {
    return TranscriptionJob(
      id: json['id'] as String,
      status: jobStatusFromString(json['status'] as String),
      error: json['error'] as String?,
    );
  }

  final String id;
  final JobStatus status;
  final String? error;
}

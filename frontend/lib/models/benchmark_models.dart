class BenchmarkRun {
  const BenchmarkRun({
    required this.id,
    required this.name,
    required this.creationDate,
    required this.runDate,
    required this.description,
    required this.lmStudioUrl,
    required this.model,
    required this.frameSampleRate,
    required this.saveSampleFrames,
    required this.batchSameEvidenceSpans,
    required this.outputFolder,
    required this.qaFiles,
    required this.status,
    required this.progress,
    required this.error,
    required this.metrics,
    required this.canStart,
    required this.canResume,
  });

  final String id;
  final String name;
  final String creationDate;
  final String runDate;
  final String description;
  final String lmStudioUrl;
  final String model;
  final int frameSampleRate;
  final bool saveSampleFrames;
  final bool batchSameEvidenceSpans;
  final String outputFolder;
  final List<String> qaFiles;
  final String status;
  final BenchmarkProgress progress;
  final String error;
  final BenchmarkMetrics metrics;
  final bool canStart;
  final bool canResume;

  bool get isRunning => status == 'queued' || status == 'running';

  factory BenchmarkRun.fromJson(Map<String, dynamic> json) {
    return BenchmarkRun(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      creationDate: json['creation_date']?.toString() ?? json['creationDate']?.toString() ?? '',
      runDate: json['run_date']?.toString() ?? json['runDate']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      lmStudioUrl: json['lm_studio_url']?.toString() ?? json['lmStudioUrl']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      frameSampleRate: _int(json['frame_sample_rate'] ?? json['frameSampleRate']),
      saveSampleFrames: json['save_sample_frames'] == true || json['saveSampleFrames'] == true,
      batchSameEvidenceSpans: json['batch_same_evidence_spans'] != false && json['batchSameEvidenceSpans'] != false,
      outputFolder: json['output_folder']?.toString() ?? json['outputFolder']?.toString() ?? '',
      qaFiles: _stringList(json['qa_files'] ?? json['qaFiles']),
      status: json['status']?.toString() ?? 'unknown',
      progress: BenchmarkProgress.fromJson(Map<String, dynamic>.from((json['progress'] as Map?) ?? const {})),
      error: json['error']?.toString() ?? '',
      metrics: BenchmarkMetrics.fromJson(Map<String, dynamic>.from((json['metrics'] as Map?) ?? const {})),
      canStart: json['canStart'] == true,
      canResume: json['canResume'] == true,
    );
  }
}

class BenchmarkProgress {
  const BenchmarkProgress({required this.processedQuestions, required this.totalQuestions, required this.percent});

  final int processedQuestions;
  final int totalQuestions;
  final int percent;

  factory BenchmarkProgress.fromJson(Map<String, dynamic> json) {
    return BenchmarkProgress(
      processedQuestions: _int(json['processedQuestions']),
      totalQuestions: _int(json['totalQuestions']),
      percent: _int(json['percent']),
    );
  }
}

class BenchmarkMetricBucket {
  const BenchmarkMetricBucket({required this.correct, required this.count, required this.percent});

  final int correct;
  final int count;
  final double percent;

  factory BenchmarkMetricBucket.fromJson(Map<String, dynamic> json) {
    return BenchmarkMetricBucket(
      correct: _int(json['correct']),
      count: _int(json['count']),
      percent: _double(json['percent']),
    );
  }
}

class BenchmarkMetrics {
  const BenchmarkMetrics({required this.total, required this.byFamily, required this.dayNight});

  final BenchmarkMetricBucket total;
  final Map<String, BenchmarkMetricBucket> byFamily;
  final Map<String, BenchmarkMetricBucket> dayNight;

  factory BenchmarkMetrics.fromJson(Map<String, dynamic> json) {
    return BenchmarkMetrics(
      total: BenchmarkMetricBucket.fromJson(Map<String, dynamic>.from((json['total'] as Map?) ?? const {})),
      byFamily: _bucketMap(json['byFamily']),
      dayNight: _bucketMap(json['dayNight']),
    );
  }
}

class BenchmarkEvent {
  const BenchmarkEvent({required this.index, required this.type, required this.message, required this.timestamp});

  final int index;
  final String type;
  final String message;
  final String timestamp;

  factory BenchmarkEvent.fromJson(Map<String, dynamic> json) {
    return BenchmarkEvent(
      index: _int(json['index']),
      type: json['type']?.toString() ?? 'log',
      message: json['message']?.toString() ?? '',
      timestamp: json['ts']?.toString() ?? '',
    );
  }
}

Map<String, BenchmarkMetricBucket> _bucketMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return {
    for (final entry in value.entries)
      entry.key.toString(): BenchmarkMetricBucket.fromJson(Map<String, dynamic>.from((entry.value as Map?) ?? const {})),
  };
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map((item) => item.toString()).toList(growable: false);
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

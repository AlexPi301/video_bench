import 'dart:convert';
import 'dart:html' as html;

import '../models/benchmark_models.dart';

class BenchmarkCreateRequest {
  const BenchmarkCreateRequest({
    required this.name,
    required this.creationDate,
    required this.runDate,
    required this.description,
    required this.lmStudioUrl,
    required this.frameSampleRate,
    required this.saveSampleFrames,
    required this.batchSameEvidenceSpans,
    required this.skipEvidenceAboveThreshold,
    required this.evidenceDurationThresholdSeconds,
    required this.outputFolder,
    required this.qaFiles,
  });

  final String name;
  final String creationDate;
  final String runDate;
  final String description;
  final String lmStudioUrl;
  final int frameSampleRate;
  final bool saveSampleFrames;
  final bool batchSameEvidenceSpans;
  final bool skipEvidenceAboveThreshold;
  final double evidenceDurationThresholdSeconds;
  final String outputFolder;
  final List<String> qaFiles;

  Map<String, dynamic> toJson() => {
        'name': name,
        'creationDate': creationDate,
        'runDate': runDate,
        'description': description,
        'lmStudioUrl': lmStudioUrl,
        'frameSampleRate': frameSampleRate,
        'saveSampleFrames': saveSampleFrames,
        'batchSameEvidenceSpans': batchSameEvidenceSpans,
        'skipEvidenceAboveThreshold': skipEvidenceAboveThreshold,
        'evidenceDurationThresholdSeconds': evidenceDurationThresholdSeconds,
        'outputFolder': outputFolder,
        'qaFiles': qaFiles,
      };
}

typedef BenchmarkUpdateRequest = BenchmarkCreateRequest;

class BenchmarkRunCreateRequest {
  const BenchmarkRunCreateRequest({required this.model});
  final String model;
  Map<String, dynamic> toJson() => {'model': model};
}

class BenchmarkEventsPage {
  const BenchmarkEventsPage({required this.events, required this.next});
  final List<BenchmarkEvent> events;
  final int next;
}

class BenchmarksClient {
  const BenchmarksClient();

  Future<List<Benchmark>> listBenchmarks() async {
    final text = await html.HttpRequest.getString('/api/benchmarks/');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final raw = json['benchmarks'];
    return raw is List ? raw.whereType<Map>().map((item) => Benchmark.fromJson(Map<String, dynamic>.from(item))).toList(growable: false) : const [];
  }

  Future<Benchmark> createBenchmark(BenchmarkCreateRequest request) async {
    final response = await html.HttpRequest.request('/api/benchmarks/create/', method: 'POST', requestHeaders: {'Content-Type': 'application/json'}, sendData: jsonEncode(request.toJson()));
    return Benchmark.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<Benchmark> updateBenchmark(String benchmarkId, BenchmarkUpdateRequest request) async {
    final response = await html.HttpRequest.request('/api/benchmarks/$benchmarkId/edit/', method: 'POST', requestHeaders: {'Content-Type': 'application/json'}, sendData: jsonEncode(request.toJson()));
    return Benchmark.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<void> deleteBenchmark(String benchmarkId) async {
    await html.HttpRequest.request('/api/benchmarks/$benchmarkId/delete/', method: 'DELETE');
  }

  Future<BenchmarkRun> addRun(String benchmarkId, BenchmarkRunCreateRequest request) async {
    final response = await html.HttpRequest.request('/api/benchmarks/$benchmarkId/runs/create/', method: 'POST', requestHeaders: {'Content-Type': 'application/json'}, sendData: jsonEncode(request.toJson()));
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> startRun(String benchmarkId, String runId) async {
    final response = await html.HttpRequest.request('/api/benchmarks/$benchmarkId/runs/$runId/start/', method: 'POST');
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> resumeRun(String benchmarkId, String runId) async {
    final response = await html.HttpRequest.request('/api/benchmarks/$benchmarkId/runs/$runId/resume/', method: 'POST');
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> pauseRun(String benchmarkId, String runId) async {
    final response = await html.HttpRequest.request('/api/benchmarks/$benchmarkId/runs/$runId/pause/', method: 'POST');
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<void> deleteRun(String benchmarkId, String runId) async {
    await html.HttpRequest.request('/api/benchmarks/$benchmarkId/runs/$runId/delete/', method: 'DELETE');
  }

  Future<BenchmarkEventsPage> getEvents(String benchmarkId, String runId, int after) async {
    final text = await html.HttpRequest.getString('/api/benchmarks/$benchmarkId/runs/$runId/events/?after=$after');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawEvents = json['events'];
    return BenchmarkEventsPage(
      events: rawEvents is List ? rawEvents.whereType<Map>().map((event) => BenchmarkEvent.fromJson(Map<String, dynamic>.from(event))).toList(growable: false) : const [],
      next: _int(json['next']),
    );
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

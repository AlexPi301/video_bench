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
    required this.model,
    required this.frameSampleRate,
    required this.saveSampleFrames,
    required this.batchSameEvidenceSpans,
    required this.outputFolder,
    required this.qaFiles,
  });

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

  Map<String, dynamic> toJson() => {
        'name': name,
        'creationDate': creationDate,
        'runDate': runDate,
        'description': description,
        'lmStudioUrl': lmStudioUrl,
        'model': model,
        'frameSampleRate': frameSampleRate,
        'saveSampleFrames': saveSampleFrames,
        'batchSameEvidenceSpans': batchSameEvidenceSpans,
        'outputFolder': outputFolder,
        'qaFiles': qaFiles,
      };
}

class BenchmarkUpdateRequest {
  const BenchmarkUpdateRequest({
    required this.name,
    required this.creationDate,
    required this.runDate,
    required this.description,
    required this.lmStudioUrl,
    required this.frameSampleRate,
    required this.saveSampleFrames,
    required this.batchSameEvidenceSpans,
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
        'outputFolder': outputFolder,
        'qaFiles': qaFiles,
      };
}

class BenchmarkEventsPage {
  const BenchmarkEventsPage({required this.events, required this.next});

  final List<BenchmarkEvent> events;
  final int next;
}

class BenchmarksClient {
  const BenchmarksClient();

  Future<List<BenchmarkRun>> listRuns() async {
    final text = await html.HttpRequest.getString('/api/benchmarks/runs/');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawRuns = json['runs'];
    return rawRuns is List
        ? rawRuns.whereType<Map>().map((run) => BenchmarkRun.fromJson(Map<String, dynamic>.from(run))).toList(growable: false)
        : const [];
  }

  Future<BenchmarkRun> createRun(BenchmarkCreateRequest request) async {
    final response = await html.HttpRequest.request(
      '/api/benchmarks/runs/create/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode(request.toJson()),
    );
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> updateRun(String runId, BenchmarkUpdateRequest request) async {
    final response = await html.HttpRequest.request(
      '/api/benchmarks/runs/$runId/edit/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode(request.toJson()),
    );
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> getRun(String runId) async {
    final text = await html.HttpRequest.getString('/api/benchmarks/runs/$runId/');
    return BenchmarkRun.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<BenchmarkRun> startRun(String runId) async {
    final response = await html.HttpRequest.request('/api/benchmarks/runs/$runId/start/', method: 'POST');
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<BenchmarkRun> resumeRun(String runId) async {
    final response = await html.HttpRequest.request('/api/benchmarks/runs/$runId/resume/', method: 'POST');
    return BenchmarkRun.fromJson(jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>);
  }

  Future<void> deleteRun(String runId) async {
    await html.HttpRequest.request('/api/benchmarks/runs/$runId/delete/', method: 'DELETE');
  }

  Future<BenchmarkEventsPage> getEvents(String runId, int after) async {
    final text = await html.HttpRequest.getString('/api/benchmarks/runs/$runId/events/?after=$after');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawEvents = json['events'];
    return BenchmarkEventsPage(
      events: rawEvents is List
          ? rawEvents.whereType<Map>().map((event) => BenchmarkEvent.fromJson(Map<String, dynamic>.from(event))).toList(growable: false)
          : const [],
      next: _int(json['next']),
    );
  }
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

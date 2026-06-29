import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import '../models/impact_cycle_models.dart';

class ImpactCycleUpload {
  const ImpactCycleUpload({required this.path, required this.filename, required this.url});

  final String path;
  final String filename;
  final String url;

  factory ImpactCycleUpload.fromJson(Map<String, dynamic> json) {
    return ImpactCycleUpload(
      path: json['path']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
    );
  }
}

class ImpactCycleEventsPage {
  const ImpactCycleEventsPage({required this.events, required this.next});

  final List<ImpactCycleEvent> events;
  final int next;
}

class ImpactCycleActivitiesPage {
  const ImpactCycleActivitiesPage({required this.activities});

  final List<ImpactCycleActivity> activities;
}

class ImpactCycleClient {
  const ImpactCycleClient();

  Future<ImpactCycleUpload> uploadVideo(dynamic file) async {
    final formData = html.FormData()..appendBlob('video', file as html.Blob, _fileName(file));
    final request = await html.HttpRequest.request(
      '/api/impact-cycle/uploads/',
      method: 'POST',
      sendData: formData,
    );
    return ImpactCycleUpload.fromJson(_decodeObject(request.responseText));
  }

  Future<ImpactCycleJob> createJob({
    required String sourceType,
    required String sourcePath,
    required String outputDirectory,
    required double samplingFps,
    required int maxFrames,
    required String backendProvider,
    bool directOutput = false,
  }) async {
    final request = await html.HttpRequest.request(
      '/api/impact-cycle/jobs/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode({
        'source': {'type': sourceType, 'path': sourcePath},
        'settings': {
          'samplingFps': samplingFps,
          'maxFrames': maxFrames,
          'backendProvider': backendProvider,
          'outputDirectory': outputDirectory,
          'directOutput': directOutput,
        },
      }),
    );
    return ImpactCycleJob.fromJson(_decodeObject(request.responseText));
  }

  Future<ImpactCycleBundle> getMountedBundle(String path) async {
    final uri = Uri(path: '/api/mounted-files/file/', queryParameters: {'path': path});
    final text = await html.HttpRequest.getString(uri.toString());
    return ImpactCycleBundle.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<List<ImpactCycleJob>> listJobs() async {
    final text = await html.HttpRequest.getString('/api/impact-cycle/jobs/');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawJobs = json['jobs'];
    return rawJobs is List
        ? rawJobs.whereType<Map>().map((job) => ImpactCycleJob.fromJson(Map<String, dynamic>.from(job))).toList(growable: false)
        : const [];
  }

  Future<ImpactCycleJob> getJob(String jobId) async {
    final text = await html.HttpRequest.getString('/api/impact-cycle/jobs/$jobId/');
    return ImpactCycleJob.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<ImpactCycleEventsPage> getEvents(String jobId, int after) async {
    final text = await html.HttpRequest.getString('/api/impact-cycle/jobs/$jobId/events/?after=$after');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawEvents = json['events'];
    return ImpactCycleEventsPage(
      events: rawEvents is List
          ? rawEvents.whereType<Map>().map((event) => ImpactCycleEvent.fromJson(Map<String, dynamic>.from(event))).toList(growable: false)
          : const [],
      next: _int(json['next']),
    );
  }

  Future<ImpactCycleBundle> getBundle(String jobId) async {
    final text = await html.HttpRequest.getString('/api/impact-cycle/jobs/$jobId/bundle/');
    return ImpactCycleBundle.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<void> cancelJob(String jobId) async {
    await html.HttpRequest.request('/api/impact-cycle/jobs/$jobId/cancel/', method: 'POST');
  }

  Future<ImpactCycleActivitiesPage> getActivities() async {
    final text = await html.HttpRequest.getString('/api/impact-cycle/activities/');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawActivities = json['activities'];
    return ImpactCycleActivitiesPage(
      activities: rawActivities is List
          ? rawActivities.whereType<Map>().map((activity) => ImpactCycleActivity.fromJson(Map<String, dynamic>.from(activity))).toList(growable: false)
          : const [],
    );
  }

  Map<String, dynamic> _decodeObject(String? text) => jsonDecode(text ?? '{}') as Map<String, dynamic>;

  String _fileName(dynamic file) {
    final name = (file as dynamic).name;
    return name?.toString() ?? 'video';
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

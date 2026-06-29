import 'dart:math' as math;

import 'video_report.dart';

class ImpactCycleJob {
  const ImpactCycleJob({
    required this.id,
    required this.operation,
    required this.status,
    required this.videoName,
    required this.videoUrl,
    required this.processedFrames,
    required this.totalFrames,
    required this.percent,
    required this.error,
    this.bundleUrl,
  });

  final String id;
  final String operation;
  final String status;
  final String videoName;
  final String videoUrl;
  final int processedFrames;
  final int totalFrames;
  final int percent;
  final String error;
  final String? bundleUrl;

  bool get isRunning => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';

  factory ImpactCycleJob.fromJson(Map<String, dynamic> json) {
    final progress = Map<String, dynamic>.from((json['progress'] as Map?) ?? const {});
    final video = Map<String, dynamic>.from((json['video'] as Map?) ?? const {});
    return ImpactCycleJob(
      id: json['id']?.toString() ?? '',
      operation: json['operation']?.toString() ?? 'sam3_precompute',
      status: json['status']?.toString() ?? 'unknown',
      videoName: video['name']?.toString() ?? 'video',
      videoUrl: video['url']?.toString() ?? '',
      processedFrames: _int(progress['processedFrames']),
      totalFrames: _int(progress['totalFrames']),
      percent: _int(progress['percent']),
      error: json['error']?.toString() ?? '',
      bundleUrl: json['bundleUrl']?.toString(),
    );
  }
}

class ImpactCycleEvent {
  const ImpactCycleEvent({required this.index, required this.type, required this.message, required this.timestamp});

  final int index;
  final String type;
  final String message;
  final String timestamp;

  factory ImpactCycleEvent.fromJson(Map<String, dynamic> json) {
    return ImpactCycleEvent(
      index: _int(json['index']),
      type: json['type']?.toString() ?? 'log',
      message: json['message']?.toString() ?? '',
      timestamp: json['ts']?.toString() ?? '',
    );
  }
}

class ImpactCycleActivity {
  const ImpactCycleActivity({required this.type, required this.status, required this.message, required this.jobId});

  final String type;
  final String status;
  final String message;
  final String jobId;

  bool get isFailure => status == 'failed';

  factory ImpactCycleActivity.fromJson(Map<String, dynamic> json) {
    return ImpactCycleActivity(
      type: json['type']?.toString() ?? 'activity',
      status: json['status']?.toString() ?? 'unknown',
      message: json['message']?.toString() ?? '',
      jobId: json['jobId']?.toString() ?? '',
    );
  }
}

class ImpactCycleBundle {
  const ImpactCycleBundle({required this.sourceFps, required this.pointsOfInterest, required this.graphs});

  final double sourceFps;
  final List<VideoPointOfInterest> pointsOfInterest;
  final List<ImpactCycleGraph> graphs;

  factory ImpactCycleBundle.fromJson(Map<String, dynamic> json) {
    final fps = _double(json['source_fps'], fallback: 1);
    final graphs = <ImpactCycleGraph>[];
    final points = <VideoPointOfInterest>[];
    final rawGraphs = json['graphs'];
    if (rawGraphs is List) {
      for (final rawGraph in rawGraphs) {
        if (rawGraph is! Map) {
          continue;
        }
        final graph = ImpactCycleGraph.fromJson(Map<String, dynamic>.from(rawGraph), fps);
        graphs.add(graph);
        points.addAll(graph.pointsOfInterest);
      }
    }
    points.sort((left, right) => left.timestamp.compareTo(right.timestamp));
    return ImpactCycleBundle(sourceFps: fps, pointsOfInterest: points, graphs: graphs);
  }
}

class ImpactCycleGraph {
  const ImpactCycleGraph({required this.frameIdx, required this.timeSec, required this.summary, required this.nodes, required this.edges});

  final int frameIdx;
  final double timeSec;
  final String summary;
  final List<ImpactCycleNode> nodes;
  final List<ImpactCycleEdge> edges;

  List<VideoPointOfInterest> get pointsOfInterest {
    return [
      for (final node in nodes)
        if (node.boundingBox != null)
          VideoPointOfInterest(
            objectId: node.numericId,
            objectType: node.label,
            timestamp: Duration(milliseconds: (timeSec * Duration.millisecondsPerSecond).round()),
            firstTimeSeen: Duration(milliseconds: (timeSec * Duration.millisecondsPerSecond).round()),
            totalScreenTime: Duration.zero,
            boundingBox: node.boundingBox!,
            confidence: node.score,
          ),
    ];
  }

  factory ImpactCycleGraph.fromJson(Map<String, dynamic> json, double sourceFps) {
    final meta = Map<String, dynamic>.from((json['metadata'] as Map?) ?? const {});
    final frameIdx = _int(json['frame_idx'] ?? meta['graph_frame_idx']);
    final timeSec = _double(json['time_sec'] ?? meta['graph_time_sec'], fallback: frameIdx / math.max(0.1, sourceFps));
    final rawNodes = json['nodes'];
    final rawEdges = json['edges'];
    return ImpactCycleGraph(
      frameIdx: frameIdx,
      timeSec: timeSec,
      summary: (json['summary'] ?? meta['global_semantic_summary'] ?? meta['global_summary'] ?? '').toString(),
      nodes: rawNodes is List
          ? rawNodes.whereType<Map>().map((node) => ImpactCycleNode.fromJson(Map<String, dynamic>.from(node))).toList(growable: false)
          : const [],
      edges: rawEdges is List
          ? rawEdges.whereType<Map>().map((edge) => ImpactCycleEdge.fromJson(Map<String, dynamic>.from(edge))).toList(growable: false)
          : const [],
    );
  }
}

class ImpactCycleNode {
  const ImpactCycleNode({required this.id, required this.label, required this.score, required this.boundingBox});

  final String id;
  final String label;
  final double score;
  final BoundingBox? boundingBox;

  int get numericId {
    final direct = int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), ''));
    if (direct != null) {
      return direct;
    }
    return id.hashCode.abs() % 100000;
  }

  factory ImpactCycleNode.fromJson(Map<String, dynamic> json) {
    return ImpactCycleNode(
      id: json['entity_id']?.toString() ?? json['id']?.toString() ?? '',
      label: json['canonical_label']?.toString() ?? json['label']?.toString() ?? 'object',
      score: _double(json['score']),
      boundingBox: _bbox(json['bbox']),
    );
  }
}

class ImpactCycleEdge {
  const ImpactCycleEdge({required this.sourceId, required this.relation, required this.targetId});

  final String sourceId;
  final String relation;
  final String targetId;

  factory ImpactCycleEdge.fromJson(Map<String, dynamic> json) {
    return ImpactCycleEdge(
      sourceId: json['src_id']?.toString() ?? '',
      relation: json['relation']?.toString() ?? '',
      targetId: json['dst_id']?.toString() ?? '',
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

double _double(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

BoundingBox? _bbox(Object? value) {
  if (value is! List || value.length < 4) {
    return null;
  }
  final x = _double(value[0]);
  final y = _double(value[1]);
  final w = _double(value[2]);
  final h = _double(value[3]);
  return BoundingBox(x1: x, y1: y, x2: x + w, y2: y + h);
}

const answerFormats = ['open_ended', 'multiple_choice', 'yes_no', 'numeric'];
const qaFamilies = [
  'object_attribute',
  'action_event',
  'temporal_reasoning',
  'spatial_relation',
  'scene_place',
  'trajectory_grounded',
  'day_night_robustness',
  'counting',
  'event_memory',
  'negative_absence',
  'ambiguity_aware',
];
const reasoningTypes = [
  'perception',
  'action_recognition',
  'temporal_ordering',
  'event_localization',
  'spatial_relation',
  'scene_understanding',
  'trajectory_alignment',
  'counting',
  'absence_detection',
  'ambiguity_handling',
];
const difficultyLevels = ['easy', 'medium', 'hard'];
const visibilityQualities = ['clear', 'blurred', 'occluded', 'dark', 'glare', 'mixed'];
const dayNightTags = ['day', 'night', 'mixed', 'unknown'];

class EvidenceSpan {
  const EvidenceSpan({
    required this.startSeconds,
    required this.endSeconds,
    this.startFrame,
    this.endFrame,
    this.description,
  });

  final double startSeconds;
  final double endSeconds;
  final int? startFrame;
  final int? endFrame;
  final String? description;

  Map<String, dynamic> toJson() => {
        'start_seconds': startSeconds,
        'end_seconds': endSeconds,
        'start_frame': startFrame,
        'end_frame': endFrame,
        'description': description,
      };

  factory EvidenceSpan.fromJson(Map<String, dynamic> json) {
    return EvidenceSpan(
      startSeconds: _double(json['start_seconds'], 'start_seconds'),
      endSeconds: _double(json['end_seconds'], 'end_seconds'),
      startFrame: _nullableInt(json['start_frame'], 'start_frame'),
      endFrame: _nullableInt(json['end_frame'], 'end_frame'),
      description: json['description']?.toString(),
    );
  }
}

class BenchmarkAnnotation {
  const BenchmarkAnnotation({
    required this.id,
    required this.videoId,
    required this.question,
    required this.answer,
    required this.answerFormat,
    required this.family,
    required this.reasoningTypes,
    required this.difficulty,
    required this.visibility,
    required this.dayNight,
    required this.evidenceSpans,
    required this.trajectoryLinkage,
    required this.choices,
    required this.answerAliases,
    required this.unanswerable,
  });

  final String id;
  final String videoId;
  final String question;
  final dynamic answer;
  final String answerFormat;
  final String family;
  final List<String> reasoningTypes;
  final String difficulty;
  final String visibility;
  final String dayNight;
  final List<EvidenceSpan> evidenceSpans;
  final Map<String, dynamic>? trajectoryLinkage;
  final List<String> choices;
  final List<String> answerAliases;
  final bool unanswerable;

  Duration get timestamp {
    final seconds = evidenceSpans.isEmpty ? 0.0 : evidenceSpans.first.startSeconds;
    return Duration(milliseconds: (seconds * Duration.millisecondsPerSecond).round());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'video_id': videoId,
        'question': question,
        'answer': answer,
        'answer_format': answerFormat,
        'family': family,
        'reasoning_types': reasoningTypes,
        'difficulty': difficulty,
        'visibility': visibility,
        'day_night': dayNight,
        'evidence_spans': [for (final span in evidenceSpans) span.toJson()],
        'trajectory_linkage': trajectoryLinkage,
        'choices': choices,
        'answer_aliases': answerAliases,
        'unanswerable': unanswerable,
      };

  factory BenchmarkAnnotation.fromJson(Map<String, dynamic> json) {
    return BenchmarkAnnotation(
      id: _string(json['id'], 'id'),
      videoId: _string(json['video_id'], 'video_id'),
      question: _string(json['question'], 'question'),
      answer: json['answer'],
      answerFormat: _enumString(json['answer_format'], 'answer_format', answerFormats),
      family: _enumString(json['family'], 'family', qaFamilies),
      reasoningTypes: _stringList(json['reasoning_types'], 'reasoning_types'),
      difficulty: _enumString(json['difficulty'], 'difficulty', difficultyLevels),
      visibility: _enumString(json['visibility'], 'visibility', visibilityQualities),
      dayNight: _enumString(json['day_night'], 'day_night', dayNightTags),
      evidenceSpans: _mapList(json['evidence_spans'], 'evidence_spans')
          .map(EvidenceSpan.fromJson)
          .toList(growable: false),
      trajectoryLinkage: json['trajectory_linkage'] == null
          ? null
          : Map<String, dynamic>.from(json['trajectory_linkage'] as Map),
      choices: _stringList(json['choices'] ?? const [], 'choices'),
      answerAliases: _stringList(json['answer_aliases'] ?? const [], 'answer_aliases'),
      unanswerable: json['unanswerable'] == true,
    );
  }
}

class AnnotationDataset {
  const AnnotationDataset({
    required this.name,
    required this.version,
    required this.description,
    required this.qaPairs,
  });

  final String name;
  final String version;
  final String? description;
  final List<BenchmarkAnnotation> qaPairs;

  AnnotationDataset add(BenchmarkAnnotation annotation) {
    return AnnotationDataset(
      name: name,
      version: version,
      description: description,
      qaPairs: [...qaPairs, annotation],
    );
  }

  AnnotationDataset replace(BenchmarkAnnotation annotation) {
    return AnnotationDataset(
      name: name,
      version: version,
      description: description,
      qaPairs: [
        for (final pair in qaPairs)
          if (pair.id == annotation.id) annotation else pair,
      ],
    );
  }

  AnnotationDataset delete(String id) {
    return AnnotationDataset(
      name: name,
      version: version,
      description: description,
      qaPairs: [for (final pair in qaPairs) if (pair.id != id) pair],
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'description': description,
        'qa_pairs': [for (final pair in qaPairs) pair.toJson()],
      };

  factory AnnotationDataset.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('qa_pairs')) {
      return AnnotationDataset(
        name: _string(json['name'], 'name'),
        version: json['version']?.toString() ?? '1.0',
        description: json['description']?.toString(),
        qaPairs: _mapList(json['qa_pairs'], 'qa_pairs')
            .map(BenchmarkAnnotation.fromJson)
            .toList(growable: false),
      );
    }

    final annotation = BenchmarkAnnotation.fromJson(json);
    return AnnotationDataset(
      name: '${annotation.videoId}_annotations',
      version: '1.0',
      description: 'Annotations imported in Video Bench',
      qaPairs: [annotation],
    );
  }
}

String _string(dynamic value, String field) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) {
    throw FormatException('Missing required annotation field: $field');
  }
  return text;
}

String _enumString(dynamic value, String field, List<String> allowed) {
  final text = _string(value, field);
  if (!allowed.contains(text)) {
    throw FormatException('Invalid $field: $text');
  }
  return text;
}

List<String> _stringList(dynamic value, String field) {
  if (value is! List) {
    throw FormatException('Expected list for annotation field: $field');
  }
  return [for (final item in value) item.toString()];
}

List<Map<String, dynamic>> _mapList(dynamic value, String field) {
  if (value is! List) {
    throw FormatException('Expected list for annotation field: $field');
  }
  return [for (final item in value) Map<String, dynamic>.from(item as Map)];
}

double _double(dynamic value, String field) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.parse(value);
  }
  throw FormatException('Missing numeric annotation field: $field');
}

int? _nullableInt(dynamic value, String field) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String && value.trim().isNotEmpty) {
    return int.parse(value);
  }
  throw FormatException('Invalid integer annotation field: $field');
}

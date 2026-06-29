import 'package:flutter_test/flutter_test.dart';
import 'package:video_bench_frontend/services/annotation_json_parser.dart';

void main() {
  group('AnnotationJsonParser', () {
    test('parses dataset annotation files', () {
      const json = '''{
  "name": "sample_annotations",
  "version": "1.0",
  "description": "Sample",
  "qa_pairs": [
    {
      "id": "qa_0001",
      "video_id": "sample_video",
      "question": "Is there a bicycle visible?",
      "answer": true,
      "answer_format": "yes_no",
      "family": "negative_absence",
      "reasoning_types": ["absence_detection"],
      "difficulty": "easy",
      "visibility": "clear",
      "day_night": "day",
      "evidence_spans": [
        {
          "start_seconds": 4.2,
          "end_seconds": 6.8,
          "start_frame": null,
          "end_frame": null,
          "description": "A bicycle is visible."
        }
      ],
      "trajectory_linkage": null,
      "choices": [],
      "answer_aliases": ["yes"],
      "unanswerable": false
    }
  ]
}''';

      final dataset = const AnnotationJsonParser().parse(json);

      expect(dataset.name, 'sample_annotations');
      expect(dataset.qaPairs, hasLength(1));
      expect(dataset.qaPairs.single.timestamp.inMilliseconds, 4200);
      expect(dataset.qaPairs.single.answer, true);
    });

    test('normalizes a single qa pair into a dataset', () {
      const json = '''{
  "id": "qa_0001",
  "video_id": "single_video",
  "question": "What is visible?",
  "answer": "a car",
  "answer_format": "open_ended",
  "family": "object_attribute",
  "reasoning_types": ["perception"],
  "difficulty": "medium",
  "visibility": "clear",
  "day_night": "unknown",
  "evidence_spans": [
    {"start_seconds": 1.0, "end_seconds": 1.0, "start_frame": null, "end_frame": null, "description": null}
  ],
  "trajectory_linkage": null,
  "choices": [],
  "answer_aliases": [],
  "unanswerable": false
}''';

      final dataset = const AnnotationJsonParser().parse(json);

      expect(dataset.name, 'single_video_annotations');
      expect(dataset.qaPairs.single.id, 'qa_0001');
    });
  });
}

import 'dart:convert';

import '../models/annotation_dataset.dart';

class AnnotationJsonFormatException implements Exception {
  const AnnotationJsonFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AnnotationJsonParser {
  const AnnotationJsonParser();

  AnnotationDataset parse(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const FormatException('Annotation JSON root must be an object.');
      }
      return AnnotationDataset.fromJson(Map<String, dynamic>.from(decoded));
    } on AnnotationJsonFormatException {
      rethrow;
    } on FormatException catch (error) {
      throw AnnotationJsonFormatException(error.message);
    } catch (error) {
      throw AnnotationJsonFormatException('Could not parse annotation JSON: $error');
    }
  }

  String serialize(AnnotationDataset dataset) {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(dataset.toJson())}\n';
  }
}

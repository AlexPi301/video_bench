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
    final payload = dataset.toJson();
    final invalidPath = _firstInvalidJsonPath(payload);
    if (invalidPath != null) {
      throw AnnotationJsonFormatException('Annotation JSON contains a value that cannot be encoded at $invalidPath.');
    }
    try {
      return '${encoder.convert(payload)}\n';
    } on JsonUnsupportedObjectError catch (error) {
      throw AnnotationJsonFormatException('Annotation JSON contains an unsupported value: ${error.unsupportedObject}.');
    } on JsonCyclicError {
      throw const AnnotationJsonFormatException('Annotation JSON contains a cyclic object reference.');
    } catch (error) {
      throw AnnotationJsonFormatException('Could not encode annotation JSON: $error');
    }
  }

  String? _firstInvalidJsonPath(dynamic value, [String path = r'$']) {
    if (value == null || value is String || value is num || value is bool) {
      return null;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index += 1) {
        final childPath = _firstInvalidJsonPath(value[index], '$path[$index]');
        if (childPath != null) {
          return childPath;
        }
      }
      return null;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          return '$path.<non-string-key:${entry.key}>';
        }
        final childPath = _firstInvalidJsonPath(entry.value, '$path.${entry.key}');
        if (childPath != null) {
          return childPath;
        }
      }
      return null;
    }
    return '$path (${value.runtimeType}: $value)';
  }
}

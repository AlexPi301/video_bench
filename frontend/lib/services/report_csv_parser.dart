import 'dart:convert';

import 'package:csv/csv.dart';

import '../models/video_report.dart';

class ReportCsvFormatException implements Exception {
  ReportCsvFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ReportCsvParser {
  const ReportCsvParser();

  VideoReport parse(String csvContent) {
    final normalizedCsv = csvContent
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(normalizedCsv);

    if (rows.isEmpty) {
      throw ReportCsvFormatException('CSV report is empty.');
    }

    final header = rows.first.map((value) => value.toString().trim()).toList();
    final columns = <String, int>{
      for (var i = 0; i < header.length; i++) header[i]: i,
    };

    final objectIdIndex = _requiredColumn(columns, 'object_id');
    final firstTimeSeenIndex = _requiredColumn(columns, 'first_time_seen');
    final totalScreenTimeIndex = _requiredColumn(columns, 'total_screen_time');
    final objectTypeIndex = _requiredColumn(columns, 'object_type');
    final bboxIndex = _requiredColumn(columns, 'bbox-coords');

    final points = <VideoPointOfInterest>[];

    for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      if (row.every((value) => value.toString().trim().isEmpty)) {
        continue;
      }

      try {
        final objectId = int.parse(_cell(row, objectIdIndex));
        final firstTimeSeen = parseAnalyzerTimestamp(
          _cell(row, firstTimeSeenIndex),
        );
        final totalScreenTime = parseAnalyzerTimestamp(
          _cell(row, totalScreenTimeIndex),
        );
        final objectType = _cell(row, objectTypeIndex);
        final bboxJson = _decodeBboxJson(_cell(row, bboxIndex));
        final timestamp = bboxJson['timestamp'] == null
            ? firstTimeSeen
            : parseAnalyzerTimestamp(bboxJson['timestamp'].toString());

        points.add(VideoPointOfInterest(
          objectId: objectId,
          objectType: objectType,
          timestamp: timestamp,
          firstTimeSeen: firstTimeSeen,
          totalScreenTime: totalScreenTime,
          boundingBox: BoundingBox(
            x1: _number(bboxJson, 'x1'),
            y1: _number(bboxJson, 'y1'),
            x2: _number(bboxJson, 'x2'),
            y2: _number(bboxJson, 'y2'),
          ),
          confidence: bboxJson['confidence'] == null
              ? 0
              : (bboxJson['confidence'] as num).toDouble(),
        ));
      } on ReportCsvFormatException {
        rethrow;
      } catch (error) {
        throw ReportCsvFormatException(
          'Could not parse CSV report row ${rowIndex + 1}: $error',
        );
      }
    }

    points.sort((left, right) => left.timestamp.compareTo(right.timestamp));
    return VideoReport(pointsOfInterest: List.unmodifiable(points));
  }

  static int _requiredColumn(Map<String, int> columns, String column) {
    final index = columns[column];
    if (index == null) {
      throw ReportCsvFormatException('Missing required CSV column: $column');
    }
    return index;
  }

  static String _cell(List<dynamic> row, int index) {
    if (index >= row.length) {
      return '';
    }
    return row[index].toString().trim();
  }

  static double _number(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.parse(value);
    }
    throw ReportCsvFormatException('Missing numeric bbox field: $key');
  }

  static Map<String, dynamic> _decodeBboxJson(String value) {
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } on FormatException {
      final firstObject = _firstJsonObject(value);
      if (firstObject == null) {
        rethrow;
      }
      return jsonDecode(firstObject) as Map<String, dynamic>;
    }
  }

  static String? _firstJsonObject(String value) {
    final start = value.indexOf('{');
    if (start < 0) {
      return null;
    }

    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var index = start; index < value.length; index++) {
      final char = value.codeUnitAt(index);

      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == 0x5C) {
        escaped = inString;
        continue;
      }
      if (char == 0x22) {
        inString = !inString;
        continue;
      }
      if (inString) {
        continue;
      }
      if (char == 0x7B) {
        depth++;
      } else if (char == 0x7D) {
        depth--;
        if (depth == 0) {
          return value.substring(start, index + 1);
        }
      }
    }

    return null;
  }
}

Duration parseAnalyzerTimestamp(String value) {
  final parts = value.trim().split(RegExp('[:.]'));
  if (parts.length != 4) {
    throw ReportCsvFormatException('Invalid analyzer timestamp: $value');
  }

  return Duration(
    hours: int.parse(parts[0]),
    minutes: int.parse(parts[1]),
    seconds: int.parse(parts[2]),
    milliseconds: int.parse(parts[3]),
  );
}

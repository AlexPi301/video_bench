import 'package:flutter_test/flutter_test.dart';
import 'package:video_bench_frontend/services/report_csv_parser.dart';

void main() {
  group('ReportCsvParser', () {
    test('parses video_analyzer file based report rows', () {
      const csv = '''object_id,first_time_seen,total_screen_time,object_type,bbox-coords
5,00:00:05:334,00:00:00:667,plane,"{""timestamp"":""00:00:05:334"",""x1"":925.63,""y1"":44.99,""x2"":1214.13,""y2"":178.03,""confidence"":0.8632}"
22,00:00:16:002,00:00:01:333,truck,"{""timestamp"":""00:00:16:002"",""x1"":81.51,""y1"":0.1,""x2"":537.29,""y2"":186.37,""confidence"":0.9314}"
''';

      final report = const ReportCsvParser().parse(csv);

      expect(report.pointsOfInterest, hasLength(2));
      expect(report.pointsOfInterest.first.objectId, 5);
      expect(report.pointsOfInterest.first.objectType, 'plane');
      expect(report.pointsOfInterest.first.timestamp.inMilliseconds, 5334);
      expect(report.pointsOfInterest.first.boundingBox.x1, 925.63);
      expect(report.pointsOfInterest.first.confidence, 0.8632);
      expect(report.pointsOfInterest.last.objectType, 'truck');
    });

    test('sorts rows by bbox timestamp', () {
      const csv = '''object_id,first_time_seen,total_screen_time,object_type,bbox-coords
2,00:00:10:000,00:00:00:333,car,"{""timestamp"":""00:00:10:000"",""x1"":1,""y1"":2,""x2"":3,""y2"":4,""confidence"":0.8}"
1,00:00:01:000,00:00:00:333,car,"{""timestamp"":""00:00:01:000"",""x1"":1,""y1"":2,""x2"":3,""y2"":4,""confidence"":0.8}"
''';

      final report = const ReportCsvParser().parse(csv);

      expect(report.pointsOfInterest.map((point) => point.objectId), [1, 2]);
    });

    test('parses analyzer reports with carriage return line endings', () {
      const csv = 'object_id,first_time_seen,total_screen_time,object_type,bbox-coords\r'
          '1,00:00:00:000,00:00:07:667,truck,"{""timestamp"":""00:00:00:000"",""x1"":368.23,""y1"":62.55,""x2"":658.82,""y2"":290.76,""confidence"":0.9288}"\r'
          '2,00:00:01:000,00:00:00:667,car,"{""timestamp"":""00:00:01:000"",""x1"":1157.7,""y1"":229.98,""x2"":1279.36,""y2"":544.7,""confidence"":0.9211}"\r';

      final report = const ReportCsvParser().parse(csv);

      expect(report.pointsOfInterest, hasLength(2));
      expect(report.pointsOfInterest.first.objectType, 'truck');
      expect(report.pointsOfInterest.last.timestamp.inSeconds, 1);
    });

    test('recovers first bbox object if a field contains trailing data', () {
      const csv = '''object_id,first_time_seen,total_screen_time,object_type,bbox-coords
1,00:00:00:000,00:00:07:667,truck,"{""timestamp"":""00:00:00:000"",""x1"":368.23,""y1"":62.55,""x2"":658.82,""y2"":290.76,""confidence"":0.9288}
2,00:00:01:000,00:00:00:667,car"
''';

      final report = const ReportCsvParser().parse(csv);

      expect(report.pointsOfInterest.single.objectId, 1);
      expect(report.pointsOfInterest.single.boundingBox.x2, 658.82);
    });

    test('rejects reports with missing required columns', () {
      const csv = 'object_id,first_time_seen,object_type\n1,00:00:00:000,car\n';

      expect(
        () => const ReportCsvParser().parse(csv),
        throwsA(isA<ReportCsvFormatException>()),
      );
    });

    test('parses analyzer timestamp format', () {
      final timestamp = parseAnalyzerTimestamp('00:01:35:342');

      expect(timestamp.inMilliseconds, 95342);
    });
  });
}

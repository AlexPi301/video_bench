import 'dart:math' as math;

class BoundingBox {
  const BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  double get width => math.max(0, x2 - x1);
  double get height => math.max(0, y2 - y1);
}

class VideoPointOfInterest {
  const VideoPointOfInterest({
    required this.objectId,
    required this.objectType,
    required this.timestamp,
    required this.firstTimeSeen,
    required this.totalScreenTime,
    required this.boundingBox,
    required this.confidence,
  });

  final int objectId;
  final String objectType;
  final Duration timestamp;
  final Duration firstTimeSeen;
  final Duration totalScreenTime;
  final BoundingBox boundingBox;
  final double confidence;
}

class VideoReport {
  const VideoReport({required this.pointsOfInterest});

  final List<VideoPointOfInterest> pointsOfInterest;
}

String formatVideoTimestamp(Duration duration) {
  final totalMilliseconds = duration.inMilliseconds;
  final hours = totalMilliseconds ~/ Duration.millisecondsPerHour;
  final minutes = (totalMilliseconds ~/ Duration.millisecondsPerMinute) % 60;
  final seconds = (totalMilliseconds ~/ Duration.millisecondsPerSecond) % 60;
  final millis = totalMilliseconds % 1000;

  String two(int value) => value.toString().padLeft(2, '0');
  String three(int value) => value.toString().padLeft(3, '0');

  return '${two(hours)}:${two(minutes)}:${two(seconds)}.${three(millis)}';
}

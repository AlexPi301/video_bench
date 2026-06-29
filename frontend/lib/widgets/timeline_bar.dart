import 'package:flutter/material.dart';

import '../models/video_report.dart';

class TimelineBar extends StatelessWidget {
  const TimelineBar({
    super.key,
    required this.duration,
    required this.position,
    required this.pointsOfInterest,
    required this.onSeek,
  });

  final Duration duration;
  final Duration position;
  final List<VideoPointOfInterest> pointsOfInterest;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _handleTap(details.localPosition.dx, constraints.maxWidth),
          child: SizedBox(
            height: 48,
            child: CustomPaint(
              painter: _TimelinePainter(
                duration: duration,
                position: position,
                pointsOfInterest: pointsOfInterest,
                primary: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTap(double x, double width) {
    if (duration == Duration.zero || width <= 0) {
      return;
    }

    final nearestPoi = _nearestPoi(x, width);
    if (nearestPoi != null) {
      onSeek(nearestPoi.timestamp);
      return;
    }

    final ratio = (x / width).clamp(0.0, 1.0);
    onSeek(Duration(milliseconds: (duration.inMilliseconds * ratio).round()));
  }

  VideoPointOfInterest? _nearestPoi(double x, double width) {
    if (pointsOfInterest.isEmpty || duration == Duration.zero) {
      return null;
    }

    const hitRadius = 12.0;
    VideoPointOfInterest? closest;
    var closestDistance = double.infinity;

    for (final poi in pointsOfInterest) {
      final markerX = poi.timestamp.inMilliseconds / duration.inMilliseconds * width;
      final distance = (markerX - x).abs();
      if (distance < closestDistance) {
        closest = poi;
        closestDistance = distance;
      }
    }

    return closestDistance <= hitRadius ? closest : null;
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.duration,
    required this.position,
    required this.pointsOfInterest,
    required this.primary,
  });

  final Duration duration;
  final Duration position;
  final List<VideoPointOfInterest> pointsOfInterest;
  final Color primary;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final railRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - 4, size.width, 8),
      const Radius.circular(8),
    );
    final railPaint = Paint()..color = const Color(0xFF273044);
    canvas.drawRRect(railRect, railPaint);

    if (duration > Duration.zero) {
      final progress = (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - 4, size.width * progress, 8),
        const Radius.circular(8),
      );
      canvas.drawRRect(progressRect, Paint()..color = primary);

      for (final poi in pointsOfInterest) {
        final ratio = poi.timestamp.inMilliseconds / duration.inMilliseconds;
        if (ratio < 0 || ratio > 1) {
          continue;
        }
        final x = size.width * ratio;
        final markerPaint = Paint()..color = _markerColor(poi.objectType);
        final path = Path()
          ..moveTo(x, centerY - 14)
          ..lineTo(x + 6, centerY)
          ..lineTo(x, centerY + 14)
          ..lineTo(x - 6, centerY)
          ..close();
        canvas.drawPath(path, markerPaint);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = const Color(0xDD0F172A),
        );
      }

      final scrubberX = size.width * progress;
      canvas.drawCircle(
        Offset(scrubberX, centerY),
        8,
        Paint()..color = const Color(0xFFF8FAFC),
      );
      canvas.drawCircle(
        Offset(scrubberX, centerY),
        5,
        Paint()..color = primary,
      );
    }

    final endCapPaint = Paint()..color = const Color(0xFF64748B);
    canvas.drawCircle(Offset.zero.translate(0, centerY), 3, endCapPaint);
    canvas.drawCircle(Offset(size.width, centerY), 3, endCapPaint);
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position ||
        oldDelegate.pointsOfInterest != pointsOfInterest ||
        oldDelegate.primary != primary;
  }

  Color _markerColor(String type) {
    switch (type.toLowerCase()) {
      case 'car':
        return const Color(0xFF60A5FA);
      case 'truck':
        return const Color(0xFFF59E0B);
      case 'plane':
        return const Color(0xFFA78BFA);
      case 'person':
        return const Color(0xFFF472B6);
      default:
        return Color.lerp(const Color(0xFF94A3B8), primary, 0.2) ?? primary;
    }
  }
}

class PoiLegend extends StatelessWidget {
  const PoiLegend({super.key, required this.pointsOfInterest});

  final List<VideoPointOfInterest> pointsOfInterest;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final poi in pointsOfInterest) {
      counts.update(poi.objectType, (value) => value + 1, ifAbsent: () => 1);
    }

    if (counts.isEmpty) {
      return const Text('No points of interest loaded.');
    }

    final entries = counts.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in entries)
          Chip(
            avatar: CircleAvatar(
              backgroundColor: _legendColor(entry.key, Theme.of(context).colorScheme.primary),
              radius: 5,
            ),
            label: Text('${entry.key} ${entry.value}'),
          ),
      ],
    );
  }

  Color _legendColor(String type, Color primary) {
    switch (type.toLowerCase()) {
      case 'car':
        return const Color(0xFF60A5FA);
      case 'truck':
        return const Color(0xFFF59E0B);
      case 'plane':
        return const Color(0xFFA78BFA);
      case 'person':
        return const Color(0xFFF472B6);
      default:
        return Color.lerp(const Color(0xFF94A3B8), primary, 0.2) ?? primary;
    }
  }
}

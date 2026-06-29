import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import '../models/annotation_dataset.dart';
import '../models/video_report.dart';

class VideoSurfaceController extends ChangeNotifier {
  _WebVideoSurfaceState? _surface;
  String? _pendingVideoUrl;
  List<VideoPointOfInterest> _pointsOfInterest = const [];
  List<BenchmarkAnnotation> _annotations = const [];
  var _showBoundingBoxes = true;
  var _playbackRate = 1.0;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  var _isPlaying = false;
  var _isInteractionBlocked = false;

  Duration get duration => _duration;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  bool get hasVideo => _pendingVideoUrl != null;
  double get playbackRate => _playbackRate;
  bool get showBoundingBoxes => _showBoundingBoxes;

  void loadVideoUrl(String videoUrl) {
    _pendingVideoUrl = videoUrl;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    _surface?._load(videoUrl);
    notifyListeners();
  }

  void setPointsOfInterest(List<VideoPointOfInterest> pointsOfInterest) {
    _pointsOfInterest = List.unmodifiable(pointsOfInterest);
    _surface?._setPointsOfInterest(_pointsOfInterest);
  }

  void setAnnotations(List<BenchmarkAnnotation> annotations) {
    _annotations = List.unmodifiable(annotations);
    _surface?._setAnnotations(_annotations);
  }

  void setBoundingBoxesVisible(bool visible) {
    if (_showBoundingBoxes == visible) {
      return;
    }
    _showBoundingBoxes = visible;
    _surface?._setBoundingBoxesVisible(visible);
  }

  void setPlaybackRate(double rate) {
    _playbackRate = rate;
    _surface?._setPlaybackRate(rate);
    notifyListeners();
  }

  Future<void> play() async {
    await _surface?._play();
  }

  void pause() => _surface?._pause();

  void seekTo(Duration position) => _surface?._seekTo(position);

  String? captureCurrentFrameDataUrl() => _surface?._captureCurrentFrameDataUrl();

  void setInteractionBlocked(bool blocked) {
    _isInteractionBlocked = blocked;
    _surface?._setInteractionBlocked(blocked);
  }

  void _attach(_WebVideoSurfaceState surface) {
    _surface = surface;
    surface._setPointsOfInterest(_pointsOfInterest);
    surface._setAnnotations(_annotations);
    surface._setBoundingBoxesVisible(_showBoundingBoxes);
    surface._setPlaybackRate(_playbackRate);
    surface._setInteractionBlocked(_isInteractionBlocked);
    final videoUrl = _pendingVideoUrl;
    if (videoUrl != null) {
      surface._load(videoUrl);
    }
  }

  void _detach(_WebVideoSurfaceState surface) {
    if (_surface == surface) {
      _surface = null;
    }
  }

  void _sync({
    required Duration duration,
    required Duration position,
    required bool isPlaying,
  }) {
    if (_duration == duration && _position == position && _isPlaying == isPlaying) {
      return;
    }

    _duration = duration;
    _position = position;
    _isPlaying = isPlaying;
    notifyListeners();
  }
}

class WebVideoSurface extends StatefulWidget {
  const WebVideoSurface({
    super.key,
    required this.controller,
  });

  final VideoSurfaceController controller;

  @override
  State<WebVideoSurface> createState() => _WebVideoSurfaceState();
}

class _WebVideoSurfaceState extends State<WebVideoSurface> {
  static var _nextViewId = 0;

  late final String _viewType;
  late final html.DivElement _root;
  late final html.DivElement _videoWrap;
  late final html.DivElement _timeline;
  late final html.DivElement _progress;
  late final html.DivElement _markers;
  late final html.DivElement _hoverLine;
  late final html.DivElement _tooltip;
  late final html.VideoElement _video;
  late final html.CanvasElement _canvas;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _playbackTimer;
  List<VideoPointOfInterest> _pointsOfInterest = const [];
  List<BenchmarkAnnotation> _annotations = const [];
  var _showBoundingBoxes = true;

  @override
  void initState() {
    super.initState();
    _viewType = 'video-bench-surface-${_nextViewId++}';
    _root = html.DivElement()
      ..tabIndex = -1
      ..id = 'video-bench-video-surface-$_viewType'
      ..setAttribute('data-vb-role', 'video-surface')
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.overflow = 'hidden'
      ..style.backgroundColor = '#020617'
      ..style.borderRadius = '18px';
    _videoWrap = html.DivElement()
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.right = '0'
      ..style.bottom = '56px'
      ..style.overflow = 'hidden'
      ..style.backgroundColor = '#020617';
    _video = html.VideoElement()
      ..controls = false
      ..preload = 'metadata'
      ..setAttribute('data-vb-role', 'video-element')
      ..setAttribute('aria-label', 'Video Bench video')
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#020617';
    _video.setAttribute('playsinline', 'true');

    _canvas = html.CanvasElement()
      ..setAttribute('data-vb-role', 'overlay-canvas')
      ..setAttribute('aria-hidden', 'true')
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.pointerEvents = 'none';

    _timeline = html.DivElement()
      ..title = 'Timeline'
      ..setAttribute('data-vb-role', 'timeline')
      ..setAttribute('aria-label', 'Video timeline')
      ..style.position = 'absolute'
      ..style.left = '24px'
      ..style.right = '24px'
      ..style.bottom = '18px'
      ..style.height = '20px'
      ..style.overflow = 'hidden'
      ..style.cursor = 'pointer'
      ..style.borderRadius = '999px'
      ..style.background = 'linear-gradient(180deg, #334155 0%, #1E293B 100%)'
      ..style.boxShadow = 'inset 0 1px 2px rgba(255,255,255,0.10), 0 0 0 1px rgba(148,163,184,0.26), 0 12px 28px rgba(0,0,0,0.32)';
    _progress = html.DivElement()
      ..setAttribute('data-vb-role', 'timeline-progress')
      ..setAttribute('aria-hidden', 'true')
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.bottom = '0'
      ..style.width = '0%'
      ..style.borderRadius = '999px'
      ..style.background = 'linear-gradient(90deg, #22D3EE 0%, #6EE7B7 52%, #A7F3D0 100%)'
      ..style.boxShadow = '0 0 18px rgba(110,231,183,0.35)';
    _markers = html.DivElement()
      ..setAttribute('data-vb-role', 'timeline-markers')
      ..setAttribute('aria-hidden', 'false')
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.top = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.pointerEvents = 'none';
    _hoverLine = html.DivElement()
      ..setAttribute('data-vb-role', 'timeline-hover-line')
      ..setAttribute('aria-hidden', 'true')
      ..style.position = 'absolute'
      ..style.left = '0%'
      ..style.top = '-8px'
      ..style.width = '2px'
      ..style.height = '36px'
      ..style.borderRadius = '999px'
      ..style.backgroundColor = 'rgba(248, 250, 252, 0.92)'
      ..style.boxShadow = '0 0 12px rgba(248,250,252,0.55)'
      ..style.pointerEvents = 'none'
      ..style.opacity = '0';
    _tooltip = html.DivElement()
      ..setAttribute('data-vb-role', 'timeline-tooltip')
      ..style.position = 'absolute'
      ..style.left = '0%'
      ..style.bottom = '50px'
      ..style.transform = 'translateX(-50%)'
      ..style.padding = '6px 9px'
      ..style.borderRadius = '10px'
      ..style.backgroundColor = 'rgba(15, 23, 42, 0.94)'
      ..style.color = '#F8FAFC'
      ..style.font = '600 12px system-ui, -apple-system, Segoe UI, sans-serif'
      ..style.whiteSpace = 'nowrap'
      ..style.boxShadow = '0 12px 28px rgba(0,0,0,0.42), 0 0 0 1px rgba(148,163,184,0.28)'
      ..style.pointerEvents = 'none'
      ..style.opacity = '0';
    _timeline.children.addAll([_progress, _markers, _hoverLine]);
    _videoWrap.children.addAll([_video, _canvas]);
    _root.children.addAll([_videoWrap, _timeline, _tooltip]);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) => _root);
    _listenToVideo();
    widget.controller._attach(this);
    _updateAgentAttributes();
  }

  @override
  void didUpdateWidget(covariant WebVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    _playbackTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
    super.dispose();
  }

  void _listenToVideo() {
    _subscriptions.addAll([
      _video.onLoadedMetadata.listen((_) {
        _syncController();
        _renderTimelineMarkers();
        _drawOverlay();
      }),
      _video.onTimeUpdate.listen((_) {
        _syncController();
        _drawOverlay();
      }),
      _video.onSeeked.listen((_) {
        _syncController();
        _drawOverlay();
      }),
      _video.onPlay.listen((_) {
        _startPlaybackTimer();
        _syncController();
      }),
      _video.onPause.listen((_) {
        _playbackTimer?.cancel();
        _syncController();
        _drawOverlay();
      }),
      _video.onEnded.listen((_) {
        _playbackTimer?.cancel();
        _syncController();
        _drawOverlay();
      }),
      _timeline.onMouseDown.listen(_seekFromTimelineEvent),
      _timeline.onClick.listen(_seekFromTimelineEvent),
      _timeline.onMouseMove.listen((event) {
        _showTimelineTooltip(event as html.MouseEvent);
      }),
      _timeline.onMouseLeave.listen((_) {
        _hideTimelineTooltip();
      }),
    ]);
  }

  void _load(String url) {
    _playbackTimer?.cancel();
    _video
      ..pause()
      ..src = url
      ..currentTime = 0;
    _video.load();
    _clearCanvas();
    _syncController();
    _renderTimelineMarkers();
    _updateAgentAttributes();
  }

  void _setPointsOfInterest(List<VideoPointOfInterest> pointsOfInterest) {
    _pointsOfInterest = pointsOfInterest;
    _renderTimelineMarkers();
    _drawOverlay();
    _updateAgentAttributes();
  }

  void _setAnnotations(List<BenchmarkAnnotation> annotations) {
    _annotations = annotations;
    _renderTimelineMarkers();
    _updateAgentAttributes();
  }

  void _setBoundingBoxesVisible(bool visible) {
    _showBoundingBoxes = visible;
    _drawOverlay();
    _updateAgentAttributes();
  }

  void _setPlaybackRate(double rate) {
    _video.playbackRate = rate;
    _updateAgentAttributes();
  }

  Future<void> _play() async {
    if (_video.src.isEmpty) {
      return;
    }
    await _video.play();
  }

  void _pause() {
    _video.pause();
  }

  void _seekTo(Duration position) {
    if (_video.src.isEmpty) {
      return;
    }
    final targetSeconds = position.inMilliseconds / Duration.millisecondsPerSecond;
    _video.currentTime = targetSeconds.clamp(0, _safeDurationSeconds()).toDouble();
    _syncController();
    _drawOverlay();
  }

  String? _captureCurrentFrameDataUrl() {
    if (_video.src.isEmpty || _video.videoWidth <= 0 || _video.videoHeight <= 0) {
      return null;
    }
    final canvas = html.CanvasElement(
      width: _video.videoWidth,
      height: _video.videoHeight,
    );
    canvas.context2D.drawImageScaled(
      _video,
      0,
      0,
      _video.videoWidth.toDouble(),
      _video.videoHeight.toDouble(),
    );
    return canvas.toDataUrl('image/jpeg', 0.86);
  }

  void _setInteractionBlocked(bool blocked) {
    _root.style.pointerEvents = blocked ? 'none' : 'auto';
  }

  void _startPlaybackTimer() {
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _syncController();
      _drawOverlay();
    });
  }

  void _syncController() {
    widget.controller._sync(
      duration: _durationFromSeconds(_video.duration.toDouble()),
      position: _durationFromSeconds(_video.currentTime.toDouble()),
      isPlaying: !_video.paused,
    );
    _updateTimeline();
    _updateAgentAttributes();
  }

  void _updateAgentAttributes() {
    final duration = _durationFromSeconds(_video.duration.toDouble());
    final position = _durationFromSeconds(_video.currentTime.toDouble());
    final hasVideo = _video.src.isNotEmpty;
    _root
      ..setAttribute('data-has-video', hasVideo.toString())
      ..setAttribute('data-current-time-ms', position.inMilliseconds.toString())
      ..setAttribute('data-duration-ms', duration.inMilliseconds.toString())
      ..setAttribute('data-is-playing', (!_video.paused).toString())
      ..setAttribute('data-playback-rate', _video.playbackRate.toString())
      ..setAttribute('data-bounding-boxes-visible', _showBoundingBoxes.toString())
      ..setAttribute('data-poi-count', _pointsOfInterest.length.toString())
      ..setAttribute('data-annotation-count', _annotations.length.toString());
    _video
      ..setAttribute('data-has-video', hasVideo.toString())
      ..setAttribute('data-current-time-ms', position.inMilliseconds.toString())
      ..setAttribute('data-duration-ms', duration.inMilliseconds.toString())
      ..setAttribute('data-is-playing', (!_video.paused).toString())
      ..setAttribute('data-playback-rate', _video.playbackRate.toString());
  }

  void _updateTimeline() {
    final duration = _safeDurationSeconds();
    final ratio = duration == double.maxFinite || duration <= 0
        ? 0.0
        : (_video.currentTime.toDouble() / duration).clamp(0.0, 1.0);
    final percent = '${(ratio * 100).toStringAsFixed(4)}%';
    _progress.style.width = percent;
  }

  void _seekFromTimelineEvent(html.MouseEvent event) {
    final duration = _safeDurationSeconds();
    if (duration == double.maxFinite || duration <= 0) {
      return;
    }
    final rect = _timeline.getBoundingClientRect();
    final ratio = ((event.client.x - rect.left) / rect.width).clamp(0.0, 1.0);
    _video.currentTime = ratio * duration;
    _syncController();
    _drawOverlay();
  }

  void _renderTimelineMarkers() {
    _markers.children.clear();
    final duration = _safeDurationSeconds();
    if (duration == double.maxFinite || duration <= 0) {
      return;
    }

    for (final point in _pointsOfInterest) {
      final ratio = (point.timestamp.inMilliseconds / Duration.millisecondsPerSecond / duration).clamp(0.0, 1.0);
      final marker = html.DivElement()
        ..title = '${point.objectType} #${point.objectId} ${formatVideoTimestamp(point.timestamp)}'
        ..setAttribute('data-vb-role', 'poi-marker')
        ..setAttribute('data-object-type', point.objectType)
        ..setAttribute('data-object-id', point.objectId.toString())
        ..setAttribute('data-timestamp-ms', point.timestamp.inMilliseconds.toString())
        ..setAttribute('aria-label', '${point.objectType} #${point.objectId} at ${formatVideoTimestamp(point.timestamp)}')
        ..style.position = 'absolute'
        ..style.left = '${(ratio * 100).toStringAsFixed(4)}%'
        ..style.top = '50%'
        ..style.width = '4px'
        ..style.height = '20px'
        ..style.marginLeft = '-2px'
        ..style.marginTop = '-10px'
        ..style.transform = 'scaleY(1)'
        ..style.transition = 'transform 120ms ease, box-shadow 120ms ease, filter 120ms ease'
        ..style.borderRadius = '999px'
        ..style.backgroundColor = _colorForObjectType(point.objectType)
        ..style.boxShadow = '0 0 0 1px rgba(15,23,42,0.92), 0 4px 12px rgba(0,0,0,0.36)'
        ..style.pointerEvents = 'auto';
      marker.onClick.listen((event) {
        event.stopPropagation();
        _seekTo(point.timestamp);
      });
      marker.onMouseEnter.listen((event) {
        marker.style
          ..transform = 'scaleY(1)'
          ..filter = 'brightness(1.12)'
          ..boxShadow = '0 0 0 2px rgba(248,250,252,0.95), 0 8px 20px rgba(0,0,0,0.45)';
        _showMarkerTooltip(event as html.MouseEvent, point);
      });
      marker.onMouseMove.listen((event) {
        _showMarkerTooltip(event as html.MouseEvent, point);
      });
      marker.onMouseLeave.listen((_) {
        marker.style
          ..transform = 'scaleY(1)'
          ..filter = 'brightness(1)'
          ..boxShadow = '0 0 0 1px rgba(15,23,42,0.92), 0 4px 12px rgba(0,0,0,0.36)';
      });
      _markers.children.add(marker);
    }

    for (final annotation in _annotations) {
      final ratio = (annotation.timestamp.inMilliseconds / Duration.millisecondsPerSecond / duration).clamp(0.0, 1.0);
      final marker = html.DivElement()
        ..title = '${annotation.id} ${formatVideoTimestamp(annotation.timestamp)}'
        ..text = '★'
        ..setAttribute('data-vb-role', 'annotation-marker')
        ..setAttribute('data-annotation-id', annotation.id)
        ..setAttribute('data-family', annotation.family)
        ..setAttribute('data-timestamp-ms', annotation.timestamp.inMilliseconds.toString())
        ..setAttribute('aria-label', 'Annotation ${annotation.id} at ${formatVideoTimestamp(annotation.timestamp)}')
        ..style.position = 'absolute'
        ..style.left = '${(ratio * 100).toStringAsFixed(4)}%'
        ..style.top = '50%'
        ..style.width = '18px'
        ..style.height = '18px'
        ..style.marginLeft = '-9px'
        ..style.marginTop = '-9px'
        ..style.color = '#FACC15'
        ..style.font = '700 16px system-ui, -apple-system, Segoe UI, sans-serif'
        ..style.lineHeight = '18px'
        ..style.textAlign = 'center'
        ..style.textShadow = '0 1px 2px rgba(15,23,42,1), 0 0 8px rgba(250,204,21,0.7)'
        ..style.transition = 'transform 120ms ease, filter 120ms ease'
        ..style.pointerEvents = 'auto';
      marker.onClick.listen((event) {
        event.stopPropagation();
        _seekTo(annotation.timestamp);
      });
      marker.onMouseEnter.listen((event) {
        marker.style
          ..transform = 'scale(1.22)'
          ..filter = 'brightness(1.1)';
        _showAnnotationTooltip(event as html.MouseEvent, annotation);
      });
      marker.onMouseMove.listen((event) {
        _showAnnotationTooltip(event as html.MouseEvent, annotation);
      });
      marker.onMouseLeave.listen((_) {
        marker.style
          ..transform = 'scale(1)'
          ..filter = 'brightness(1)';
      });
      _markers.children.add(marker);
    }
  }

  void _showTimelineTooltip(html.MouseEvent event) {
    final duration = _safeDurationSeconds();
    if (duration == double.maxFinite || duration <= 0) {
      return;
    }
    final rect = _timeline.getBoundingClientRect();
    final ratio = ((event.client.x - rect.left) / rect.width).clamp(0.0, 1.0);
    final timestamp = Duration(milliseconds: (duration * Duration.millisecondsPerSecond * ratio).round());
    _showTooltipAtRatio(ratio, formatVideoTimestamp(timestamp));
  }

  void _showMarkerTooltip(html.MouseEvent event, VideoPointOfInterest point) {
    final rect = _timeline.getBoundingClientRect();
    final ratio = ((event.client.x - rect.left) / rect.width).clamp(0.0, 1.0);
    _showTooltipAtRatio(
      ratio,
      '${point.objectType} #${point.objectId} - ${formatVideoTimestamp(point.timestamp)}',
    );
  }

  void _showAnnotationTooltip(html.MouseEvent event, BenchmarkAnnotation annotation) {
    final rect = _timeline.getBoundingClientRect();
    final ratio = ((event.client.x - rect.left) / rect.width).clamp(0.0, 1.0);
    final label = annotation.question.isEmpty ? annotation.id : annotation.question;
    _showTooltipAtRatio(
      ratio,
      '★ $label - ${formatVideoTimestamp(annotation.timestamp)}',
    );
  }

  void _showTooltipAtRatio(double ratio, String text) {
    final percent = '${(ratio * 100).toStringAsFixed(4)}%';
    final left = 24 + (_timeline.clientWidth * ratio);
    _tooltip
      ..text = text
      ..style.left = '${left.toStringAsFixed(2)}px'
      ..style.opacity = '1';
    _hoverLine.style
      ..left = percent
      ..opacity = '1';
  }

  void _hideTimelineTooltip() {
    _tooltip.style.opacity = '0';
    _hoverLine.style.opacity = '0';
  }

  Duration _durationFromSeconds(double value) {
    if (value.isNaN || value.isInfinite || value < 0) {
      return Duration.zero;
    }
    return Duration(milliseconds: (value * Duration.millisecondsPerSecond).round());
  }

  double _safeDurationSeconds() {
    final duration = _video.duration;
    if (duration.isNaN || duration.isInfinite || duration <= 0) {
      return double.maxFinite;
    }
    return duration.toDouble();
  }

  void _clearCanvas() {
    final width = math.max(1, _videoWrap.clientWidth);
    final height = math.max(1, _videoWrap.clientHeight);
    final dpr = html.window.devicePixelRatio;
    _canvas
      ..width = (width * dpr).round()
      ..height = (height * dpr).round();
    final context = _canvas.context2D;
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    context.clearRect(0, 0, width, height);
  }

  void _drawOverlay() {
    final containerWidth = math.max(1, _videoWrap.clientWidth).toDouble();
    final containerHeight = math.max(1, _videoWrap.clientHeight).toDouble();
    final dpr = html.window.devicePixelRatio;

    final targetWidth = (containerWidth * dpr).round();
    final targetHeight = (containerHeight * dpr).round();
    if (_canvas.width != targetWidth || _canvas.height != targetHeight) {
      _canvas
        ..width = targetWidth
        ..height = targetHeight;
    }

    final context = _canvas.context2D;
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    context.clearRect(0, 0, containerWidth, containerHeight);

    final videoWidth = _video.videoWidth.toDouble();
    final videoHeight = _video.videoHeight.toDouble();
    if (!_showBoundingBoxes || videoWidth <= 0 || videoHeight <= 0 || _pointsOfInterest.isEmpty) {
      return;
    }

    final videoRect = _containedVideoRect(
      containerWidth: containerWidth,
      containerHeight: containerHeight,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
    );
    final currentPosition = _durationFromSeconds(_video.currentTime.toDouble());
    const frameTolerance = Duration(milliseconds: 24);

    for (final point in _pointsOfInterest) {
      if ((point.timestamp - currentPosition).abs() > frameTolerance) {
        continue;
      }
      _drawBoundingBox(context, videoRect, videoWidth, videoHeight, point);
    }
  }

  _VideoRect _containedVideoRect({
    required double containerWidth,
    required double containerHeight,
    required double videoWidth,
    required double videoHeight,
  }) {
    final videoAspect = videoWidth / videoHeight;
    final containerAspect = containerWidth / containerHeight;

    if (containerAspect > videoAspect) {
      final height = containerHeight;
      final width = height * videoAspect;
      return _VideoRect(
        left: (containerWidth - width) / 2,
        top: 0,
        width: width,
        height: height,
      );
    }

    final width = containerWidth;
    final height = width / videoAspect;
    return _VideoRect(
      left: 0,
      top: (containerHeight - height) / 2,
      width: width,
      height: height,
    );
  }

  void _drawBoundingBox(
    html.CanvasRenderingContext2D context,
    _VideoRect videoRect,
    double sourceWidth,
    double sourceHeight,
    VideoPointOfInterest point,
  ) {
    final box = point.boundingBox;
    final left = videoRect.left + box.x1 / sourceWidth * videoRect.width;
    final top = videoRect.top + box.y1 / sourceHeight * videoRect.height;
    final width = box.width / sourceWidth * videoRect.width;
    final height = box.height / sourceHeight * videoRect.height;

    context
      ..lineWidth = 3
      ..strokeStyle = _colorForObjectType(point.objectType)
      ..fillStyle = 'rgba(15, 23, 42, 0.72)';
    context.strokeRect(left, top, width, height);

    final label = '${point.objectType} #${point.objectId} ${(point.confidence * 100).round()}%';
    context.font = '600 13px system-ui, -apple-system, Segoe UI, sans-serif';
    final labelWidth = (context.measureText(label).width ?? 0).toDouble() + 14;
    final labelTop = math.max(4, top - 27);
    context.fillRect(left, labelTop, labelWidth, 23);
    context
      ..fillStyle = '#F8FAFC'
      ..fillText(label, left + 7, labelTop + 16);
  }

  String _colorForObjectType(String type) {
    switch (type.toLowerCase()) {
      case 'car':
        return '#60A5FA';
      case 'truck':
        return '#F59E0B';
      case 'plane':
        return '#A78BFA';
      case 'person':
        return '#F472B6';
      default:
        return '#6EE7B7';
    }
  }
}

class _VideoRect {
  const _VideoRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

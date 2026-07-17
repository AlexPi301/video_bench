import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';

import '../models/annotation_dataset.dart';
import '../models/impact_cycle_models.dart';
import '../models/video_report.dart';
import '../services/annotation_json_parser.dart';
import '../services/devtools_agent_bridge.dart';
import '../services/impact_cycle_client.dart';
import '../services/mounted_files_client.dart';
import '../services/report_csv_parser.dart';
import 'drop_zone_panel.dart';
import 'timeline_bar.dart';
import 'web_video_surface.dart';

const _experimentalEnabled = bool.fromEnvironment('VIDEO_BENCH_EXPERIMENTAL');

class VideoBenchPage extends StatefulWidget {
  const VideoBenchPage({super.key});

  @override
  State<VideoBenchPage> createState() => _VideoBenchPageState();
}

class _VideoBenchPageState extends State<VideoBenchPage> {
  final _videoController = VideoSurfaceController();
  final _parser = const ReportCsvParser();
  final _annotationParser = const AnnotationJsonParser();
  final _mountedFilesClient = const MountedFilesClient();
  final _impactCycleClient = const ImpactCycleClient();
  StreamSubscription<html.KeyboardEvent>? _keyboardSubscription;
  Timer? _statusTimer;

  DropzoneViewController? _videoUrlOwner;
  String? _videoObjectUrl;
  String? _videoFilename;
  String? _csvFilename;
  String? _annotationFilename;
  VideoReport? _report;
  AnnotationDataset? _annotationDataset;
  List<ImpactCycleJob> _jobs = const [];
  List<ImpactCycleActivity> _activities = const [];
  String? _errorMessage;
  String _statusMessage = 'Drop a video file to begin.';
  String _mountedVideoPath = '';
  String _metadataDirectory = '';
  String _reportCsvPath = '';
  String _qaPairsPath = '';
  String _captionsPath = '';
  bool? _reportCsvFound;
  bool? _qaPairsFound;
  bool? _captionsFound;
  final Set<String> _hiddenCategoryKeys = {};
  final Set<String> _hiddenAnnotationTypeKeys = {};
  var _annotationDialogOpen = false;

  List<VideoPointOfInterest> get _pointsOfInterest =>
      _report?.pointsOfInterest ?? const [];

  List<BenchmarkAnnotation> get _annotations =>
      _annotationDataset?.qaPairs ?? const [];

  List<VideoPointOfInterest> get _filteredPointsOfInterest => [
        for (final poi in _pointsOfInterest)
          if (!_hiddenCategoryKeys.contains(_poiCategoryKey(poi.objectType))) poi,
      ];

  List<BenchmarkAnnotation> get _filteredAnnotations => [
        for (final annotation in _annotations)
          if (!_hiddenAnnotationTypeKeys.contains(_annotationTypeKey(annotation.family)))
            annotation,
      ];

  List<Duration> get _filteredTimelineTimestamps => [
        for (final poi in _filteredPointsOfInterest) poi.timestamp,
        for (final annotation in _filteredAnnotations) annotation.timestamp,
      ]..sort((a, b) => a.compareTo(b));

  @override
  void initState() {
    super.initState();
    _registerAgentHooks();
    _videoController.addListener(_handleControllerUpdate);
    _keyboardSubscription = html.window.onKeyDown.listen(_handleBrowserKeyDown);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDebugSessionIfEnabled();
      _refreshStatusPanels();
    });
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStatusPanels());
  }

  @override
  void dispose() {
    DevtoolsAgentBridge.instance.unregisterOwner(this);
    _videoController.removeListener(_handleControllerUpdate);
    _keyboardSubscription?.cancel();
    _statusTimer?.cancel();
    _releaseVideoUrl();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1440),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(
                    statusMessage: _statusMessage,
                    failedActivityCount: _activities.where((activity) => activity.isFailure).length,
                    runningJobCount: _jobs.where((job) => job.isRunning).length,
                    onShowActivities: _showActivities,
                    onShowJobs: _showJobs,
                  ),
                  const SizedBox(height: 22),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: _buildPlayerCard(context)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 22),
                        SizedBox(
                          width: 360,
                          child: _buildSidePanel(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerCard(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF020617),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      WebVideoSurface(controller: _videoController),
                      if (!_videoController.hasVideo) const _EmptyVideoState(),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _PlaybackControls(
              hasVideo: _videoController.hasVideo,
              isPlaying: _videoController.isPlaying,
              position: _videoController.position,
              duration: _videoController.duration,
              playbackRate: _videoController.playbackRate,
              onTogglePlayback: () {
                if (_videoController.isPlaying) {
                  _videoController.pause();
                } else {
                  _videoController.play();
                }
              },
              onSkipBackward: () => _seekRelative(const Duration(seconds: -10)),
              onSkipForward: () => _seekRelative(const Duration(seconds: 10)),
              onPlaybackRateChanged: _videoController.setPlaybackRate,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Semantics(
                    identifier: 'video-bench.add-annotation',
                    button: true,
                    enabled: _videoController.hasVideo,
                    label: 'Add annotation',
                    child: FilledButton.tonalIcon(
                      onPressed: _videoController.hasVideo ? _openAnnotationDialog : null,
                      icon: const Icon(Icons.add),
                      label: const Text('Add annotation'),
                    ),
                  ),
                  Semantics(
                    identifier: 'video-bench.last-poi',
                    button: true,
                    enabled: _videoController.hasVideo,
                    label: 'last POI',
                    child: FilledButton.tonalIcon(
                      onPressed: _videoController.hasVideo ? _seekToLastPoi : null,
                      icon: const Icon(Icons.skip_previous),
                      label: const Text('last POI'),
                    ),
                  ),
                  Semantics(
                    identifier: 'video-bench.next-poi',
                    button: true,
                    enabled: _videoController.hasVideo,
                    label: 'next POI',
                    child: FilledButton.tonalIcon(
                      onPressed: _videoController.hasVideo ? _seekToNextPoi : null,
                      icon: const Icon(Icons.skip_next),
                      label: const Text('next POI'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidePanel(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Session', style: Theme.of(context).textTheme.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _InfoRow(
                label: 'Video',
                value: _videoFilename ?? 'No video loaded',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'CSV report',
                value: _csvFilename ?? 'Optional, not loaded',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Annotation JSON',
                value: _annotationFilename ?? 'Optional, not loaded',
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Points of interest',
                value: _pointsOfInterest.length.toString(),
              ),
              const SizedBox(height: 12),
              _InfoRow(
                label: 'Annotations',
                value: _annotations.length.toString(),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: Semantics(
                  identifier: 'video-bench.open-mounted-video',
                  button: true,
                  label: 'Browse Video file',
                  child: FilledButton.tonalIcon(
                    onPressed: _openMountedVideoDialog,
                    icon: const Icon(Icons.video_library),
                    label: const Text('Browse Video file'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildQaPairsPanel(context),
              if (_errorMessage != null) ...[
                const SizedBox(height: 22),
                _ErrorPanel(message: _errorMessage!),
              ],
              const SizedBox(height: 22),
              Text('Categories', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              _CategoryFilter(
                categories: _categoryOptions(),
                hiddenKeys: _hiddenCategoryKeys,
                onChanged: _setCategoryVisible,
              ),
              const SizedBox(height: 22),
              Text('Annotation Types', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              _CategoryFilter(
                categories: _annotationTypeOptions(),
                emptyMessage: 'Load an annotation JSON to filter annotation types.',
                hiddenKeys: _hiddenAnnotationTypeKeys,
                onChanged: _setAnnotationTypeVisible,
              ),
              const SizedBox(height: 22),
              Text('Recent POIs', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              SizedBox(
                height: 320,
                child: _PoiList(
                  pointsOfInterest: _filteredPointsOfInterest,
                  annotations: _filteredAnnotations,
                  onPointSelected: _videoController.seekTo,
                  onAnnotationSelected: _openExistingAnnotationDialog,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQaPairsPanel(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('QA workflow', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_metadataDirectory.isEmpty)
          Text(
            'Select a mounted video to use its sibling *_meta directory.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
          )
        else
          const SizedBox.shrink(),
        if (_metadataDirectory.isNotEmpty) const SizedBox(height: 10),
        _QaWorkflowRow(
          filename: 'report.csv',
          exists: _reportCsvFound == true,
          checking: _reportCsvFound == null && _metadataDirectory.isNotEmpty,
          onBrowsePressed: _openMountedReportCsvDialog,
        ),
        const SizedBox(height: 8),
        _QaWorkflowRow(
          filename: 'qa_pairs.json',
          exists: _qaPairsFound == true,
          checking: _qaPairsFound == null && _metadataDirectory.isNotEmpty,
          generateButtonLabel: 'generate qa pairs',
          onGeneratePressed: _experimentalEnabled ? _openGenerateQaPairsDialog : null,
          onBrowsePressed: _openMountedAnnotationJsonDialog,
        ),
        const SizedBox(height: 8),
        _QaWorkflowRow(
          filename: 'captions.json',
          exists: _captionsFound == true,
          checking: _captionsFound == null && _metadataDirectory.isNotEmpty,
          generateButtonLabel: 'generate captions',
          onGeneratePressed: _openGenerateCaptionsDialog,
          onBrowsePressed: _openMountedCaptionsDialog,
        ),
      ],
    );
  }

  Future<void> _handleFilesSelected(
    DropzoneViewController controller,
    List<dynamic> files,
  ) async {
    setState(() {
      _errorMessage = null;
      _statusMessage = 'Reading dropped files...';
    });

    try {
      final candidates = <_DroppedFile>[];
      for (final file in files) {
        candidates.add(await _DroppedFile.fromDropzone(controller, file));
      }

      final video = _firstWhereOrNull(candidates, (file) => file.isVideo);
      final csv = _firstWhereOrNull(candidates, (file) => file.isCsv);

      if (video == null && csv == null) {
        setState(() {
          _errorMessage = 'No supported video or CSV file was provided.';
          _statusMessage = 'Drop a video file to begin.';
        });
        return;
      }

      if (video != null) {
        final url = await controller.createFileUrl(video.rawFile);
        _loadVideoUrl(url: url, filename: video.name, owner: controller);
      }

      if (csv != null) {
        final bytes = await controller.getFileData(csv.rawFile);
        final text = utf8.decode(bytes);
        _loadCsvText(csvText: text, filename: csv.name);
      }

      setState(() {
        if (_report == null) {
          _statusMessage = 'Video loaded. Add a CSV report to show POIs.';
        } else {
          _statusMessage =
              'Loaded ${_pointsOfInterest.length} points of interest from $_csvFilename.';
        }
      });
    } on ReportCsvFormatException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _statusMessage = 'CSV report could not be parsed.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Could not load files: $error';
        _statusMessage = 'File loading failed.';
      });
    }
  }

  Future<void> _openUploadDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _UploadDialog(
        hasVideo: _videoController.hasVideo,
        annotationFilename: _annotationFilename,
        onFilesSelected: _handleFilesSelected,
        onAnnotationFileSelected: _handleAnnotationFileSelected,
      ),
    );
  }

  Future<void> _handleAnnotationFileSelected(
    DropzoneViewController controller,
    dynamic file,
  ) async {
    setState(() {
      _errorMessage = null;
      _statusMessage = 'Reading annotation JSON...';
    });

    try {
      final droppedFile = await _DroppedFile.fromDropzone(controller, file);
      if (!droppedFile.isJson) {
        setState(() {
          _errorMessage = 'Annotation upload expects a JSON file.';
          _statusMessage = 'Annotation JSON could not be loaded.';
        });
        return;
      }

      final bytes = await controller.getFileData(droppedFile.rawFile);
      _loadAnnotationJsonText(text: utf8.decode(bytes), filename: droppedFile.name);
    } on AnnotationJsonFormatException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _statusMessage = 'Annotation JSON could not be parsed.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Could not load annotation JSON: $error';
        _statusMessage = 'Annotation JSON loading failed.';
      });
    }
  }

  Future<void> _openMountedReportCsvDialog() async {
    final selection = await showDialog<MountedFileEntry>(
      context: context,
      builder: (context) => _MountedMetadataFileDialog(
        client: _mountedFilesClient,
        kind: 'csv',
        title: 'Select CSV report',
        description: 'Choose a CSV report from the mounted input volume to load for this video.',
        emptyMessage: 'No CSV files in this directory.',
        fileIcon: Icons.table_chart,
      ),
    );
    if (selection == null) {
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = 'Loading mounted CSV report...';
    });

    try {
      await _loadMountedCsv(selection);
    } on ReportCsvFormatException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _statusMessage = 'Mounted CSV report could not be parsed.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Could not load mounted CSV report: $error';
        _statusMessage = 'Mounted CSV report loading failed.';
      });
    }
  }

  Future<void> _openMountedAnnotationJsonDialog() async {
    final selection = await showDialog<MountedFileEntry>(
      context: context,
      builder: (context) => _MountedMetadataFileDialog(
        client: _mountedFilesClient,
        kind: 'json',
        title: 'Select annotation JSON',
        description: 'Choose a JSON file from the mounted input volume to load as Video Bench annotations.',
        emptyMessage: 'No JSON files in this directory.',
        fileIcon: Icons.data_object,
      ),
    );
    if (selection == null) {
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = 'Loading mounted annotation JSON...';
    });

    try {
      final url = selection.url ?? Uri(path: '/api/mounted-files/file/', queryParameters: {'path': selection.path}).toString();
      final text = await html.HttpRequest.getString(url);
      _loadAnnotationJsonText(text: text, filename: selection.path);
    } on AnnotationJsonFormatException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _statusMessage = 'Mounted annotation JSON could not be parsed.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Could not load mounted annotation JSON: $error';
        _statusMessage = 'Mounted annotation JSON loading failed.';
      });
    }
  }

  Future<void> _openMountedCaptionsDialog() async {
    final selection = await showDialog<MountedFileEntry>(
      context: context,
      builder: (context) => _MountedMetadataFileDialog(
        client: _mountedFilesClient,
        kind: 'json',
        title: 'Select captions JSON',
        description: 'Choose a captions.json file from the mounted input volume.',
        emptyMessage: 'No JSON files in this directory.',
        fileIcon: Icons.closed_caption,
      ),
    );
    if (selection == null) {
      return;
    }
    setState(() {
      _captionsFound = true;
      _statusMessage = 'Selected captions file: ${selection.path}';
    });
  }

  Future<void> _openGenerateCaptionsDialog() async {
    final result = await showDialog<_CaptionGenerationParams>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _GenerateCaptionsDialog(
        defaultOutputDirectory: _metadataDirectory,
        videoFilename: _videoFilename ?? '',
      ),
    );
    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = 'Creating caption generation job...';
    });

    try {
      final request = await html.HttpRequest.request(
        '/api/impact-cycle/jobs/',
        method: 'POST',
        requestHeaders: {'Content-Type': 'application/json'},
        sendData: jsonEncode({
          'operation': 'caption_generate',
          'inputs': {
            'videoPath': _mountedVideoPath,
          },
          'settings': {
            'lmStudioUrl': result.lmStudioUrl,
            'model': result.model,
            'fpsSampling': result.fpsSampling,
            'captionPrompt': result.captionPrompt,
            'outputDirectory': _metadataDirectory,
            'directOutput': true,
          },
        }),
      );
      final json = jsonDecode(request.responseText ?? '{}') as Map<String, dynamic>;
      final jobId = json['id']?.toString() ?? '';
      if (jobId.isNotEmpty) {
        await _refreshStatusPanels();
      }
      if (mounted) {
        setState(() {
          _statusMessage = 'Caption generation job created: $jobId';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not create caption generation job: $error';
          _statusMessage = 'Caption generation job creation failed.';
        });
      }
    }
  }

  Future<void> _openGenerateQaPairsDialog() async {
    final result = await showDialog<_QaPairsGenerationParams>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _GenerateQaPairsDialog(
        client: _mountedFilesClient,
        defaultOutputDirectory: _metadataDirectory,
        videoFilename: _videoFilename ?? '',
        initialVideoPath: _mountedVideoPath,
      ),
    );
    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = 'Creating QA-pair generation jobs...';
    });

    try {
      final jobIds = <String>[];
      for (final videoPath in result.videoPaths) {
        final outputDirectory = _metadataDirectoryForVideoPath(videoPath);
        final request = await html.HttpRequest.request(
          '/api/impact-cycle/jobs/',
          method: 'POST',
          requestHeaders: {'Content-Type': 'application/json'},
          sendData: jsonEncode({
            'operation': 'qa_pairs_generate',
            'inputs': {
              'videoPath': videoPath,
            },
            'settings': {
              'lmStudioUrl': result.lmStudioUrl,
              'model': result.model,
              'fpsSampling': result.fpsSampling,
              'windowSizeSeconds': result.windowSizeSeconds,
              'qaPairsPerWindow': result.qaPairsPerWindow,
              'qaGenerationPrompt': result.qaGenerationPrompt,
              'outputDirectory': outputDirectory,
              'directOutput': true,
            },
          }),
        );
        final json = jsonDecode(request.responseText ?? '{}') as Map<String, dynamic>;
        final jobId = json['id']?.toString() ?? '';
        if (jobId.isNotEmpty) {
          jobIds.add(jobId);
        }
      }
      await _refreshStatusPanels();
      if (mounted) {
        setState(() {
          _statusMessage = 'Created ${jobIds.length} QA-pair generation job(s).';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not create QA-pair generation jobs: $error';
          _statusMessage = 'QA-pair generation job creation failed.';
        });
      }
    }
  }

  String _metadataDirectoryForVideoPath(String videoPath) {
    final parts = videoPath.split('/');
    final filename = parts.isEmpty ? videoPath : parts.last;
    final dotIndex = filename.lastIndexOf('.');
    final stem = dotIndex <= 0 ? filename : filename.substring(0, dotIndex);
    final metaName = '${stem}_meta';
    if (parts.length <= 1) {
      return metaName;
    }
    return [...parts.sublist(0, parts.length - 1), metaName].join('/');
  }

  Future<void> _loadMountedCsv(MountedFileEntry entry) async {
    final url = entry.url ?? Uri(path: '/api/mounted-files/file/', queryParameters: {'path': entry.path}).toString();
    final text = await html.HttpRequest.getString(url);
    _loadCsvText(csvText: text, filename: entry.path);
    if (mounted) {
      setState(() {
        _reportCsvFound = true;
        _statusMessage = 'Loaded ${_pointsOfInterest.length} points of interest from ${entry.path}.';
      });
    }
  }

  void _loadAnnotationJsonText({required String text, required String filename}) {
    final dataset = _annotationParser.parse(text);
    setState(() {
      _annotationDataset = dataset;
      _annotationFilename = filename;
      _qaPairsFound = true;
      _syncFilteredTimelineData();
      _statusMessage = 'Loaded ${dataset.qaPairs.length} annotations from $filename.';
    });
  }

  Future<void> _loadDebugSessionIfEnabled() async {
    try {
      final configText = await html.HttpRequest.getString('/debug-config.json');
      final config = jsonDecode(configText) as Map<String, dynamic>;
      if (config['enabled'] != true) {
        return;
      }

      final videoUrl = config['videoUrl']?.toString();
      final csvUrl = config['csvUrl']?.toString();
      if (videoUrl == null || csvUrl == null) {
        throw const FormatException('Debug config is missing videoUrl or csvUrl.');
      }

      setState(() {
        _errorMessage = null;
        _statusMessage = 'Loading debug session...';
      });

      _loadVideoUrl(
        url: videoUrl,
        filename: config['videoFilename']?.toString() ?? videoUrl.split('/').last,
        mountedVideoPath: config['impactSourcePath']?.toString() ?? '',
      );
      final csvText = await html.HttpRequest.getString(csvUrl);
      _loadCsvText(
        csvText: csvText,
        filename: config['csvFilename']?.toString() ?? csvUrl.split('/').last,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage =
            'Debug session loaded: $_videoFilename with ${_pointsOfInterest.length} points of interest.';
      });
    } on html.ProgressEvent {
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not load debug session: $error';
        _statusMessage = 'Debug session failed to load.';
      });
    }
  }

  Future<void> _openMountedVideoDialog() async {
    final selection = await showDialog<MountedFileEntry>(
      context: context,
      builder: (context) => _MountedMetadataFileDialog(
        client: _mountedFilesClient,
        kind: 'video',
        title: 'Select mounted video file',
        description: 'Choose a video file from the mounted input volume.',
        emptyMessage: 'No video files in this directory.',
        fileIcon: Icons.video_library,
      ),
    );
    if (selection == null) {
      return;
    }

    final videoUrl = selection.url;
    if (videoUrl == null) {
      setState(() {
        _errorMessage = 'Selected mounted video does not include a loadable URL.';
        _statusMessage = 'Mounted file loading failed.';
      });
      return;
    }

    setState(() {
      _errorMessage = null;
      _statusMessage = 'Loading mounted files...';
    });

    try {
      _loadVideoUrl(
        url: videoUrl,
        filename: selection.path,
        mountedVideoPath: selection.path,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Mounted video loaded. Looking for QA workflow files.';
      });
    } on ReportCsvFormatException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _statusMessage = 'Mounted CSV report could not be parsed.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Could not load mounted files: $error';
        _statusMessage = 'Mounted file loading failed.';
      });
    }
  }

  void _loadVideoUrl({
    required String url,
    required String filename,
    DropzoneViewController? owner,
    String mountedVideoPath = '',
  }) {
    _releaseVideoUrl();
    _videoUrlOwner = owner;
    _videoObjectUrl = url;
    _videoFilename = filename;
    _csvFilename = null;
    _annotationFilename = null;
    _report = null;
    _annotationDataset = null;
    _setMountedVideoPath(mountedVideoPath);
    _hiddenCategoryKeys.clear();
    _hiddenAnnotationTypeKeys.clear();
    _syncFilteredTimelineData();
    _videoController.loadVideoUrl(url);
    _refreshQaPairsStatus();
  }

  void _loadCsvText({required String csvText, required String filename}) {
    final report = _parser.parse(csvText);
    _csvFilename = filename;
    _report = report;
    _syncFilteredTimelineData();
  }

  Future<void> _openAnnotationDialog() async {
    final wasPlaying = _videoController.isPlaying;
    if (wasPlaying) {
      _videoController.pause();
    }

    final timestamp = _videoController.position;
    if (!mounted) {
      return;
    }

    _annotationDialogOpen = true;
    _videoController.setInteractionBlocked(true);
    await showDialog<_AnnotationDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AnnotationDialog(
        timestamp: timestamp,
        videoUrl: _videoObjectUrl,
        videoId: _videoIdForAnnotation(),
        nextId: _nextAnnotationId(),
        duration: _videoController.duration,
        annotations: _annotations,
        onSave: _saveAnnotationFromDialog,
      ),
    ).whenComplete(() {
      _annotationDialogOpen = false;
      _videoController.setInteractionBlocked(false);
    });
  }

  Future<void> _openExistingAnnotationDialog(BenchmarkAnnotation annotation) async {
    _videoController.seekTo(annotation.timestamp);
    _videoController.pause();

    _annotationDialogOpen = true;
    _videoController.setInteractionBlocked(true);
    final result = await showDialog<_AnnotationDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AnnotationDialog(
        timestamp: annotation.timestamp,
        videoUrl: _videoObjectUrl,
        videoId: annotation.videoId,
        nextId: annotation.id,
        duration: _videoController.duration,
        annotations: _annotations,
        annotation: annotation,
        onSave: _saveAnnotationFromDialog,
      ),
    ).whenComplete(() {
      _annotationDialogOpen = false;
      _videoController.setInteractionBlocked(false);
    });

    if (result == null || !mounted) {
      return;
    }

    final currentDataset = _annotationDataset ?? _newAnnotationDataset();
    if (result.deleteId != null) {
      final dataset = currentDataset.delete(result.deleteId!);
      setState(() {
        _annotationDataset = dataset;
        _syncFilteredTimelineData();
        _statusMessage = 'Deleted annotation ${result.deleteId}.';
      });
      await _persistAnnotationDataset();
      return;
    }

  }

  Future<void> _saveAnnotationFromDialog(BenchmarkAnnotation annotation, String? previousId) async {
    final currentDataset = _annotationDataset ?? _newAnnotationDataset();
    final replaceId = previousId ?? annotation.id;
    final exists = currentDataset.qaPairs.any((pair) => pair.id == replaceId);
    final withoutPrevious = previousId != null && previousId != annotation.id
        ? currentDataset.delete(previousId)
        : currentDataset;
    final dataset = exists
        ? previousId != null && previousId != annotation.id
            ? withoutPrevious.add(annotation)
            : withoutPrevious.replace(annotation)
        : withoutPrevious.add(annotation);
    setState(() {
      _annotationDataset = dataset;
      _syncFilteredTimelineData();
      _statusMessage = exists
          ? 'Updated annotation ${annotation.id}.'
          : 'Added annotation ${annotation.id} at ${formatVideoTimestamp(annotation.timestamp)}.';
    });
    await _persistAnnotationDataset();
  }

  String? _annotationPersistPath() {
    final filename = _annotationFilename;
    if (filename != null && filename.contains('/')) {
      return filename;
    }
    if (_metadataDirectory.isNotEmpty) {
      return _qaPairsPath;
    }
    return null;
  }

  Future<void> _persistAnnotationDataset() async {
    final dataset = _annotationDataset;
    if (dataset == null) {
      return;
    }
    final targetPath = _annotationPersistPath();
    if (targetPath == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage =
            'Annotation saved in memory only. Load a mounted video to persist qa_pairs.json next to it.';
        _statusMessage = 'Annotation saved in memory only.';
      });
      return;
    }

    try {
      final serialized = _annotationParser.serialize(dataset);
      final saved = await _mountedFilesClient.saveJson(
        path: targetPath,
        content: serialized,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _annotationFilename = saved.path;
        _qaPairsFound = true;
        _errorMessage = null;
        _statusMessage =
            'Saved ${dataset.qaPairs.length} annotation(s) to ${saved.path}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Could not save annotation JSON to $targetPath: $error';
        _statusMessage = 'Annotation saved in memory only.';
      });
    }
  }

  List<_CategoryOption> _categoryOptions() {
    final objectCounts = <String, int>{};
    for (final poi in _pointsOfInterest) {
      objectCounts.update(poi.objectType, (value) => value + 1, ifAbsent: () => 1);
    }

    final objectEntries = objectCounts.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return [
      for (final entry in objectEntries)
        _CategoryOption(
          key: _poiCategoryKey(entry.key),
          label: entry.key,
          count: entry.value,
          type: _CategoryType.object,
        ),
    ];
  }

  List<_CategoryOption> _annotationTypeOptions() {
    final familyCounts = <String, int>{};
    for (final annotation in _annotations) {
      familyCounts.update(annotation.family, (value) => value + 1, ifAbsent: () => 1);
    }

    final familyEntries = familyCounts.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return [
      for (final entry in familyEntries)
        _CategoryOption(
          key: _annotationTypeKey(entry.key),
          label: entry.key,
          count: entry.value,
          type: _CategoryType.annotationFamily,
        ),
    ];
  }

  void _setCategoryVisible(String key, bool visible) {
    setState(() {
      if (visible) {
        _hiddenCategoryKeys.remove(key);
      } else {
        _hiddenCategoryKeys.add(key);
      }
      _syncFilteredTimelineData();
    });
  }

  void _setAnnotationTypeVisible(String key, bool visible) {
    setState(() {
      if (visible) {
        _hiddenAnnotationTypeKeys.remove(key);
      } else {
        _hiddenAnnotationTypeKeys.add(key);
      }
      _syncFilteredTimelineData();
    });
  }

  void _syncFilteredTimelineData() {
    _videoController.setPointsOfInterest(_filteredPointsOfInterest);
    _videoController.setAnnotations(_filteredAnnotations);
  }

  void _setMountedVideoPath(String path) {
    _mountedVideoPath = path.trim();
    if (_mountedVideoPath.isEmpty) {
      _metadataDirectory = '';
      _reportCsvPath = '';
      _qaPairsPath = '';
      _captionsPath = '';
      _reportCsvFound = null;
      _qaPairsFound = null;
      _captionsFound = null;
      return;
    }

    final parts = _mountedVideoPath.split('/');
    final filename = parts.isEmpty ? _mountedVideoPath : parts.last;
    final dot = filename.lastIndexOf('.');
    final baseName = dot <= 0 ? filename : filename.substring(0, dot);
    final parent = parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/');
    _metadataDirectory = parent.isEmpty ? '${baseName}_meta' : '$parent/${baseName}_meta';
    _reportCsvPath = '$_metadataDirectory/report.csv';
    _qaPairsPath = '$_metadataDirectory/qa_pairs.json';
    _captionsPath = '$_metadataDirectory/captions.json';
    _reportCsvFound = null;
    _qaPairsFound = null;
    _captionsFound = null;
  }

  Future<void> _refreshStatusPanels() async {
    try {
      final results = await Future.wait<dynamic>([
        _impactCycleClient.listJobs(),
        _impactCycleClient.getActivities(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _jobs = results[0] as List<ImpactCycleJob>;
        _activities = (results[1] as ImpactCycleActivitiesPage).activities;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _activities = const [
          ImpactCycleActivity(
            type: 'frontend',
            status: 'failed',
            message: 'Could not refresh jobs or activities.',
            jobId: '',
          ),
        ];
      });
    }
    await _refreshQaPairsStatus();
  }

  Future<void> _refreshQaPairsStatus() async {
    final metadataDirectory = _metadataDirectory;
    if (metadataDirectory.isEmpty) {
      return;
    }
    try {
      final listing = await _mountedFilesClient.list(path: metadataDirectory, kind: 'all');
      MountedFileEntry? reportCsv;
      MountedFileEntry? qaPairs;
      MountedFileEntry? captions;
      for (final entry in listing.entries) {
        if (!entry.isFile) {
          continue;
        }
        if (entry.name == 'report.csv' && entry.isCsv) {
          reportCsv = entry;
        } else if (entry.name == 'qa_pairs.json' && entry.isJson) {
          qaPairs = entry;
        } else if (entry.name == 'captions.json' && entry.isJson) {
          captions = entry;
        }
      }
      if (!mounted || metadataDirectory != _metadataDirectory) {
        return;
      }
      setState(() {
        _reportCsvFound = reportCsv != null;
        _qaPairsFound = qaPairs != null;
        _captionsFound = captions != null;
      });
      if (reportCsv != null && _csvFilename != reportCsv.path) {
        await _loadMountedCsv(reportCsv);
      }
      if (qaPairs != null && _annotationFilename != qaPairs.path) {
        final url = qaPairs.url ?? Uri(path: '/api/mounted-files/file/', queryParameters: {'path': qaPairs.path}).toString();
        final text = await html.HttpRequest.getString(url);
        _loadAnnotationJsonText(text: text, filename: qaPairs.path);
      }
    } catch (_) {
      if (!mounted || metadataDirectory != _metadataDirectory) {
        return;
      }
      setState(() {
        _reportCsvFound = false;
        _qaPairsFound = false;
        _captionsFound = false;
      });
    }
  }

  Future<void> _showJobs() async {
    await _refreshStatusPanels();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _JobsDialog(jobs: _jobs, onCancelJob: _cancelJobFromDialog),
    );
  }

  Future<List<ImpactCycleJob>> _cancelJobFromDialog(ImpactCycleJob job) async {
    try {
      await _impactCycleClient.cancelJob(job.id);
      final jobs = await _impactCycleClient.listJobs();
      final shortId = job.id.length > 8 ? job.id.substring(0, 8) : job.id;
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _statusMessage = 'Cancellation requested for ${job.operation} job $shortId.';
        });
      }
      return jobs;
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not cancel job: $error';
          _statusMessage = 'Job cancellation failed.';
        });
      }
      rethrow;
    }
  }

  Future<void> _showActivities() async {
    await _refreshStatusPanels();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _ActivitiesDialog(activities: _activities),
    );
  }

  void _handleBrowserKeyDown(html.KeyboardEvent event) {
    if (_annotationDialogOpen) {
      return;
    }
    if (_isTextInputFocused()) {
      return;
    }

    if (event.code == 'Space') {
      event.preventDefault();
      _togglePlayback();
      return;
    }
    if (event.code == 'ArrowLeft') {
      event.preventDefault();
      _seekRelative(const Duration(milliseconds: -500));
      return;
    }
    if (event.code == 'ArrowRight') {
      event.preventDefault();
      _seekRelative(const Duration(milliseconds: 500));
      return;
    }
    if (event.code == 'KeyA') {
      event.preventDefault();
      if (_videoController.hasVideo) {
        _openAnnotationDialog();
      }
    }
  }

  bool _isTextInputFocused() {
    final element = html.document.activeElement;
    final tagName = element?.tagName.toLowerCase();
    return tagName == 'input' ||
        tagName == 'textarea' ||
        tagName == 'select' ||
        element?.isContentEditable == true;
  }

  void _togglePlayback() {
    if (!_videoController.hasVideo) {
      return;
    }
    if (_videoController.isPlaying) {
      _videoController.pause();
    } else {
      _videoController.play();
    }
  }

  void _seekRelative(Duration offset) {
    if (!_videoController.hasVideo) {
      return;
    }
    _videoController.seekTo(_videoController.position + offset);
  }

  void _seekToNextPoi() {
    if (!_videoController.hasVideo) {
      return;
    }
    final position = _videoController.position;
    final timestamps = _filteredTimelineTimestamps;
    for (final ts in timestamps) {
      if (ts > position) {
        _videoController.seekTo(ts);
        return;
      }
    }
  }

  void _seekToLastPoi() {
    if (!_videoController.hasVideo) {
      return;
    }
    final position = _videoController.position;
    final timestamps = _filteredTimelineTimestamps;
    Duration? target;
    for (final ts in timestamps) {
      if (ts < position) {
        target = ts;
      } else {
        break;
      }
    }
    if (target != null) {
      _videoController.seekTo(target);
    }
  }

  AnnotationDataset _newAnnotationDataset() {
    return AnnotationDataset(
      name: '${_videoBaseName()}_annotations',
      version: '1.0',
      description: 'Annotations created in Video Bench',
      qaPairs: const [],
    );
  }

  String _nextAnnotationId() {
    final usedIds = _annotations.map((annotation) => annotation.id).toSet();
    var index = _annotations.length + 1;
    while (true) {
      final id = 'qa_${index.toString().padLeft(4, '0')}';
      if (!usedIds.contains(id)) {
        return id;
      }
      index++;
    }
  }

  String _videoIdForAnnotation() => _videoBaseName().replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');

  String _videoBaseName() {
    final filename = _videoFilename ?? 'video';
    final withoutPath = filename.split('/').last.split('\\').last;
    final dot = withoutPath.lastIndexOf('.');
    return dot <= 0 ? withoutPath : withoutPath.substring(0, dot);
  }

  void _releaseVideoUrl() {
    final url = _videoObjectUrl;
    if (url == null) {
      return;
    }
    try {
      _videoUrlOwner?.releaseFileUrl(url);
    } catch (_) {
      // The browser also releases blob URLs when the page unloads.
    }
    _videoObjectUrl = null;
    _videoUrlOwner = null;
  }

  void _handleControllerUpdate() {
    if (mounted) {
      setState(() {});
    }
    DevtoolsAgentBridge.instance.emitStateChanged();
  }

  void _registerAgentHooks() {
    final bridge = DevtoolsAgentBridge.instance;
    bridge.registerStateProvider(this, 'videoBench', _agentState);
    bridge.registerCommand(this, 'videoBench.loadMountedVideo', (args) async {
      final path = _requiredString(args, 'path');
      setState(() {
        _errorMessage = null;
        _statusMessage = 'Loading mounted video via DevTools agent...';
      });
      _loadVideoUrl(
        url: _mountedFileUrl(path),
        filename: path,
        mountedVideoPath: path,
      );
      setState(() => _statusMessage = 'Mounted video loaded via DevTools agent.');
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.loadMountedCsv', (args) async {
      await _loadMountedCsvPath(_requiredString(args, 'path'));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.loadMountedAnnotationJson', (args) async {
      await _loadMountedAnnotationJsonPath(_requiredString(args, 'path'));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.loadMountedSession', (args) async {
      final videoPath = _requiredString(args, 'videoPath');
      final csvPath = args['csvPath']?.toString();
      final annotationPath = args['annotationPath']?.toString();
      setState(() {
        _errorMessage = null;
        _statusMessage = 'Loading mounted session via DevTools agent...';
      });
      _loadVideoUrl(
        url: _mountedFileUrl(videoPath),
        filename: videoPath,
        mountedVideoPath: videoPath,
      );
      if (csvPath != null && csvPath.isNotEmpty) {
        await _loadMountedCsvPath(csvPath);
      }
      if (annotationPath != null && annotationPath.isNotEmpty) {
        await _loadMountedAnnotationJsonPath(annotationPath);
      }
      if (mounted) {
        setState(() => _statusMessage = 'Mounted session loaded via DevTools agent.');
      }
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.play', (_) async {
      await _videoController.play();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.pause', (_) {
      _videoController.pause();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.togglePlayback', (_) {
      _togglePlayback();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.seekTo', (args) {
      _videoController.seekTo(_durationFromAgentArgs(args));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.seekRelative', (args) {
      _seekRelative(_durationFromAgentArgs(args));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.seekToNextPoi', (_) {
      _seekToNextPoi();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.seekToLastPoi', (_) {
      _seekToLastPoi();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.setPlaybackRate', (args) {
      _videoController.setPlaybackRate(_requiredDouble(args, 'rate'));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.setCategoryVisible', (args) {
      final key = args['key']?.toString() ?? _poiCategoryKey(_requiredString(args, 'objectType'));
      _setCategoryVisible(key, _optionalBool(args['visible'], fallback: true));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.setAnnotationTypeVisible', (args) {
      final key = args['key']?.toString() ?? _annotationTypeKey(_requiredString(args, 'family'));
      _setAnnotationTypeVisible(key, _optionalBool(args['visible'], fallback: true));
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.addAnnotation', (args) async {
      final annotation = _annotationFromAgentArgs(args);
      final dataset = (_annotationDataset ?? _newAnnotationDataset()).add(annotation);
      setState(() {
        _annotationDataset = dataset;
        _syncFilteredTimelineData();
        _statusMessage = 'Added annotation ${annotation.id} via DevTools agent.';
      });
      await _persistAnnotationDataset();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.updateAnnotation', (args) async {
      final annotation = _annotationFromAgentArgs(args);
      final dataset = (_annotationDataset ?? _newAnnotationDataset()).replace(annotation);
      setState(() {
        _annotationDataset = dataset;
        _syncFilteredTimelineData();
        _statusMessage = 'Updated annotation ${annotation.id} via DevTools agent.';
      });
      await _persistAnnotationDataset();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.deleteAnnotation', (args) async {
      final id = _requiredString(args, 'id');
      final dataset = (_annotationDataset ?? _newAnnotationDataset()).delete(id);
      setState(() {
        _annotationDataset = dataset;
        _syncFilteredTimelineData();
        _statusMessage = 'Deleted annotation $id via DevTools agent.';
      });
      await _persistAnnotationDataset();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.persistAnnotations', (_) async {
      await _persistAnnotationDataset();
      return _agentState();
    });
    bridge.registerCommand(this, 'videoBench.refreshStatus', (_) async {
      await _refreshStatusPanels();
      return _agentState();
    });
  }

  Future<void> _loadMountedCsvPath(String path) async {
    setState(() {
      _errorMessage = null;
      _statusMessage = 'Loading mounted CSV report via DevTools agent...';
    });
    final text = await html.HttpRequest.getString(_mountedFileUrl(path));
    _loadCsvText(csvText: text, filename: path);
    if (mounted) {
      setState(() {
        _reportCsvFound = true;
        _statusMessage = 'Loaded ${_pointsOfInterest.length} points of interest from $path.';
      });
    }
  }

  Future<void> _loadMountedAnnotationJsonPath(String path) async {
    setState(() {
      _errorMessage = null;
      _statusMessage = 'Loading mounted annotation JSON via DevTools agent...';
    });
    final text = await html.HttpRequest.getString(_mountedFileUrl(path));
    _loadAnnotationJsonText(text: text, filename: path);
  }

  Map<String, dynamic> _agentState() {
    return {
      'status': _statusMessage,
      'error': _errorMessage,
      'videoFilename': _videoFilename,
      'mountedVideoPath': _mountedVideoPath,
      'csvFilename': _csvFilename,
      'annotationFilename': _annotationFilename,
      'metadataDirectory': _metadataDirectory,
      'reportCsvPath': _reportCsvPath,
      'qaPairsPath': _qaPairsPath,
      'captionsPath': _captionsPath,
      'reportCsvFound': _reportCsvFound,
      'qaPairsFound': _qaPairsFound,
      'captionsFound': _captionsFound,
      'counts': {
        'pointsOfInterest': _pointsOfInterest.length,
        'filteredPointsOfInterest': _filteredPointsOfInterest.length,
        'annotations': _annotations.length,
        'filteredAnnotations': _filteredAnnotations.length,
        'jobs': _jobs.length,
        'runningJobs': _jobs.where((job) => job.isRunning).length,
        'activities': _activities.length,
        'failedActivities': _activities.where((activity) => activity.isFailure).length,
      },
      'video': {
        'hasVideo': _videoController.hasVideo,
        'isPlaying': _videoController.isPlaying,
        'positionMs': _videoController.position.inMilliseconds,
        'durationMs': _videoController.duration.inMilliseconds,
        'playbackRate': _videoController.playbackRate,
      },
      'filters': {
        'hiddenCategoryKeys': _hiddenCategoryKeys.toList()..sort(),
        'hiddenAnnotationTypeKeys': _hiddenAnnotationTypeKeys.toList()..sort(),
      },
      'categories': _categoryOptions().map(_categoryOptionToJson).toList(growable: false),
      'annotationTypes': _annotationTypeOptions().map(_categoryOptionToJson).toList(growable: false),
      'pointsOfInterest': _pointsOfInterest.map(_poiToAgentJson).toList(growable: false),
      'filteredPointsOfInterest': _filteredPointsOfInterest.map(_poiToAgentJson).toList(growable: false),
      'annotations': _annotations.map(_annotationToAgentJson).toList(growable: false),
      'filteredAnnotations': _filteredAnnotations.map(_annotationToAgentJson).toList(growable: false),
      'jobs': _jobs.map(_jobToAgentJson).toList(growable: false),
      'activities': _activities.map(_activityToAgentJson).toList(growable: false),
    };
  }

  Duration _durationFromAgentArgs(Map<String, dynamic> args) {
    if (args.containsKey('milliseconds')) {
      return Duration(milliseconds: _requiredInt(args, 'milliseconds'));
    }
    if (args.containsKey('seconds')) {
      return Duration(milliseconds: (_requiredDouble(args, 'seconds') * Duration.millisecondsPerSecond).round());
    }
    throw ArgumentError('Expected milliseconds or seconds.');
  }

  BenchmarkAnnotation _annotationFromAgentArgs(Map<String, dynamic> args) {
    final rawAnnotation = args['annotation'];
    if (rawAnnotation is! Map) {
      throw ArgumentError('Expected annotation object.');
    }
    return BenchmarkAnnotation.fromJson(Map<String, dynamic>.from(rawAnnotation));
  }

  String _mountedFileUrl(String path) {
    return Uri(path: '/api/mounted-files/file/', queryParameters: {'path': path}).toString();
  }

  Map<String, dynamic> _categoryOptionToJson(_CategoryOption option) => {
        'key': option.key,
        'label': option.label,
        'count': option.count,
        'type': option.type.name,
        'visible': !_hiddenCategoryKeys.contains(option.key) && !_hiddenAnnotationTypeKeys.contains(option.key),
      };

  Map<String, dynamic> _poiToAgentJson(VideoPointOfInterest poi) => {
        'objectId': poi.objectId,
        'objectType': poi.objectType,
        'timestampMs': poi.timestamp.inMilliseconds,
        'timestamp': formatVideoTimestamp(poi.timestamp),
        'firstTimeSeenMs': poi.firstTimeSeen.inMilliseconds,
        'totalScreenTimeMs': poi.totalScreenTime.inMilliseconds,
        'confidence': poi.confidence,
        'boundingBox': {
          'x1': poi.boundingBox.x1,
          'y1': poi.boundingBox.y1,
          'x2': poi.boundingBox.x2,
          'y2': poi.boundingBox.y2,
        },
      };

  Map<String, dynamic> _annotationToAgentJson(BenchmarkAnnotation annotation) => {
        ...annotation.toJson(),
        'timestampMs': annotation.timestamp.inMilliseconds,
        'timestamp': formatVideoTimestamp(annotation.timestamp),
      };

  Map<String, dynamic> _jobToAgentJson(ImpactCycleJob job) => {
        'id': job.id,
        'operation': job.operation,
        'status': job.status,
        'videoName': job.videoName,
        'videoUrl': job.videoUrl,
        'processedFrames': job.processedFrames,
        'totalFrames': job.totalFrames,
        'percent': job.percent,
        'error': job.error,
        'bundleUrl': job.bundleUrl,
        'isRunning': job.isRunning,
        'isCompleted': job.isCompleted,
      };

  Map<String, dynamic> _activityToAgentJson(ImpactCycleActivity activity) => {
        'type': activity.type,
        'status': activity.status,
        'message': activity.message,
        'jobId': activity.jobId,
        'isFailure': activity.isFailure,
      };

  String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw ArgumentError('Expected non-empty $key.');
    }
    return value;
  }

  int _requiredInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null) {
      throw ArgumentError('Expected integer $key.');
    }
    return parsed;
  }

  double _requiredDouble(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is num) {
      return value.toDouble();
    }
    final parsed = double.tryParse(value?.toString() ?? '');
    if (parsed == null) {
      throw ArgumentError('Expected number $key.');
    }
    return parsed;
  }

  bool _optionalBool(Object? value, {required bool fallback}) {
    if (value is bool) {
      return value;
    }
    if (value == null) {
      return fallback;
    }
    final text = value.toString().toLowerCase();
    if (text == 'true') {
      return true;
    }
    if (text == 'false') {
      return false;
    }
    return fallback;
  }

  T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
    for (final value in values) {
      if (test(value)) {
        return value;
      }
    }
    return null;
  }
}

String _poiCategoryKey(String objectType) => 'object:$objectType';

String _annotationTypeKey(String family) => 'annotation:$family';

enum _CategoryType { object, annotationFamily }

class _CategoryOption {
  const _CategoryOption({
    required this.key,
    required this.label,
    required this.count,
    required this.type,
  });

  final String key;
  final String label;
  final int count;
  final _CategoryType type;
}

class _DroppedFile {
  const _DroppedFile({
    required this.rawFile,
    required this.name,
    required this.mime,
  });

  final dynamic rawFile;
  final String name;
  final String mime;

  bool get isVideo {
    final lowerName = name.toLowerCase();
    return mime.startsWith('video/') ||
        mime == 'application/mp4' ||
        mime == 'application/octet-stream' && lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mov') ||
        lowerName.endsWith('.webm') ||
        lowerName.endsWith('.mkv') ||
        lowerName.endsWith('.avi') ||
        lowerName.endsWith('.m4v');
  }

  bool get isCsv {
    final lowerName = name.toLowerCase();
    final lowerMime = mime.toLowerCase();
    return lowerName.endsWith('.csv') ||
        lowerMime.contains('csv') ||
        lowerMime.contains('excel');
  }

  bool get isJson {
    final lowerName = name.toLowerCase();
    final lowerMime = mime.toLowerCase();
    return lowerName.endsWith('.json') || lowerMime.contains('json');
  }

  static Future<_DroppedFile> fromDropzone(
    DropzoneViewController controller,
    dynamic file,
  ) async {
    return _DroppedFile(
      rawFile: file,
      name: await controller.getFilename(file),
      mime: await controller.getFileMIME(file),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.statusMessage,
    required this.failedActivityCount,
    required this.runningJobCount,
    required this.onShowActivities,
    required this.onShowJobs,
  });

  final String statusMessage;
  final int failedActivityCount;
  final int runningJobCount;
  final VoidCallback onShowActivities;
  final VoidCallback onShowJobs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.video_file,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Video Bench',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 2),
              Semantics(
                identifier: 'video-bench.status',
                liveRegion: true,
                child: Text(
                  statusMessage,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                ),
              ),
            ],
          ),
        ),
        Badge.count(
          count: failedActivityCount,
          isLabelVisible: failedActivityCount > 0,
          child: Semantics(
            identifier: 'video-bench.show-activities',
            button: true,
            label: 'activities',
            child: OutlinedButton.icon(
              onPressed: onShowActivities,
              icon: Icon(failedActivityCount > 0 ? Icons.error_outline : Icons.notifications_none),
              label: const Text('activities'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Badge.count(
          count: runningJobCount,
          isLabelVisible: runningJobCount > 0,
          child: Semantics(
            identifier: 'video-bench.show-jobs',
            button: true,
            label: 'jobs',
            child: FilledButton.tonalIcon(
              onPressed: onShowJobs,
              icon: const Icon(Icons.work_outline),
              label: const Text('jobs'),
            ),
          ),
        ),
      ],
    );
  }
}

class _CaptionGenerationParams {
  const _CaptionGenerationParams({
    required this.lmStudioUrl,
    required this.model,
    required this.fpsSampling,
    required this.captionPrompt,
  });

  final String lmStudioUrl;
  final String model;
  final int fpsSampling;
  final String captionPrompt;
}

class _QaPairsGenerationParams {
  const _QaPairsGenerationParams({
    required this.videoPaths,
    required this.lmStudioUrl,
    required this.model,
    required this.fpsSampling,
    required this.windowSizeSeconds,
    required this.qaPairsPerWindow,
    required this.qaGenerationPrompt,
  });

  final List<String> videoPaths;
  final String lmStudioUrl;
  final String model;
  final int fpsSampling;
  final int windowSizeSeconds;
  final int qaPairsPerWindow;
  final String qaGenerationPrompt;
}

class _GenerateQaPairsDialog extends StatefulWidget {
  const _GenerateQaPairsDialog({
    required this.client,
    required this.defaultOutputDirectory,
    required this.videoFilename,
    required this.initialVideoPath,
  });

  final MountedFilesClient client;
  final String defaultOutputDirectory;
  final String videoFilename;
  final String initialVideoPath;

  @override
  State<_GenerateQaPairsDialog> createState() => _GenerateQaPairsDialogState();
}

class _GenerateQaPairsDialogState extends State<_GenerateQaPairsDialog> {
  late final TextEditingController _lmStudioUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _fpsSamplingController;
  late final TextEditingController _windowSizeController;
  late final TextEditingController _qaPairsPerWindowController;
  late final TextEditingController _promptController;
  late Future<MountedFileListing> _listingFuture;
  late String _path;
  late final Set<String> _selectedVideos;
  final Set<String> _selectedDirectories = {};
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _lmStudioUrlController = TextEditingController(text: 'http://host.docker.internal:1234/v1');
    _modelController = TextEditingController(text: 'google/gemma-4-31b');
    _fpsSamplingController = TextEditingController(text: '3');
    _windowSizeController = TextEditingController(text: '25');
    _qaPairsPerWindowController = TextEditingController(text: '10');
    _promptController = TextEditingController(text: _defaultQaPairsPrompt);
    _path = _directoryOf(widget.initialVideoPath);
    _selectedVideos = {
      if (widget.initialVideoPath.isNotEmpty) widget.initialVideoPath,
    };
    _listingFuture = _loadListing();
  }

  @override
  void dispose() {
    _lmStudioUrlController.dispose();
    _modelController.dispose();
    _fpsSamplingController.dispose();
    _windowSizeController.dispose();
    _qaPairsPerWindowController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 920),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.quiz, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Generate QA pairs', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.videoFilename.isNotEmpty
                    ? 'Video: ${widget.videoFilename}'
                    : 'No video loaded',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              if (widget.defaultOutputDirectory.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'Output: ${widget.defaultOutputDirectory}/qa_pairs.json',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
                ),
              ],
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Mounted videos', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      _buildMountedVideoBrowser(context),
                      const SizedBox(height: 12),
                      _dialogField(_lmStudioUrlController, 'LM Studio URL'),
                      const SizedBox(height: 12),
                      _dialogField(_modelController, 'Model'),
                      const SizedBox(height: 12),
                      _dialogField(_fpsSamplingController, 'FPS sampling',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                      const SizedBox(height: 12),
                      _dialogField(_windowSizeController, 'Window size in seconds',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                      const SizedBox(height: 12),
                      _dialogField(_qaPairsPerWindowController, 'QA-pairs per window',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                      const SizedBox(height: 12),
                      Text('QA generation prompt', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      Semantics(
                        identifier: 'qa-pairs-dialog.prompt',
                        textField: true,
                        label: 'QA generation prompt',
                        child: TextField(
                          controller: _promptController,
                          maxLines: 8,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: 'Enter the prompt for QA-pair generation...',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Semantics(
                    identifier: 'qa-pairs-dialog.cancel',
                    button: true,
                    label: 'Cancel',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const Spacer(),
                  Semantics(
                    identifier: 'qa-pairs-dialog.generate',
                    button: true,
                    label: 'Generate',
                    child: FilledButton.icon(
                      onPressed: _generate,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMountedVideoBrowser(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        height: 360,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FutureBuilder<MountedFileListing>(
            future: _listingFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done || _busy) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Could not browse mounted files: ${snapshot.error}'));
              }
              final listing = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          listing.path.isEmpty ? 'Mounted input root' : listing.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: listing.parent == null ? null : () => _openDirectory(listing.parent!),
                        icon: const Icon(Icons.arrow_upward),
                        label: const Text('Up'),
                      ),
                    ],
                  ),
                  Text(
                    '${_selectedVideos.length} video file(s), ${_selectedDirectories.length} folder(s) selected',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: _buildEntryList(listing.entries)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEntryList(List<MountedFileEntry> entries) {
    if (entries.isEmpty) {
      return const Center(child: Text('No files or folders in this directory.'));
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.isDirectory
            ? _selectedDirectories.contains(entry.path)
            : _selectedVideos.contains(entry.path);
        return ListTile(
          dense: true,
          leading: Checkbox(
            value: selected,
            onChanged: entry.isDirectory
                ? (_) => _toggleDirectory(entry.path)
                : entry.isVideo
                    ? (_) => _toggleVideo(entry.path)
                    : null,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            entry.isDirectory ? 'Directory' : '${entry.kind.toUpperCase()} - ${entry.path}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: entry.isDirectory || entry.isVideo,
          trailing: entry.isDirectory
              ? IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _openDirectory(entry.path),
                )
              : null,
          onTap: entry.isDirectory ? () => _toggleDirectory(entry.path) : entry.isVideo ? () => _toggleVideo(entry.path) : null,
        );
      },
    );
  }

  Widget _dialogField(TextEditingController controller, String label, {TextInputType? keyboardType}) {
    return Semantics(
      identifier: 'qa-pairs-dialog.${_semanticIdForLabel(label)}',
      textField: true,
      label: label,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  void _toggleVideo(String path) {
    setState(() {
      if (!_selectedVideos.remove(path)) {
        _selectedVideos.add(path);
      }
    });
  }

  Future<void> _selectDirectory(String path) async {
    setState(() => _busy = true);
    try {
      final videos = await _collectVideoFiles(path);
      setState(() {
        _selectedDirectories.add(path);
        _selectedVideos.addAll(videos);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleDirectory(String path) async {
    if (_selectedDirectories.contains(path)) {
      setState(() => _busy = true);
      try {
        final videos = await _collectVideoFiles(path);
        setState(() {
          _selectedDirectories.remove(path);
          _selectedVideos.removeAll(videos);
        });
      } finally {
        if (mounted) {
          setState(() => _busy = false);
        }
      }
      return;
    }
    await _selectDirectory(path);
  }

  Future<List<String>> _collectVideoFiles(String path) async {
    final listing = await widget.client.list(path: path, kind: 'all');
    final videos = <String>[];
    for (final entry in listing.entries) {
      if (entry.isDirectory) {
        videos.addAll(await _collectVideoFiles(entry.path));
      } else if (entry.isVideo) {
        videos.add(entry.path);
      }
    }
    return videos;
  }

  void _openDirectory(String path) {
    setState(() {
      _path = path;
      _listingFuture = _loadListing();
    });
  }

  Future<MountedFileListing> _loadListing() => widget.client.list(path: _path, kind: 'all');

  String _directoryOf(String path) {
    final parts = path.split('/');
    if (parts.length <= 1) {
      return '';
    }
    return parts.sublist(0, parts.length - 1).join('/');
  }

  String _semanticIdForLabel(String label) {
    return label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  void _generate() {
    final videoPaths = _selectedVideos.toList()..sort();
    final url = _lmStudioUrlController.text.trim();
    final model = _modelController.text.trim();
    final fps = int.tryParse(_fpsSamplingController.text.trim());
    final windowSize = int.tryParse(_windowSizeController.text.trim());
    final qaPairsPerWindow = int.tryParse(_qaPairsPerWindowController.text.trim());
    final prompt = _promptController.text.trim();
    if (videoPaths.isEmpty ||
        url.isEmpty ||
        model.isEmpty ||
        fps == null ||
        fps < 1 ||
        windowSize == null ||
        windowSize < 1 ||
        qaPairsPerWindow == null ||
        qaPairsPerWindow < 1 ||
        prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one video and fill all fields with positive numeric values.')),
      );
      return;
    }
    Navigator.of(context).pop(_QaPairsGenerationParams(
      videoPaths: videoPaths,
      lmStudioUrl: url,
      model: model,
      fpsSampling: fps,
      windowSizeSeconds: windowSize,
      qaPairsPerWindow: qaPairsPerWindow,
      qaGenerationPrompt: prompt,
    ));
  }
}

const _defaultQaPairsPrompt = 'Generate question-answer pairs for the selected video windows. '
    'Focus on visually grounded facts, object interactions, temporal changes, and scene context. '
    'Return concise questions with accurate answers based only on visible evidence.';

const _defaultCaptionPrompt = 'You are a detailed video frame captioner. '
    'Describe everything you see in this video frame with maximum detail. '
    'Include the overall scenery and environment (weather, lighting, time of day, terrain, vegetation). '
    'Describe all objects of every kind: vehicles, aircraft, people, animals, buildings, infrastructure, equipment, and any other items. '
    'For each moving object or person, provide a fully detailed description: its type, color, size, shape, markings, and distinctive features. '
    'Describe how it looks, its direction of travel in relation to infrastructure such as roads, runways, taxiways, or paths, '
    'and its movement direction (left to right, approaching the camera, moving away, crossing, stationary, etc.). '
    'Describe how each object is positioned in relation to the camera: foreground or background, left/center/right of frame, '
    'partially visible or fully visible, occluded by other objects, and its approximate distance. '
    'Include as many detailed characteristics as possible: speed relative to other objects, interactions between objects, '
    'text or logos visible on objects, surface conditions, and any notable events or anomalies. '
    'Structure the caption as flowing descriptive prose, not bullet points.';

class _GenerateCaptionsDialog extends StatefulWidget {
  const _GenerateCaptionsDialog({
    required this.defaultOutputDirectory,
    required this.videoFilename,
  });

  final String defaultOutputDirectory;
  final String videoFilename;

  @override
  State<_GenerateCaptionsDialog> createState() => _GenerateCaptionsDialogState();
}

class _GenerateCaptionsDialogState extends State<_GenerateCaptionsDialog> {
  late final TextEditingController _lmStudioUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _fpsSamplingController;
  late final TextEditingController _promptController;

  @override
  void initState() {
    super.initState();
    _lmStudioUrlController = TextEditingController(text: 'http://host.docker.internal:1234/v1');
    _modelController = TextEditingController(text: 'google/gemma-4-31b');
    _fpsSamplingController = TextEditingController(text: '3');
    _promptController = TextEditingController(text: _defaultCaptionPrompt);
  }

  @override
  void dispose() {
    _lmStudioUrlController.dispose();
    _modelController.dispose();
    _fpsSamplingController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.closed_caption, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Generate captions', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.videoFilename.isNotEmpty
                    ? 'Video: ${widget.videoFilename}'
                    : 'No video loaded',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              if (widget.defaultOutputDirectory.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'Output: ${widget.defaultOutputDirectory}/captions.json',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
                ),
              ],
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _dialogField(_lmStudioUrlController, 'LM Studio URL'),
                      const SizedBox(height: 12),
                      _dialogField(_modelController, 'Model'),
                      const SizedBox(height: 12),
                      _dialogField(_fpsSamplingController, 'FPS sampling (caption every Nth frame)',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                      const SizedBox(height: 12),
                      Text('Captioning prompt', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      Semantics(
                        identifier: 'caption-dialog.prompt',
                        textField: true,
                        label: 'Captioning prompt',
                        child: TextField(
                          controller: _promptController,
                          maxLines: 8,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: 'Enter the prompt for caption generation...',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Semantics(
                    identifier: 'caption-dialog.cancel',
                    button: true,
                    label: 'Cancel',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const Spacer(),
                  Semantics(
                    identifier: 'caption-dialog.generate',
                    button: true,
                    label: 'Generate',
                    child: FilledButton.icon(
                      onPressed: _generate,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogField(TextEditingController controller, String label, {TextInputType? keyboardType}) {
    return Semantics(
      identifier: 'caption-dialog.${_semanticIdForLabel(label)}',
      textField: true,
      label: label,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  String _semanticIdForLabel(String label) {
    return label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  void _generate() {
    final url = _lmStudioUrlController.text.trim();
    final model = _modelController.text.trim();
    final fps = int.tryParse(_fpsSamplingController.text.trim());
    final prompt = _promptController.text.trim();
    if (url.isEmpty || model.isEmpty || fps == null || fps < 1 || prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill in all fields. FPS sampling must be a positive integer.')),
      );
      return;
    }
    Navigator.of(context).pop(_CaptionGenerationParams(
      lmStudioUrl: url,
      model: model,
      fpsSampling: fps,
      captionPrompt: prompt,
    ));
  }
}

class _QaWorkflowRow extends StatelessWidget {
  const _QaWorkflowRow({
    required this.filename,
    required this.exists,
    required this.checking,
    required this.onBrowsePressed,
    this.generateButtonLabel,
    this.onGeneratePressed,
  });

  final String filename;
  final bool exists;
  final bool checking;
  final VoidCallback onBrowsePressed;
  final String? generateButtonLabel;
  final VoidCallback? onGeneratePressed;

  @override
  Widget build(BuildContext context) {
    final color = exists ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    return Row(
      children: [
        if (checking)
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(exists ? Icons.check_circle : Icons.cancel, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(filename, overflow: TextOverflow.ellipsis)),
        if (generateButtonLabel != null) ...[
          const SizedBox(width: 8),
          Semantics(
            identifier: 'video-bench.qa-workflow.$filename.generate',
            button: true,
            enabled: onGeneratePressed != null,
            label: generateButtonLabel,
            child: FilledButton.tonal(
              onPressed: onGeneratePressed,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(fontSize: 12),
                minimumSize: const Size(0, 34),
              ),
              child: Text(generateButtonLabel!),
            ),
          ),
        ],
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: onBrowsePressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: const TextStyle(fontSize: 12),
            minimumSize: const Size(0, 34),
          ),
          icon: const Icon(Icons.folder_open),
          label: const Text('Browse'),
        ),
      ],
    );
  }
}

class _MountedMetadataFileDialog extends StatefulWidget {
  const _MountedMetadataFileDialog({
    required this.client,
    required this.kind,
    required this.title,
    required this.description,
    required this.emptyMessage,
    required this.fileIcon,
  });

  final MountedFilesClient client;
  final String kind;
  final String title;
  final String description;
  final String emptyMessage;
  final IconData fileIcon;

  @override
  State<_MountedMetadataFileDialog> createState() => _MountedMetadataFileDialogState();
}

class _MountedMetadataFileDialogState extends State<_MountedMetadataFileDialog> {
  var _path = '';
  MountedFileEntry? _selected;
  late Future<MountedFileListing> _listingFuture;

  @override
  void initState() {
    super.initState();
    _listingFuture = _loadListing();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(widget.fileIcon, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<MountedFileListing>(
                  future: _listingFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _DialogError(message: 'Could not browse mounted files: ${snapshot.error}');
                    }
                    final listing = snapshot.data!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                listing.path.isEmpty ? 'Mounted input root' : listing.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: listing.parent == null ? null : () => _openDirectory(listing.parent!),
                              icon: const Icon(Icons.arrow_upward),
                              label: const Text('Up'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(child: _buildEntryList(listing.entries)),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Load'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryList(List<MountedFileEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Text(widget.emptyMessage, style: const TextStyle(color: Color(0xFF94A3B8))),
      );
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selectable = entry.isDirectory || _isTargetKind(entry);
        final selected = entry.path == _selected?.path;
        return ListTile(
          leading: Icon(entry.isDirectory ? Icons.folder : widget.fileIcon),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            entry.isDirectory ? 'Directory' : entry.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: selectable,
          selected: selected,
          trailing: selected ? const Icon(Icons.check_circle) : null,
          onTap: () {
            if (entry.isDirectory) {
              _openDirectory(entry.path);
            } else if (_isTargetKind(entry)) {
              setState(() => _selected = entry);
            }
          },
        );
      },
    );
  }

  Future<MountedFileListing> _loadListing() => widget.client.list(path: _path, kind: widget.kind);

  bool _isTargetKind(MountedFileEntry entry) => entry.kind == widget.kind;

  void _openDirectory(String path) {
    setState(() {
      _path = path;
      _selected = null;
      _listingFuture = _loadListing();
    });
  }
}

class _DialogError extends StatelessWidget {
  const _DialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF451A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF991B1B)),
      ),
      child: Text(message),
    );
  }
}

class _JobsDialog extends StatefulWidget {
  const _JobsDialog({required this.jobs, required this.onCancelJob});

  final List<ImpactCycleJob> jobs;
  final Future<List<ImpactCycleJob>> Function(ImpactCycleJob job) onCancelJob;

  @override
  State<_JobsDialog> createState() => _JobsDialogState();
}

class _JobsDialogState extends State<_JobsDialog> {
  late List<ImpactCycleJob> _jobs;
  String? _cancellingJobId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _jobs = widget.jobs;
  }

  Future<void> _cancelJob(ImpactCycleJob job) async {
    setState(() {
      _cancellingJobId = job.id;
      _error = null;
    });
    try {
      final jobs = await widget.onCancelJob(job);
      if (!mounted) {
        return;
      }
      setState(() {
        _jobs = jobs;
        _cancellingJobId = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cancellingJobId = null;
        _error = 'Could not kill job: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Jobs'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                _DialogError(message: _error!),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: _jobs.isEmpty
                    ? const Text('No jobs yet.')
                    : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _jobs.length,
                      separatorBuilder: (_, __) => const Divider(height: 18),
                      itemBuilder: (context, index) {
                        final job = _jobs[index];
                        final isCancelling = _cancellingJobId == job.id;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(job.videoName, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${job.operation} - ${job.status} - ${job.percent}% (${job.processedFrames}/${job.totalFrames})',
                                    style: const TextStyle(color: Color(0xFF94A3B8)),
                                  ),
                                  if (job.error.isNotEmpty)
                                    Text(
                                      job.error,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Color(0xFFFCA5A5)),
                                    ),
                                ],
                              ),
                            ),
                            if (job.isRunning) ...[
                              const SizedBox(width: 12),
                              Semantics(
                                identifier: 'video-bench.jobs.kill-${job.id}',
                                button: true,
                                label: 'Kill job',
                                child: OutlinedButton.icon(
                                  onPressed: isCancelling ? null : () => _cancelJob(job),
                                  icon: isCancelling
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Icon(Icons.stop_circle_outlined),
                                  label: const Text('Kill'),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}

class _ActivitiesDialog extends StatelessWidget {
  const _ActivitiesDialog({required this.activities});

  final List<ImpactCycleActivity> activities;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Activities'),
      content: SizedBox(
        width: 560,
        child: activities.isEmpty
            ? const Text('No activity checks have run yet.')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: activities.length,
                separatorBuilder: (_, __) => const Divider(height: 18),
                itemBuilder: (context, index) {
                  final activity = activities[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      activity.isFailure ? Icons.error_outline : Icons.check_circle_outline,
                      color: activity.isFailure ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7),
                    ),
                    title: Text('${activity.type}: ${activity.status}'),
                    subtitle: Text(activity.message),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}

class _UploadDialog extends StatelessWidget {
  const _UploadDialog({
    required this.hasVideo,
    required this.annotationFilename,
    required this.onFilesSelected,
    required this.onAnnotationFileSelected,
  });

  final bool hasVideo;
  final String? annotationFilename;
  final DropzoneFilesSelected onFilesSelected;
  final DropzoneFileSelected onAnnotationFileSelected;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.upload_file,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Upload files',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Drag and drop a video file and optional CSV report. You can also add an optional annotation JSON file.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF94A3B8),
                    ),
              ),
              const SizedBox(height: 18),
              DropZonePanel(
                hasVideo: hasVideo,
                onFilesSelected: onFilesSelected,
              ),
              const SizedBox(height: 12),
              AnnotationDropZonePanel(
                filename: annotationFilename,
                onFileSelected: onAnnotationFileSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyVideoState extends StatelessWidget {
  const _EmptyVideoState();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topLeft,
          radius: 1.25,
          colors: [Color(0x331D4ED8), Color(0xFF020617)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_creation_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'No video loaded',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Drop a local video file below to inspect it on the timeline.',
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.hasVideo,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.playbackRate,
    required this.onTogglePlayback,
    required this.onSkipBackward,
    required this.onSkipForward,
    required this.onPlaybackRateChanged,
  });

  final bool hasVideo;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double playbackRate;
  final VoidCallback onTogglePlayback;
  final VoidCallback onSkipBackward;
  final VoidCallback onSkipForward;
  final ValueChanged<double> onPlaybackRateChanged;

  @override
  Widget build(BuildContext context) {
    const speedOptions = <double>[0.25, 0.5, 0.75, 1, 1.25, 1.5, 2];

    return Row(
      children: [
        Tooltip(
          message: 'Back 10 seconds (Left arrow)',
          child: _controlChip(
            identifier: 'video-bench.playback.seek-backward-10',
            enabled: hasVideo,
            onTap: onSkipBackward,
            icon: Icons.replay_10,
            label: '-10s',
          ),
        ),
        const SizedBox(width: 6),
        Semantics(
          identifier: 'video-bench.playback.play-pause',
          button: true,
          enabled: hasVideo,
          label: isPlaying ? 'Pause video' : 'Play video',
          child: FilledButton.icon(
            onPressed: hasVideo ? onTogglePlayback : null,
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            label: Text(isPlaying ? 'Pause' : 'Play'),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Forward 10 seconds (Right arrow)',
          child: _controlChip(
            identifier: 'video-bench.playback.seek-forward-10',
            enabled: hasVideo,
            onTap: onSkipForward,
            icon: Icons.forward_10,
            label: '+10s',
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          identifier: 'video-bench.playback.speed',
          button: true,
          enabled: hasVideo,
          label: 'Playback speed ${_formatPlaybackRate(playbackRate)}',
          child: PopupMenuButton<double>(
            enabled: hasVideo,
            tooltip: 'Playback speed',
            onSelected: onPlaybackRateChanged,
            itemBuilder: (context) => [
              for (final speed in speedOptions)
                PopupMenuItem(
                  value: speed,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: playbackRate == speed
                            ? const Icon(Icons.check, size: 18)
                            : null,
                      ),
                      Text(_formatPlaybackRate(speed)),
                    ],
                  ),
                ),
            ],
            child: Chip(
              avatar: const Icon(Icons.settings, size: 18),
              label: Text(_formatPlaybackRate(playbackRate)),
            ),
          ),
        ),
        const Spacer(),
        Text(
          '${formatVideoTimestamp(position)} / ${formatVideoTimestamp(duration)}',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFCBD5E1),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ],
    );
  }

  String _formatPlaybackRate(double speed) {
    if (speed == speed.roundToDouble()) {
      return '${speed.toStringAsFixed(0)}x';
    }
    return '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';
  }

  Widget _controlChip({
    required String identifier,
    required bool enabled,
    required VoidCallback onTap,
    required IconData icon,
    required String label,
  }) {
    return Semantics(
      identifier: identifier,
      button: true,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.48,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: enabled ? onTap : null,
            child: Chip(
              avatar: Icon(icon, size: 18),
              label: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: const Color(0xFF94A3B8),
              ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF451A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF991B1B)),
      ),
      child: Text(message),
    );
  }
}

class _CategoryFilter extends StatelessWidget {
  const _CategoryFilter({
    required this.categories,
    required this.hiddenKeys,
    required this.onChanged,
    this.emptyMessage = 'Load a CSV report to filter categories.',
  });

  final List<_CategoryOption> categories;
  final Set<String> hiddenKeys;
  final void Function(String key, bool visible) onChanged;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return Text(
        emptyMessage,
        style: const TextStyle(color: Color(0xFF94A3B8)),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final category in categories)
          Semantics(
            identifier: 'video-bench.filter.${category.key}',
            button: true,
            selected: !hiddenKeys.contains(category.key),
            label: '${category.label} ${category.count}',
            child: FilterChip(
              selected: !hiddenKeys.contains(category.key),
              avatar: Icon(
                category.type == _CategoryType.object ? Icons.category : Icons.star,
                size: 16,
                color: category.type == _CategoryType.object
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFFFACC15),
              ),
              label: Text('${category.label} ${category.count}'),
              tooltip: category.type == _CategoryType.object
                  ? 'Object type: ${category.label}'
                  : 'Annotation family: ${category.label}',
              onSelected: (selected) => onChanged(category.key, selected),
            ),
          ),
      ],
    );
  }
}

class _PoiList extends StatelessWidget {
  const _PoiList({
    required this.pointsOfInterest,
    required this.annotations,
    required this.onPointSelected,
    required this.onAnnotationSelected,
  });

  final List<VideoPointOfInterest> pointsOfInterest;
  final List<BenchmarkAnnotation> annotations;
  final ValueChanged<Duration> onPointSelected;
  final ValueChanged<BenchmarkAnnotation> onAnnotationSelected;

  @override
  Widget build(BuildContext context) {
    final items = <_TimelineListItem>[
      for (final poi in pointsOfInterest) _TimelineListItem.poi(poi),
      for (final annotation in annotations) _TimelineListItem.annotation(annotation),
    ]..sort((left, right) => left.timestamp.compareTo(right.timestamp));

    if (items.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text(
          'Analyzer CSV markers and annotations will appear here.',
          style: TextStyle(color: Color(0xFF94A3B8)),
        ),
      );
    }

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        return Semantics(
          identifier: item.semanticIdentifier,
          button: true,
          label: item.label,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              final annotation = item.annotation;
              if (annotation != null) {
                onAnnotationSelected(annotation);
              } else {
                onPointSelected(item.timestamp);
              }
            },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: item.isAnnotation ? const Color(0x22FACC15) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      formatVideoTimestamp(item.timestamp),
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (item.isAnnotation) ...[
                    const Icon(Icons.star, color: Color(0xFFFACC15), size: 18),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.isAnnotation)
                    const Text('Annotation', style: TextStyle(color: Color(0xFFFACC15)))
                  else
                    Text('${(item.poi!.confidence * 100).round()}%'),
                  const SizedBox(width: 6),
                  const Icon(Icons.keyboard_arrow_right, size: 18),
                ],
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

class _TimelineListItem {
  const _TimelineListItem.poi(this.poi) : annotation = null;
  const _TimelineListItem.annotation(this.annotation) : poi = null;

  final VideoPointOfInterest? poi;
  final BenchmarkAnnotation? annotation;

  bool get isAnnotation => annotation != null;

  Duration get timestamp => annotation?.timestamp ?? poi!.timestamp;

  String get label {
    final annotation = this.annotation;
    if (annotation != null) {
      return '${annotation.id}: ${annotation.question}';
    }
    final poi = this.poi!;
    return '${poi.objectType} #${poi.objectId}';
  }

  String get semanticIdentifier {
    final annotation = this.annotation;
    if (annotation != null) {
      return 'video-bench.annotation.${annotation.id}';
    }
    final poi = this.poi!;
    return 'video-bench.poi.${poi.timestamp.inMilliseconds}.${poi.objectType}.${poi.objectId}';
  }
}

class _AnnotationDialogResult {
  const _AnnotationDialogResult.delete(this.deleteId);

  final String? deleteId;
}

class _MultipleChoiceEditor extends StatelessWidget {
  const _MultipleChoiceEditor({
    required this.choiceControllers,
    required this.selectedCorrectChoices,
    required this.onChanged,
    required this.onAddChoice,
    required this.onDeleteChoice,
  });

  final List<TextEditingController> choiceControllers;
  final Set<int> selectedCorrectChoices;
  final VoidCallback onChanged;
  final VoidCallback onAddChoice;
  final ValueChanged<int> onDeleteChoice;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Multiple-choice options',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            TextButton.icon(
              onPressed: choiceControllers.length >= 5 ? null : onAddChoice,
              icon: const Icon(Icons.add),
              label: const Text('Add choice'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (choiceControllers.isEmpty)
          const Text(
            'Add up to 5 choices. Check the correct choice numbers to fill the answer automatically.',
            style: TextStyle(color: Color(0xFF94A3B8)),
          ),
        for (var index = 0; index < choiceControllers.length; index++) ...[
          Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  '${index + 1}.',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Checkbox(
                value: selectedCorrectChoices.contains(index + 1),
                onChanged: (checked) {
                  if (checked == true) {
                    selectedCorrectChoices.add(index + 1);
                  } else {
                    selectedCorrectChoices.remove(index + 1);
                  }
                  onChanged();
                },
              ),
              Expanded(
                child: TextFormField(
                  controller: choiceControllers[index],
                  decoration: const InputDecoration(
                    labelText: 'Choice text',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => onDeleteChoice(index),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete choice ${index + 1}',
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _EvidenceVideoPreview extends StatefulWidget {
  const _EvidenceVideoPreview({
    super.key,
    required this.videoUrl,
    required this.startSeconds,
    required this.endSeconds,
    required this.duration,
    required this.onPreviousQa,
    required this.onNextQa,
  });

  final String? videoUrl;
  final double? startSeconds;
  final double? endSeconds;
  final Duration duration;
  final VoidCallback? onPreviousQa;
  final VoidCallback? onNextQa;

  @override
  State<_EvidenceVideoPreview> createState() => _EvidenceVideoPreviewState();
}

class _EvidenceVideoPreviewState extends State<_EvidenceVideoPreview> {
  static var _nextViewId = 0;

  late final String _viewType;
  late final html.DivElement _root;
  late final html.VideoElement _video;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  var _isPlaying = false;
  var _currentSeconds = 0.0;

  bool get _hasUsableRange {
    final start = widget.startSeconds;
    final end = _effectiveEndSeconds;
    return widget.videoUrl != null && start != null && end != null && start >= 0 && end > start;
  }

  double? get _effectiveEndSeconds {
    final end = widget.endSeconds;
    if (end == null) {
      return null;
    }
    final durationSeconds = widget.duration.inMilliseconds / Duration.millisecondsPerSecond;
    if (durationSeconds <= 0) {
      return end;
    }
    return math.min(end, durationSeconds);
  }

  String get _rangeLabel {
    final start = widget.startSeconds;
    final end = _effectiveEndSeconds;
    if (start == null || end == null || end <= start) {
      return 'Enter a valid evidence start and end time to preview the video section.';
    }
    return '${start.toStringAsFixed(3)}s - ${end.toStringAsFixed(3)}s';
  }

  String get _startLabel => _formatPreviewSeconds(widget.startSeconds);

  String get _endLabel => _formatPreviewSeconds(_effectiveEndSeconds);

  String get _currentLabel => _formatPreviewSeconds(_currentSeconds);

  @override
  void initState() {
    super.initState();
    _viewType = 'video-bench-evidence-preview-${_nextViewId++}';
    _root = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#020617'
      ..style.overflow = 'hidden'
      ..style.borderRadius = '18px';
    _video = html.VideoElement()
      ..controls = false
      ..preload = 'metadata'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#020617';
    _video.setAttribute('playsinline', 'true');
    _root.children.add(_video);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _root);
    _subscriptions.add(_video.onTimeUpdate.listen((_) => _handleTimeUpdate()));
    _subscriptions.add(_video.onEnded.listen((_) => _restartEvidenceSection()));
    _subscriptions.add(_video.onLoadedMetadata.listen((_) => _seekToStart()));
    _loadVideoUrl();
  }

  @override
  void didUpdateWidget(covariant _EvidenceVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoUrl != oldWidget.videoUrl) {
      _loadVideoUrl();
    }
    if (widget.startSeconds != oldWidget.startSeconds || widget.endSeconds != oldWidget.endSeconds) {
      _seekToStart();
      if (_isPlaying && _hasUsableRange) {
        _playVideo();
      }
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
    super.dispose();
  }

  void _loadVideoUrl() {
    final videoUrl = widget.videoUrl;
    _video.pause();
    _isPlaying = false;
    _currentSeconds = widget.startSeconds ?? 0;
    if (videoUrl == null || videoUrl.isEmpty) {
      _video.removeAttribute('src');
    } else {
      _video.src = videoUrl;
    }
    _video.load();
    _seekToStart();
    if (mounted) {
      setState(() {});
    }
  }

  void _seekToStart() {
    final start = widget.startSeconds;
    if (start == null || start < 0) {
      return;
    }
    try {
      _video.currentTime = start;
      _currentSeconds = start;
    } catch (_) {
      // Browser may reject seeks before metadata is available; the next play retries.
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _seekRelative(double offsetSeconds) {
    if (!_hasUsableRange) {
      return;
    }
    final start = widget.startSeconds ?? 0;
    final end = _effectiveEndSeconds ?? start;
    final target = (_video.currentTime + offsetSeconds).clamp(start, end).toDouble();
    _video.currentTime = target;
    setState(() => _currentSeconds = target);
  }

  void _handleTimeUpdate() {
    final currentTime = _video.currentTime.toDouble();
    if (mounted) {
      setState(() => _currentSeconds = currentTime);
    } else {
      _currentSeconds = currentTime;
    }
    if (!_isPlaying) {
      return;
    }
    final end = _effectiveEndSeconds;
    if (end == null || _video.currentTime < end) {
      return;
    }
    _restartEvidenceSection();
  }

  Future<void> _restartEvidenceSection() async {
    if (!_hasUsableRange) {
      setState(() => _isPlaying = false);
      return;
    }
    _seekToStart();
    await _playVideo();
  }

  Future<void> _togglePlayback() async {
    if (!_hasUsableRange) {
      return;
    }
    if (_isPlaying) {
      _video.pause();
      setState(() => _isPlaying = false);
      return;
    }
    _seekToStart();
    await _playVideo();
  }

  Future<void> _playVideo() async {
    try {
      await _video.play();
      if (mounted) {
        setState(() => _isPlaying = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isPlaying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Evidence video section', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _rangeLabel,
              style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFF020617)),
                  child: widget.videoUrl == null
                      ? const Center(child: Text('Video preview is unavailable.'))
                      : HtmlElementView(viewType: _viewType),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _PreviewTime(label: 'Start', value: _startLabel),
                const SizedBox(width: 12),
                _PreviewTime(label: 'End', value: _endLabel),
                const SizedBox(width: 12),
                _PreviewTime(label: 'Current', value: _currentLabel),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Semantics(
                  identifier: 'annotation-dialog.evidence-video-play',
                  button: true,
                  label: _isPlaying ? 'Pause evidence video' : 'Play evidence video',
                  child: FilledButton.icon(
                    onPressed: _hasUsableRange ? _togglePlayback : null,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    label: Text(_isPlaying ? 'Pause' : 'Play'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: widget.onPreviousQa,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('last QA'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: widget.onNextQa,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('next QA'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatPreviewSeconds(double? seconds) {
    if (seconds == null || seconds.isNaN || seconds.isInfinite) {
      return '--:--.---';
    }
    final safeSeconds = math.max(0, seconds);
    final totalMilliseconds = (safeSeconds * Duration.millisecondsPerSecond).round();
    final minutes = totalMilliseconds ~/ Duration.millisecondsPerMinute;
    final remainder = totalMilliseconds % Duration.millisecondsPerMinute;
    final wholeSeconds = remainder ~/ Duration.millisecondsPerSecond;
    final milliseconds = remainder % Duration.millisecondsPerSecond;
    return '${minutes.toString().padLeft(2, '0')}:${wholeSeconds.toString().padLeft(2, '0')}.${milliseconds.toString().padLeft(3, '0')}';
  }
}

class _PreviewTime extends StatelessWidget {
  const _PreviewTime({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: const Color(0xFF64748B)),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF0F172A),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnnotationDialog extends StatefulWidget {
  const _AnnotationDialog({
    required this.timestamp,
    required this.videoUrl,
    required this.videoId,
    required this.nextId,
    required this.duration,
    required this.annotations,
    required this.onSave,
    this.annotation,
  });

  final Duration timestamp;
  final String? videoUrl;
  final String videoId;
  final String nextId;
  final Duration duration;
  final List<BenchmarkAnnotation> annotations;
  final Future<void> Function(BenchmarkAnnotation annotation, String? previousId) onSave;
  final BenchmarkAnnotation? annotation;

  @override
  State<_AnnotationDialog> createState() => _AnnotationDialogState();
}

class _AnnotationDialogState extends State<_AnnotationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _previewKey = GlobalKey<_EvidenceVideoPreviewState>();
  StreamSubscription<html.KeyboardEvent>? _keyboardSubscription;
  late final TextEditingController _idController;
  late final TextEditingController _videoIdController;
  late final TextEditingController _questionController;
  late final TextEditingController _answerController;
  late final TextEditingController _aliasesController;
  late final TextEditingController _startSecondsController;
  late final TextEditingController _endSecondsController;
  late final TextEditingController _evidenceDescriptionController;
  final _choiceControllers = <TextEditingController>[];
  String _answerFormat = 'open_ended';
  String _family = 'object_attribute';
  String _difficulty = 'medium';
  String _visibility = 'clear';
  String _dayNight = 'unknown';
  var _selectedReasoningTypes = <String>{'perception'};
  var _selectedCorrectChoices = <int>{};
  var _unanswerable = false;
  late List<BenchmarkAnnotation> _chronologicalAnnotations;
  BenchmarkAnnotation? _activeAnnotation;
  BenchmarkAnnotation? _savedAnnotationSnapshot;
  var _loadingAnnotation = false;
  var _saving = false;

  bool get _isEditing => _activeAnnotation != null;
  bool get _isMultipleChoice => _answerFormat == 'multiple_choice';
  int get _activeAnnotationIndex {
    final annotation = _activeAnnotation;
    if (annotation == null) {
      return -1;
    }
    return _chronologicalAnnotations.indexWhere((item) => item.id == annotation.id);
  }

  bool get _canNavigatePrevious => _activeAnnotationIndex > 0;
  bool get _canNavigateNext {
    final index = _activeAnnotationIndex;
    return index >= 0 && index < _chronologicalAnnotations.length - 1;
  }

  @override
  void initState() {
    super.initState();
    _chronologicalAnnotations = [...widget.annotations]
      ..sort((a, b) {
        final timeCompare = a.timestamp.compareTo(b.timestamp);
        if (timeCompare != 0) {
          return timeCompare;
        }
        return a.id.compareTo(b.id);
      });
    _activeAnnotation = widget.annotation;
    _idController = TextEditingController();
    _videoIdController = TextEditingController();
    _questionController = TextEditingController();
    _answerController = TextEditingController();
    _aliasesController = TextEditingController();
    _startSecondsController = TextEditingController();
    _endSecondsController = TextEditingController();
    _startSecondsController.addListener(_handleEvidenceRangeChanged);
    _endSecondsController.addListener(_handleEvidenceRangeChanged);
    _evidenceDescriptionController = TextEditingController();
    for (final controller in [
      _idController,
      _videoIdController,
      _questionController,
      _answerController,
      _aliasesController,
      _evidenceDescriptionController,
    ]) {
      controller.addListener(_handleFormChanged);
    }
    _keyboardSubscription = html.window.onKeyDown.listen(_handleDialogKeyDown);
    _loadAnnotationIntoForm(_activeAnnotation);
  }

  @override
  void dispose() {
    _keyboardSubscription?.cancel();
    _startSecondsController.removeListener(_handleEvidenceRangeChanged);
    for (final controller in [
      _idController,
      _videoIdController,
      _questionController,
      _answerController,
      _aliasesController,
      _evidenceDescriptionController,
    ]) {
      controller.removeListener(_handleFormChanged);
    }
    _endSecondsController.removeListener(_handleEvidenceRangeChanged);
    _idController.dispose();
    _videoIdController.dispose();
    _questionController.dispose();
    _answerController.dispose();
    _aliasesController.dispose();
    _startSecondsController.dispose();
    _endSecondsController.dispose();
    _evidenceDescriptionController.dispose();
    for (final controller in _choiceControllers) {
      _disposeChoiceController(controller);
    }
    super.dispose();
  }

  void _handleEvidenceRangeChanged() {
    if (_loadingAnnotation) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleFormChanged() {
    if (_loadingAnnotation || !mounted) {
      return;
    }
    setState(() {});
  }

  void _handleDialogKeyDown(html.KeyboardEvent event) {
    if (_isDialogTextInputFocused()) {
      return;
    }
    if (event.code == 'KeyD') {
      event.preventDefault();
      if (_canNavigatePrevious) {
        _navigateToAnnotation(-1);
      }
      return;
    }
    if (event.code == 'KeyF') {
      event.preventDefault();
      if (_canNavigateNext) {
        _navigateToAnnotation(1);
      }
      return;
    }
    if (event.code == 'KeyS') {
      event.preventDefault();
      if (_canSave) {
        unawaited(_save());
      }
      return;
    }
    if (event.code == 'Space') {
      event.preventDefault();
      final preview = _previewKey.currentState;
      if (preview != null) {
        unawaited(preview._togglePlayback());
      }
      return;
    }
    if (event.code == 'ArrowLeft') {
      event.preventDefault();
      _seekEvidenceRelative(-0.5);
      return;
    }
    if (event.code == 'ArrowRight') {
      event.preventDefault();
      _seekEvidenceRelative(0.5);
    }
  }

  bool _isDialogTextInputFocused() {
    final element = html.document.activeElement;
    final tagName = element?.tagName.toLowerCase();
    return tagName == 'input' ||
        tagName == 'textarea' ||
        tagName == 'select' ||
        element?.isContentEditable == true;
  }

  void _seekEvidenceRelative(double offsetSeconds) {
    _previewKey.currentState?._seekRelative(offsetSeconds);
  }

  void _loadAnnotationIntoForm(BenchmarkAnnotation? annotation) {
    _loadingAnnotation = true;
    final span = annotation?.evidenceSpans.isNotEmpty == true
        ? annotation!.evidenceSpans.first
        : null;
    final seconds = _secondsText(widget.timestamp);
    for (final controller in _choiceControllers) {
      _disposeChoiceController(controller);
    }
    _choiceControllers.clear();
    _idController.text = annotation?.id ?? widget.nextId;
    _videoIdController.text = annotation?.videoId ?? widget.videoId;
    _questionController.text = annotation?.question ?? '';
    _answerController.text = annotation?.answer?.toString() ?? '';
    _aliasesController.text = annotation?.answerAliases.join(', ') ?? '';
    _startSecondsController.text = span == null ? seconds : span.startSeconds.toStringAsFixed(3);
    _endSecondsController.text = span == null ? seconds : span.endSeconds.toStringAsFixed(3);
    _evidenceDescriptionController.text = span?.description ?? '';
    _answerFormat = annotation?.answerFormat ?? 'open_ended';
    _family = annotation?.family ?? 'object_attribute';
    _difficulty = annotation?.difficulty ?? 'medium';
    _visibility = annotation?.visibility ?? 'clear';
    _dayNight = annotation?.dayNight ?? 'unknown';
    _selectedReasoningTypes = annotation == null ? <String>{'perception'} : annotation.reasoningTypes.toSet();
    _unanswerable = annotation?.unanswerable ?? false;
    for (final choice in annotation?.choices ?? const <String>[]) {
      _choiceControllers.add(_newChoiceController(text: choice));
    }
    _selectedCorrectChoices = _parseCorrectChoices(annotation?.answer).toSet();
    _syncMultipleChoiceAnswer();
    _savedAnnotationSnapshot = _annotationFromForm();
    _loadingAnnotation = false;
  }

  void _navigateToAnnotation(int offset) {
    final currentIndex = _activeAnnotationIndex;
    if (currentIndex < 0) {
      return;
    }
    final nextIndex = currentIndex + offset;
    if (nextIndex < 0 || nextIndex >= _chronologicalAnnotations.length) {
      return;
    }
    setState(() {
      _activeAnnotation = _chronologicalAnnotations[nextIndex];
      _loadAnnotationIntoForm(_activeAnnotation);
    });
  }

  TextEditingController _newChoiceController({String text = ''}) {
    final controller = TextEditingController(text: text);
    controller.addListener(_handleFormChanged);
    return controller;
  }

  void _disposeChoiceController(TextEditingController controller) {
    controller.removeListener(_handleFormChanged);
    controller.dispose();
  }

  bool get _canSave => !_saving && _hasFormUpdates;

  bool get _hasFormUpdates {
    final current = _annotationFromForm();
    final saved = _savedAnnotationSnapshot;
    if (current == null || saved == null) {
      return false;
    }
    return !_annotationsEqual(current, saved);
  }

  BenchmarkAnnotation? _annotationFromForm() {
    final start = double.tryParse(_startSecondsController.text.trim());
    final end = double.tryParse(_endSecondsController.text.trim());
    if (start == null || end == null) {
      return null;
    }
    return BenchmarkAnnotation(
      id: _idController.text.trim(),
      videoId: _videoIdController.text.trim(),
      question: _questionController.text.trim(),
      answer: _unanswerable ? null : _parseAnswer(_answerController.text.trim()),
      answerFormat: _answerFormat,
      family: _family,
      reasoningTypes: _selectedReasoningTypes.toList()..sort(),
      difficulty: _difficulty,
      visibility: _visibility,
      dayNight: _dayNight,
      evidenceSpans: [
        EvidenceSpan(
          startSeconds: start,
          endSeconds: end,
          description: _emptyToNull(_evidenceDescriptionController.text),
        ),
      ],
      trajectoryLinkage: null,
      choices: _isMultipleChoice ? _choiceTexts() : const [],
      answerAliases: _csvList(_aliasesController.text),
      unanswerable: _unanswerable,
    );
  }

  bool _annotationsEqual(BenchmarkAnnotation left, BenchmarkAnnotation right) {
    return jsonEncode(left.toJson()) == jsonEncode(right.toJson());
  }

  double? get _previewStartSeconds => double.tryParse(_startSecondsController.text.trim());

  double? get _previewEndSeconds => double.tryParse(_endSecondsController.text.trim());

  @override
  Widget build(BuildContext context) {
    final startSeconds = _previewStartSeconds;
    final endSeconds = _previewEndSeconds;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit annotation' : 'Add annotation'),
          actions: [
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
              tooltip: 'Close',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 980;
                    final preview = _EvidenceVideoPreview(
                        key: _previewKey,
                        videoUrl: widget.videoUrl,
                        startSeconds: startSeconds,
                        endSeconds: endSeconds,
                        duration: widget.duration,
                        onPreviousQa: _canNavigatePrevious ? () => _navigateToAnnotation(-1) : null,
                        onNextQa: _canNavigateNext ? () => _navigateToAnnotation(1) : null,
                      );
                    final compactPreview = SizedBox(
                      width: double.infinity,
                      height: 340,
                      child: preview,
                    );
                    final form = Expanded(
                      child: Form(
                        key: _formKey,
                        child: ListView(
                          children: [
                            Row(
                              children: [
                                Expanded(child: _textField(_idController, 'ID')),
                                const SizedBox(width: 12),
                                Expanded(child: _textField(_videoIdController, 'Video ID')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _textField(_questionController, 'Question', maxLines: 2),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: _dropdown(
                                    'Answer format',
                                    _answerFormat,
                                    answerFormats,
                                    (value) => setState(() {
                                      _answerFormat = value;
                                      if (_isMultipleChoice) {
                                        _syncMultipleChoiceAnswer();
                                      }
                                    }),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: _dropdown('Family', _family, qaFamilies, (value) => setState(() => _family = value))),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(child: _dropdown('Difficulty', _difficulty, difficultyLevels, (value) => setState(() => _difficulty = value))),
                                const SizedBox(width: 12),
                                Expanded(child: _dropdown('Visibility', _visibility, visibilityQualities, (value) => setState(() => _visibility = value))),
                                const SizedBox(width: 12),
                                Expanded(child: _dropdown('Day/night', _dayNight, dayNightTags, (value) => setState(() => _dayNight = value))),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Unanswerable'),
                              value: _unanswerable,
                              onChanged: (value) => setState(() => _unanswerable = value),
                            ),
                            _textField(
                              _answerController,
                              _isMultipleChoice
                                  ? 'Correct answer'
                                  : _unanswerable
                                      ? 'Answer (ignored for unanswerable)'
                                      : 'Answer',
                              requiredField: !_unanswerable && !_isMultipleChoice,
                              enabled: !_isMultipleChoice,
                            ),
                            if (_isMultipleChoice) ...[
                              const SizedBox(height: 12),
                              _MultipleChoiceEditor(
                                choiceControllers: _choiceControllers,
                                selectedCorrectChoices: _selectedCorrectChoices,
                                onChanged: () {
                                  setState(_syncMultipleChoiceAnswer);
                                },
                                onAddChoice: _addChoice,
                                onDeleteChoice: _deleteChoice,
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text('Reasoning types', style: Theme.of(context).textTheme.labelLarge),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final type in reasoningTypes)
                                  FilterChip(
                                    label: Text(type),
                                    selected: _selectedReasoningTypes.contains(type),
                                    onSelected: (selected) {
                                      setState(() {
                                        if (selected) {
                                          _selectedReasoningTypes.add(type);
                                        } else {
                                          _selectedReasoningTypes.remove(type);
                                        }
                                      });
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(child: _numberField(_startSecondsController, 'Evidence start seconds')),
                                const SizedBox(width: 12),
                                Expanded(child: _numberField(_endSecondsController, 'Evidence end seconds')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _textField(_evidenceDescriptionController, 'Evidence description', maxLines: 2, requiredField: false),
                            const SizedBox(height: 12),
                            _textField(_aliasesController, 'Answer aliases, comma-separated', requiredField: false),
                          ],
                        ),
                      ),
                    );

                    if (compact) {
                      return Column(
                        children: [
                          compactPreview,
                          const SizedBox(height: 20),
                          form,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: preview),
                        const SizedBox(width: 20),
                        form,
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_isEditing)
                    Semantics(
                      identifier: 'annotation-dialog.delete',
                      button: true,
                      label: 'Delete annotation',
                      child: TextButton.icon(
                        onPressed: _delete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete annotation'),
                      ),
                    ),
                  const Spacer(),
                  Semantics(
                    identifier: 'annotation-dialog.cancel',
                    button: true,
                    label: 'Cancel',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    identifier: 'annotation-dialog.save',
                    button: true,
                    enabled: _canSave,
                    label: _isEditing ? 'Save changes' : 'Save annotation',
                    child: FilledButton.icon(
                      onPressed: _canSave ? _save : null,
                      icon: const Icon(Icons.save),
                      label: Text(_saving
                          ? 'Saving...'
                          : _isEditing
                              ? 'Save changes'
                              : 'Save annotation'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    bool requiredField = true,
    bool enabled = true,
  }) {
    return Semantics(
      identifier: 'annotation-dialog.${_semanticIdForLabel(label)}',
      textField: true,
      enabled: enabled,
      label: label,
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        validator: requiredField
            ? (value) => value == null || value.trim().isEmpty ? '$label is required.' : null
            : null,
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
    return Semantics(
      identifier: 'annotation-dialog.${_semanticIdForLabel(label)}',
      textField: true,
      label: label,
      child: TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        validator: (value) {
          final number = double.tryParse(value ?? '');
          if (number == null || number < 0) {
            return '$label must be non-negative.';
          }
          return null;
        },
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> onChanged,
  ) {
    return Semantics(
      identifier: 'annotation-dialog.${_semanticIdForLabel(label)}',
      label: label,
      child: DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [
          for (final item in values)
            DropdownMenuItem(value: item, child: Text(item, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (value) {
          if (value != null) {
            onChanged(value);
          }
        },
      ),
    );
  }

  String _semanticIdForLabel(String label) {
    return label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  Future<void> _save() async {
    if (!_canSave) {
      return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_selectedReasoningTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one reasoning type.')),
      );
      return;
    }

    if (_isMultipleChoice && !_unanswerable) {
      final choices = _choiceTexts();
      if (choices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least one multiple-choice option.')),
        );
        return;
      }
      if (choices.length != _choiceControllers.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fill every multiple-choice option or delete empty choices.')),
        );
        return;
      }
      if (_selectedCorrectChoices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one correct choice.')),
        );
        return;
      }
    }

    final start = double.parse(_startSecondsController.text.trim());
    final end = double.parse(_endSecondsController.text.trim());
    if (end < start) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Evidence end seconds must be >= start seconds.')),
      );
      return;
    }
    if (widget.duration > Duration.zero && start > widget.duration.inMilliseconds / Duration.millisecondsPerSecond) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Evidence start is outside the video duration.')),
      );
      return;
    }

    final annotation = _annotationFromForm();
    if (annotation == null) {
      return;
    }

    final previousId = _activeAnnotation?.id;
    setState(() => _saving = true);
    try {
      await widget.onSave(annotation, previousId);
      if (!mounted) {
        return;
      }
      setState(() {
        _activeAnnotation = annotation;
        final index = _chronologicalAnnotations.indexWhere((item) => item.id == (previousId ?? annotation.id));
        if (index >= 0) {
          _chronologicalAnnotations[index] = annotation;
        } else {
          _chronologicalAnnotations.add(annotation);
        }
        _chronologicalAnnotations.sort((a, b) {
          final timeCompare = a.timestamp.compareTo(b.timestamp);
          if (timeCompare != 0) {
            return timeCompare;
          }
          return a.id.compareTo(b.id);
        });
        _savedAnnotationSnapshot = annotation;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved annotation ${annotation.id}.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save annotation: $error')),
      );
    }
  }

  void _delete() {
    final id = _activeAnnotation?.id;
    if (id == null) {
      return;
    }
    Navigator.of(context).pop(_AnnotationDialogResult.delete(id));
  }

  dynamic _parseAnswer(String value) {
    switch (_answerFormat) {
      case 'yes_no':
        final lower = value.toLowerCase();
        if (lower == 'yes' || lower == 'true') {
          return true;
        }
        if (lower == 'no' || lower == 'false') {
          return false;
        }
        return value;
      case 'numeric':
        return num.tryParse(value) ?? value;
      case 'multiple_choice':
        return _correctChoiceAnswerText();
      default:
        return value;
    }
  }

  void _addChoice() {
    if (_choiceControllers.length >= 5) {
      return;
    }
    setState(() {
      _choiceControllers.add(_newChoiceController());
      _syncMultipleChoiceAnswer();
    });
  }

  void _deleteChoice(int index) {
    setState(() {
      _disposeChoiceController(_choiceControllers.removeAt(index));
      _selectedCorrectChoices = {
        for (final selected in _selectedCorrectChoices)
          if (selected != index + 1)
            selected > index + 1 ? selected - 1 : selected,
      };
      _syncMultipleChoiceAnswer();
    });
  }

  void _syncMultipleChoiceAnswer() {
    if (!_isMultipleChoice) {
      return;
    }
    _selectedCorrectChoices.removeWhere((value) => value < 1 || value > _choiceControllers.length);
    _answerController.text = _correctChoiceAnswerText();
  }

  String _correctChoiceNumbersText() {
    final selected = _selectedCorrectChoices.toList()..sort();
    return selected.join(',');
  }

  String _correctChoiceAnswerText() {
    final choices = _choiceTexts();
    final selected = _selectedCorrectChoices.toList()..sort();
    final selectedTexts = [
      for (final index in selected)
        if (index >= 1 && index <= choices.length) choices[index - 1],
    ];
    return selectedTexts.isEmpty ? _correctChoiceNumbersText() : selectedTexts.join(', ');
  }

  List<String> _choiceTexts() => _choiceControllers
      .map((controller) => controller.text.trim())
      .where((choice) => choice.isNotEmpty)
      .toList(growable: false);

  List<int> _parseCorrectChoices(dynamic answer) {
    if (answer == null) {
      return const [];
    }
    if (answer is num) {
      return [answer.toInt()];
    }
    final rawParts = answer
        .toString()
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final numericChoices = rawParts
        .map(int.tryParse)
        .whereType<int>()
        .where((value) => value >= 1 && value <= 5)
        .toList(growable: false);
    if (numericChoices.isNotEmpty) {
      return numericChoices;
    }
    final normalizedChoices = [
      for (final choice in _choiceTexts()) _normalizeMultipleChoiceAnswer(choice),
    ];
    return rawParts
        .map(_normalizeMultipleChoiceAnswer)
        .map((answerText) => normalizedChoices.indexOf(answerText))
        .where((index) => index >= 0)
        .map((index) => index + 1)
        .toList(growable: false);
  }

  String _normalizeMultipleChoiceAnswer(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<String> _csvList(String value) => value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _secondsText(Duration duration) {
    final seconds = duration.inMilliseconds / Duration.millisecondsPerSecond;
    return seconds.toStringAsFixed(3);
  }
}

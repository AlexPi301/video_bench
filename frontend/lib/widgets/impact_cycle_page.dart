import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';

import '../models/impact_cycle_models.dart';
import '../models/video_report.dart';
import '../services/devtools_agent_bridge.dart';
import '../services/impact_cycle_client.dart';
import '../services/mounted_files_client.dart';
import 'mounted_file_browser_dialog.dart';
import 'timeline_bar.dart';
import 'web_video_surface.dart';

class ImpactCyclePage extends StatefulWidget {
  const ImpactCyclePage({super.key, this.client = const ImpactCycleClient()});

  final ImpactCycleClient client;

  @override
  State<ImpactCyclePage> createState() => _ImpactCyclePageState();
}

class _ImpactCyclePageState extends State<ImpactCyclePage> {
  final _videoController = VideoSurfaceController();
  final _mountedFilesClient = const MountedFilesClient();
  DropzoneViewController? _dropzoneController;
  Timer? _pollTimer;
  Timer? _statusTimer;
  ImpactCycleJob? _job;
  ImpactCycleBundle? _bundle;
  List<ImpactCycleJob> _jobs = const [];
  List<ImpactCycleActivity> _activities = const [];
  var _eventCursor = 0;
  var _sourceType = '';
  var _sourcePath = '';
  var _videoName = '';
  var _videoUrl = '';
  var _status = 'Select a video from upload or the mounted input volume.';
  String? _error;
  var _samplingFps = 1.0;
  var _maxFrames = 3;
  var _backendProvider = 'sam3';
  var _isUploading = false;
  var _showBoundingBoxes = true;
  var _metaDirectory = '';
  final _metadataFiles = <String, bool>{
    'scene_graph_bundle.json': false,
    'vqa.json': false,
    'tracking_results.json': false,
    'cycle_results.json': false,
  };
  var _workflowBundlePath = '';
  var _vqaPath = '';
  var _cyclePath = '';
  var _sceneGraphGtPath = '';
  var _vqaGtPath = '';
  final _events = <ImpactCycleEvent>[];

  @override
  void initState() {
    super.initState();
    _registerAgentHooks();
    _videoController.addListener(_handleVideoUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDebugSessionIfEnabled();
      _refreshStatusPanels();
    });
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStatusPanels());
  }

  @override
  void dispose() {
    DevtoolsAgentBridge.instance.unregisterOwner(this);
    _pollTimer?.cancel();
    _statusTimer?.cancel();
    _videoController.removeListener(_handleVideoUpdate);
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ImpactHeader(
                  status: _status,
                  failedActivityCount: _activities.where((activity) => activity.isFailure).length,
                  runningJobCount: _jobs.where((job) => job.isRunning).length,
                  onShowActivities: _showActivities,
                  onShowJobs: _showJobs,
                ),
                const SizedBox(height: 22),
                Expanded(child: _buildResponsiveBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerCard() {
    final points = _bundle?.pointsOfInterest ?? const [];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(color: const Color(0xFF020617), borderRadius: BorderRadius.circular(18)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      WebVideoSurface(controller: _videoController),
                      if (!_videoController.hasVideo) const _EmptyImpactVideoState(),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TimelineBar(
              duration: _videoController.duration,
              position: _videoController.position,
              pointsOfInterest: points,
              onSeek: _videoController.seekTo,
            ),
            Row(
              children: [
                Semantics(
                  identifier: 'impact-cycle.playback.play-pause',
                  button: true,
                  enabled: _videoController.hasVideo,
                  label: _videoController.isPlaying ? 'Pause video' : 'Play video',
                  child: IconButton.filledTonal(
                    onPressed: _videoController.hasVideo ? _togglePlayback : null,
                    icon: Icon(_videoController.isPlaying ? Icons.pause : Icons.play_arrow),
                  ),
                ),
                const SizedBox(width: 10),
                Text('${formatVideoTimestamp(_videoController.position)} / ${formatVideoTimestamp(_videoController.duration)}'),
                const Spacer(),
                Chip(label: Text('${points.length} overlays')),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Boxes'),
                    Semantics(
                      identifier: 'impact-cycle.bounding-boxes-visible',
                      toggled: _showBoundingBoxes,
                      label: 'Boxes',
                      child: Switch.adaptive(
                        value: _showBoundingBoxes,
                        onChanged: _setShowBoundingBoxes,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _setShowBoundingBoxes(bool value) {
    setState(() => _showBoundingBoxes = value);
    _videoController.setBoundingBoxesVisible(value);
  }

  Widget _buildResponsiveBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 920) {
          return ListView(
            children: [
              SizedBox(height: 430, child: _buildPlayerCard()),
              const SizedBox(height: 18),
              SizedBox(height: 1120, child: _buildControlPanel()),
            ],
          );
        }
        return ListView(
          children: [
            SizedBox(
              height: constraints.maxHeight < 980 ? 980 : constraints.maxHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildPlayerCard()),
                  const SizedBox(width: 22),
                  SizedBox(width: 430, child: _buildControlPanel()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControlPanel() {
    final job = _job;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              Text('Impact Cycle SAM3', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            _buildDropZone(),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: Semantics(
                identifier: 'impact-cycle.open-mounted-volume',
                button: true,
                label: 'Browse mounted volume',
                child: FilledButton.tonalIcon(
                  onPressed: _openMountedFilesDialog,
                  icon: const Icon(Icons.folder_copy),
                  label: const Text('Browse mounted volume'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _InfoLine(label: 'Video', value: _videoName.isEmpty ? 'No video selected' : _videoName),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Sampling FPS',
                    value: _samplingFps.toString(),
                    onChanged: (value) => _samplingFps = double.tryParse(value) ?? _samplingFps,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _NumberField(
                    label: 'Max frames',
                    value: _maxFrames.toString(),
                    onChanged: (value) => _maxFrames = int.tryParse(value) ?? _maxFrames,
                  ),
                ),
              ],
            ),
            if (job?.isRunning == true) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: Semantics(
                  identifier: 'impact-cycle.cancel-job',
                  button: true,
                  label: 'Cancel running job',
                  child: OutlinedButton.icon(
                    onPressed: _cancelJob,
                    icon: const Icon(Icons.stop),
                    label: const Text('Cancel running job'),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (job != null) _JobProgress(job: job),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ErrorPanel(message: _error!),
            ],
            const SizedBox(height: 16),
            Text('Results', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _BundleSummary(bundle: _bundle),
            const SizedBox(height: 16),
            _buildWorkflowPanel(),
            const SizedBox(height: 16),
            Text('Live log', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(child: _EventLog(events: _events)),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflowPanel() {
    final running = _job?.isRunning == true;
    final hasSceneGraph = _metadataFiles['scene_graph_bundle.json'] == true;
    final hasTracking = _metadataFiles['tracking_results.json'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Main workflow', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_metaDirectory.isEmpty)
          Text('Select a mounted video to use its sibling *_meta directory.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)))
        else
          _InfoLine(label: 'Metadata dir', value: _metaDirectory),
        const SizedBox(height: 10),
        _MetadataChecklistRow(
          filename: 'scene_graph_bundle.json',
          exists: hasSceneGraph,
          buttonLabel: 'Compute Sam3 detections',
          onPressed: !running && _canStart && _metaDirectory.isNotEmpty ? _startSam3MetadataJob : null,
        ),
        const SizedBox(height: 8),
        _MetadataChecklistRow(
          filename: 'vqa.json',
          exists: _metadataFiles['vqa.json'] == true,
          buttonLabel: 'Compute VQA',
          onPressed: !running && hasSceneGraph ? () => _startWorkflowOperation('vqa_generate') : null,
        ),
        const SizedBox(height: 8),
        _MetadataChecklistRow(
          filename: 'tracking_results.json',
          exists: hasTracking,
          buttonLabel: 'Compute tracking',
          onPressed: !running && hasSceneGraph ? () => _startWorkflowOperation('track_objects') : null,
        ),
        const SizedBox(height: 8),
        _MetadataChecklistRow(
          filename: 'cycle_results.json',
          exists: _metadataFiles['cycle_results.json'] == true,
          buttonLabel: 'Compute cycle results',
          onPressed: !running && hasSceneGraph && hasTracking ? () => _startWorkflowOperation('cycle_verify') : null,
        ),
      ],
    );
  }

  Widget _buildDropZone() {
    return SizedBox(
      height: 118,
      child: Stack(
        children: [
          DropzoneView(
            operation: DragOperation.copy,
            cursor: CursorType.grab,
            onCreated: (controller) => _dropzoneController = controller,
            onDropFiles: (files) async {
              if (files == null || files.isEmpty) {
                return;
              }
              await _uploadFile(files.first);
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF334155)),
                  gradient: const LinearGradient(colors: [Color(0x1822D3EE), Color(0x102DD4BF)]),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        Icon(_isUploading ? Icons.hourglass_top : Icons.upload_file, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _isUploading ? 'Uploading video...' : 'Drop a video here, or use mounted volume browsing.',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _canStart => _sourceType.isNotEmpty && _sourcePath.isNotEmpty && (_job?.isRunning != true) && !_isUploading;

  Future<void> _uploadFile(dynamic file) async {
    setState(() {
      _isUploading = true;
      _error = null;
      _status = 'Uploading video for Impact Cycle...';
    });
    try {
      final upload = await widget.client.uploadVideo(file);
      _selectVideo(sourceType: 'upload', sourcePath: upload.path, videoUrl: upload.url, videoName: upload.filename);
      setState(() => _status = 'Uploaded ${upload.filename}. Ready to generate metadata.');
    } catch (error) {
      setState(() {
        _error = 'Upload failed: $error';
        _status = 'Upload failed.';
      });
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _openMountedFilesDialog() async {
    final selection = await showDialog<MountedFileSelection>(
      context: context,
      builder: (context) => MountedFileBrowserDialog(client: _mountedFilesClient),
    );
    if (selection == null || selection.video.url == null) {
      return;
    }
    _selectVideo(sourceType: 'mounted', sourcePath: selection.video.path, videoUrl: selection.video.url!, videoName: selection.video.path);
    final metadata = selection.metadata;
    if (metadata != null) {
      _workflowBundlePath = metadata.path;
      await _loadMountedMetadata(metadata.path);
    } else {
      setState(() => _status = 'Mounted video selected. Ready to precompute SAM3 detections.');
    }
    await _refreshMetadataFiles();
  }

  void _selectVideo({required String sourceType, required String sourcePath, required String videoUrl, required String videoName}) {
    _pollTimer?.cancel();
    _sourceType = sourceType;
    _sourcePath = sourcePath;
    _videoName = videoName;
    _videoUrl = videoUrl;
    _job = null;
    _bundle = null;
    _metaDirectory = sourceType == 'mounted' ? _metadataDirectoryForVideo(sourcePath) : '';
    _workflowBundlePath = _metaDirectory.isEmpty ? '' : '$_metaDirectory/scene_graph_bundle.json';
    _vqaPath = _metaDirectory.isEmpty ? '' : '$_metaDirectory/vqa.json';
    _cyclePath = _metaDirectory.isEmpty ? '' : '$_metaDirectory/cycle_results.json';
    for (final filename in _metadataFiles.keys) {
      _metadataFiles[filename] = false;
    }
    _events.clear();
    _eventCursor = 0;
    _videoController.loadVideoUrl(videoUrl);
    _videoController.setPointsOfInterest(const []);
  }

  Future<void> _startSam3MetadataJob() async {
    await _startJob(outputDirectory: _metaDirectory);
  }

  Future<void> _startJob({required String outputDirectory}) async {
    setState(() {
      _error = null;
      _bundle = null;
      _events.clear();
      _eventCursor = 0;
      _status = 'Starting SAM3 detection precompute...';
    });
    try {
      final job = await widget.client.createJob(
        sourceType: _sourceType,
        sourcePath: _sourcePath,
        outputDirectory: outputDirectory,
        samplingFps: _samplingFps,
        maxFrames: _maxFrames,
        backendProvider: _backendProvider,
        directOutput: true,
      );
      setState(() => _job = job);
      unawaited(_refreshStatusPanels());
      _startPolling(job.id);
    } catch (error) {
      setState(() {
        _error = 'Could not start SAM3 precompute: $error';
        _status = 'Impact Cycle start failed.';
      });
    }
  }

  void _startPolling(String jobId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollJob(jobId));
    unawaited(_pollJob(jobId));
  }

  Future<void> _pollJob(String jobId) async {
    try {
      final job = await widget.client.getJob(jobId);
      final eventsPage = await widget.client.getEvents(jobId, _eventCursor);
      if (!mounted) {
        return;
      }
      setState(() {
        _job = job;
        _eventCursor = eventsPage.next;
        _events.addAll(eventsPage.events);
        _status = _statusFor(job);
        if (job.error.isNotEmpty) {
          _error = job.error;
        }
      });
      if (!job.isRunning) {
        _pollTimer?.cancel();
        if (job.isCompleted) {
          await _loadBundle(job.id);
          await _refreshMetadataFiles();
        }
      } else if (job.bundleUrl != null) {
        await _loadBundle(job.id, quiet: true);
      }
      unawaited(_refreshStatusPanels());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Polling failed: $error');
    }
  }

  Future<void> _loadBundle(String jobId, {bool quiet = false}) async {
    try {
      final bundle = await widget.client.getBundle(jobId);
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _videoController.setPointsOfInterest(bundle.pointsOfInterest);
        if (!quiet) {
          _status = 'SAM3 detections loaded: ${bundle.graphs.length} frame(s), ${bundle.pointsOfInterest.length} overlay(s).';
        }
      });
    } catch (error) {
      if (!quiet) {
        setState(() => _error = 'Could not load generated bundle: $error');
      }
    }
  }

  Future<void> _loadMountedMetadata(String path, {bool refreshFiles = true}) async {
    try {
      final bundle = await widget.client.getMountedBundle(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _workflowBundlePath = path;
        _metaDirectory = _directoryOf(path);
        _vqaPath = '$_metaDirectory/vqa.json';
        _cyclePath = '$_metaDirectory/cycle_results.json';
        _videoController.setPointsOfInterest(bundle.pointsOfInterest);
        _status = 'Loaded metadata: ${bundle.graphs.length} frame(s), ${bundle.pointsOfInterest.length} overlay(s).';
      });
      if (refreshFiles) {
        await _refreshMetadataFiles();
      }
    } catch (error) {
      setState(() {
        _error = 'Could not load mounted metadata: $error';
        _status = 'Mounted metadata loading failed.';
      });
    }
  }

  Future<void> _startWorkflowOperation(String operation) async {
    final bundlePath = _workflowBundlePath.trim();
    final outputDirectory = _metaDirectory.isNotEmpty ? _metaDirectory : _directoryOf(bundlePath.isNotEmpty ? bundlePath : _sourcePath);
    try {
      setState(() {
        _error = null;
        _events.clear();
        _eventCursor = 0;
        _status = 'Starting Impact Cycle workflow: $operation...';
      });
      final inputs = <String, String>{};
      if (operation == 'vqa_generate' || operation == 'track_objects' || operation == 'cycle_verify') {
        inputs['bundlePath'] = bundlePath;
        inputs['videoPath'] = _sourcePath;
      } else if (operation == 'scene_graph_eval') {
        inputs['predPath'] = bundlePath;
        inputs['gtPath'] = _sceneGraphGtPath.trim();
      } else if (operation == 'vqa_eval') {
        inputs['predPath'] = _vqaPath.trim();
        inputs['gtPath'] = _vqaGtPath.trim();
      }
      final request = await html.HttpRequest.request(
        '/api/impact-cycle/jobs/',
        method: 'POST',
        requestHeaders: {'Content-Type': 'application/json'},
        sendData: jsonEncode({
          'operation': operation,
          'inputs': inputs,
          'settings': {
            'outputDirectory': outputDirectory,
            'directOutput': true,
            'rounds': 1,
            'lowQuota': true,
            'maxFrames': _maxFrames,
          },
        }),
      );
      final json = jsonDecode(request.responseText ?? '{}') as Map<String, dynamic>;
      final job = ImpactCycleJob.fromJson(json);
      final outputPath = json['output_path']?.toString() ?? '';
      if (outputPath.isNotEmpty) {
        if (operation == 'vqa_generate') {
          _vqaPath = '$outputPath/vqa.json';
        } else if (operation == 'cycle_verify') {
          _cyclePath = '$outputPath/cycle_results.json';
        }
      }
      setState(() => _job = job);
      unawaited(_refreshStatusPanels());
      _startPolling(job.id);
    } catch (error) {
      setState(() {
        _error = 'Could not start workflow operation: $error';
        _status = 'Impact Cycle workflow start failed.';
      });
    }
  }

  Future<void> _cancelJob() async {
    final job = _job;
    if (job == null) {
      return;
    }
    await widget.client.cancelJob(job.id);
    _pollTimer?.cancel();
    await _pollJob(job.id);
    await _refreshStatusPanels();
  }

  Future<void> _refreshStatusPanels() async {
    try {
      final results = await Future.wait<dynamic>([widget.client.listJobs(), widget.client.getActivities()]);
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
        _activities = const [ImpactCycleActivity(type: 'frontend', status: 'failed', message: 'Could not refresh jobs or activities.', jobId: '')];
      });
    }
  }

  Future<void> _loadDebugSessionIfEnabled() async {
    try {
      final configText = await html.HttpRequest.getString('/debug-config.json');
      final config = jsonDecode(configText) as Map<String, dynamic>;
      if (config['enabled'] != true) {
        return;
      }
      final videoUrl = config['videoUrl']?.toString();
      final sourceType = config['impactSourceType']?.toString() ?? 'mounted';
      final sourcePath = config['impactSourcePath']?.toString() ?? 'airport_walk/airport_walk_normal.mov';
      if (videoUrl == null || videoUrl.isEmpty) {
        return;
      }
      _selectVideo(
        sourceType: sourceType,
        sourcePath: sourcePath,
        videoUrl: videoUrl,
        videoName: config['videoFilename']?.toString() ?? videoUrl.split('/').last,
      );
      if (mounted) {
        setState(() => _status = 'Debug mode loaded: ${config['videoFilename'] ?? sourcePath}. Ready for SAM3 precompute.');
      }
      await _refreshMetadataFiles();
    } catch (_) {
      // Debug config is optional outside the production debug container.
    }
  }

  Future<void> _showJobs() async {
    unawaited(_refreshStatusPanels());
    await showDialog<void>(
      context: context,
      builder: (context) => _JobsDialog(
        jobs: _jobs,
        onKill: (job) async {
          await widget.client.cancelJob(job.id);
          await _refreshStatusPanels();
        },
      ),
    );
  }

  Future<void> _showActivities() async {
    unawaited(_refreshStatusPanels());
    await showDialog<void>(
      context: context,
      builder: (context) => _ActivitiesDialog(activities: _activities),
    );
  }

  void _togglePlayback() {
    if (_videoController.isPlaying) {
      _videoController.pause();
    } else {
      unawaited(_videoController.play());
    }
  }

  void _handleVideoUpdate() {
    if (mounted) {
      setState(() {});
    }
    DevtoolsAgentBridge.instance.emitStateChanged();
  }

  void _registerAgentHooks() {
    final bridge = DevtoolsAgentBridge.instance;
    bridge.registerStateProvider(this, 'impactCycle', _agentState);
    bridge.registerCommand(this, 'impactCycle.selectMountedVideo', (args) async {
      final path = _requiredString(args, 'path');
      final metadataPath = args['metadataPath']?.toString();
      _selectVideo(
        sourceType: 'mounted',
        sourcePath: path,
        videoUrl: _mountedFileUrl(path),
        videoName: path,
      );
      if (metadataPath != null && metadataPath.isNotEmpty) {
        _workflowBundlePath = metadataPath;
        await _loadMountedMetadata(metadataPath);
      } else {
        setState(() => _status = 'Mounted video selected via DevTools agent. Ready for SAM3 precompute.');
      }
      await _refreshMetadataFiles();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.startSam3', (_) async {
      await _startSam3MetadataJob();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.startWorkflowOperation', (args) async {
      await _startWorkflowOperation(_requiredString(args, 'operation'));
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.cancelCurrentJob', (_) async {
      await _cancelJob();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.refreshStatus', (_) async {
      await _refreshStatusPanels();
      await _refreshMetadataFiles();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.setSamplingFps', (args) {
      setState(() => _samplingFps = _requiredDouble(args, 'value'));
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.setMaxFrames', (args) {
      setState(() => _maxFrames = _requiredInt(args, 'value'));
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.setBoundingBoxesVisible', (args) {
      _setShowBoundingBoxes(_optionalBool(args['visible'], fallback: true));
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.play', (_) async {
      await _videoController.play();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.pause', (_) {
      _videoController.pause();
      return _agentState();
    });
    bridge.registerCommand(this, 'impactCycle.seekTo', (args) {
      _videoController.seekTo(_durationFromAgentArgs(args));
      return _agentState();
    });
  }

  Map<String, dynamic> _agentState() {
    return {
      'status': _status,
      'error': _error,
      'sourceType': _sourceType,
      'sourcePath': _sourcePath,
      'videoName': _videoName,
      'videoUrl': _videoUrl,
      'samplingFps': _samplingFps,
      'maxFrames': _maxFrames,
      'backendProvider': _backendProvider,
      'showBoundingBoxes': _showBoundingBoxes,
      'isUploading': _isUploading,
      'canStart': _canStart,
      'metadataDirectory': _metaDirectory,
      'workflowBundlePath': _workflowBundlePath,
      'vqaPath': _vqaPath,
      'cyclePath': _cyclePath,
      'sceneGraphGtPath': _sceneGraphGtPath,
      'vqaGtPath': _vqaGtPath,
      'metadataFiles': Map<String, bool>.from(_metadataFiles),
      'video': {
        'hasVideo': _videoController.hasVideo,
        'isPlaying': _videoController.isPlaying,
        'positionMs': _videoController.position.inMilliseconds,
        'durationMs': _videoController.duration.inMilliseconds,
        'playbackRate': _videoController.playbackRate,
      },
      'counts': {
        'jobs': _jobs.length,
        'runningJobs': _jobs.where((job) => job.isRunning).length,
        'activities': _activities.length,
        'failedActivities': _activities.where((activity) => activity.isFailure).length,
        'events': _events.length,
        'graphs': _bundle?.graphs.length ?? 0,
        'overlays': _bundle?.pointsOfInterest.length ?? 0,
      },
      'job': _job == null ? null : _jobToAgentJson(_job!),
      'jobs': _jobs.map(_jobToAgentJson).toList(growable: false),
      'activities': _activities.map(_activityToAgentJson).toList(growable: false),
      'events': _events.map(_eventToAgentJson).toList(growable: false),
      'pointsOfInterest': (_bundle?.pointsOfInterest ?? const <VideoPointOfInterest>[]).map(_poiToAgentJson).toList(growable: false),
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

  String _mountedFileUrl(String path) {
    return Uri(path: '/api/mounted-files/file/', queryParameters: {'path': path}).toString();
  }

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

  Map<String, dynamic> _eventToAgentJson(ImpactCycleEvent event) => {
        'index': event.index,
        'type': event.type,
        'message': event.message,
        'timestamp': event.timestamp,
      };

  Map<String, dynamic> _poiToAgentJson(VideoPointOfInterest poi) => {
        'objectId': poi.objectId,
        'objectType': poi.objectType,
        'timestampMs': poi.timestamp.inMilliseconds,
        'timestamp': formatVideoTimestamp(poi.timestamp),
        'confidence': poi.confidence,
        'boundingBox': {
          'x1': poi.boundingBox.x1,
          'y1': poi.boundingBox.y1,
          'x2': poi.boundingBox.x2,
          'y2': poi.boundingBox.y2,
        },
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

  String _statusFor(ImpactCycleJob job) {
    final label = switch (job.operation) {
      'vqa_generate' => 'VQA generation',
      'track_objects' => 'Object tracking',
      'cycle_verify' => 'Cycle verification',
      'scene_graph_eval' => 'Scene graph evaluation',
      'vqa_eval' => 'VQA evaluation',
      _ => 'SAM3 detection precompute',
    };
    switch (job.status) {
      case 'queued':
        return 'Impact Cycle job queued.';
      case 'running':
        return '$label: ${job.percent}% (${job.processedFrames}/${job.totalFrames}).';
      case 'completed':
        return '$label completed.';
      case 'failed':
        return '$label failed.';
      case 'cancelled':
        return '$label cancelled.';
      default:
        return 'Impact Cycle status: ${job.status}';
    }
  }

  String _directoryOf(String path) {
    final parts = path.split('/');
    if (parts.length <= 1) {
      return '';
    }
    return parts.sublist(0, parts.length - 1).join('/');
  }

  String _metadataDirectoryForVideo(String path) {
    final directory = _directoryOf(path);
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return directory.isEmpty ? '${stem}_meta' : '$directory/${stem}_meta';
  }

  Future<void> _refreshMetadataFiles() async {
    final metaDirectory = _metaDirectory;
    if (metaDirectory.isEmpty) {
      return;
    }
    try {
      final listing = await _mountedFilesClient.list(path: metaDirectory, kind: 'json');
      final existing = listing.entries.where((entry) => entry.isFile).map((entry) => entry.name).toSet();
      if (!mounted) {
        return;
      }
      setState(() {
        for (final filename in _metadataFiles.keys) {
          _metadataFiles[filename] = existing.contains(filename);
        }
      });
      if (_metadataFiles['scene_graph_bundle.json'] == true) {
        unawaited(_loadMountedMetadata('$_metaDirectory/scene_graph_bundle.json', refreshFiles: false));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        for (final filename in _metadataFiles.keys) {
          _metadataFiles[filename] = false;
        }
      });
    }
  }
}

class _ImpactHeader extends StatelessWidget {
  const _ImpactHeader({required this.status, required this.failedActivityCount, required this.runningJobCount, required this.onShowActivities, required this.onShowJobs});

  final String status;
  final int failedActivityCount;
  final int runningJobCount;
  final VoidCallback onShowActivities;
  final VoidCallback onShowJobs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF6EE7B7)]),
          ),
          child: const Icon(Icons.hub, color: Color(0xFF020617)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Impact Cycle Control', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Semantics(
                identifier: 'impact-cycle.status',
                liveRegion: true,
                child: Text(status, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8))),
              ),
            ],
          ),
        ),
        Badge.count(
          count: failedActivityCount,
          isLabelVisible: failedActivityCount > 0,
          child: Semantics(
            identifier: 'impact-cycle.show-activities',
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
            identifier: 'impact-cycle.show-jobs',
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

class _JobProgress extends StatelessWidget {
  const _JobProgress({required this.job});

  final ImpactCycleJob job;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Job ${job.status}', style: Theme.of(context).textTheme.titleSmall)),
            Text('${job.percent}%'),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: job.totalFrames == 0 && job.isRunning ? null : job.percent / 100),
        const SizedBox(height: 6),
        Text('${job.processedFrames}/${job.totalFrames} sampled frames', style: const TextStyle(color: Color(0xFF94A3B8))),
      ],
    );
  }
}

class _JobsDialog extends StatelessWidget {
  const _JobsDialog({required this.jobs, required this.onKill});

  final List<ImpactCycleJob> jobs;
  final Future<void> Function(ImpactCycleJob job) onKill;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SAM3 jobs'),
      content: SizedBox(
        width: 560,
        child: jobs.isEmpty
            ? const Text('No SAM3 detection jobs yet.')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: jobs.length,
                separatorBuilder: (_, __) => const Divider(height: 18),
                itemBuilder: (context, index) {
                  final job = jobs[index];
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(job.videoName, maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text('${job.status} - ${job.percent}% (${job.processedFrames}/${job.totalFrames})', style: const TextStyle(color: Color(0xFF94A3B8))),
                            if (job.error.isNotEmpty) Text(job.error, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFFCA5A5))),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: job.isRunning ? () => onKill(job) : null,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Kill'),
                      ),
                    ],
                  );
                },
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
                    leading: Icon(activity.isFailure ? Icons.error_outline : Icons.check_circle_outline, color: activity.isFailure ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7)),
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

class _BundleSummary extends StatelessWidget {
  const _BundleSummary({required this.bundle});

  final ImpactCycleBundle? bundle;

  @override
  Widget build(BuildContext context) {
    final value = bundle;
    if (value == null) {
      return const Text('No generated metadata yet.', style: TextStyle(color: Color(0xFF94A3B8)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoLine(label: 'Graphs', value: value.graphs.length.toString()),
        const SizedBox(height: 6),
        _InfoLine(label: 'Overlays', value: value.pointsOfInterest.length.toString()),
        const SizedBox(height: 8),
        PoiLegend(pointsOfInterest: value.pointsOfInterest),
      ],
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.events});

  final List<ImpactCycleEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Center(child: Text('Progress messages will appear here.', style: TextStyle(color: Color(0xFF94A3B8))));
    }
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFF020617), border: Border.all(color: const Color(0xFF273044))),
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: events.length,
        itemBuilder: (context, index) {
          final event = events[events.length - 1 - index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('[${event.type}] ${event.message}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFE2E8F0))),
          );
        },
      ),
    );
  }
}

class _MetadataChecklistRow extends StatelessWidget {
  const _MetadataChecklistRow({required this.filename, required this.exists, required this.buttonLabel, required this.onPressed});

  final String filename;
  final bool exists;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = exists ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    return Row(
      children: [
        Icon(exists ? Icons.check_circle : Icons.cancel, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(filename, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 10),
        Semantics(
          identifier: 'impact-cycle.workflow.${filename.replaceAll('.', '-')}',
          button: true,
          enabled: onPressed != null,
          label: buttonLabel,
          child: FilledButton.tonal(
            onPressed: onPressed,
            child: Text(buttonLabel),
          ),
        ),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 94, child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8)))),
        Expanded(child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.label, required this.value, required this.onChanged});

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'impact-cycle.${label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
      textField: true,
      label: label,
      child: TextFormField(
        initialValue: value,
        enabled: true,
        decoration: InputDecoration(labelText: label),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: onChanged,
      ),
    );
  }
}

class _EmptyImpactVideoState extends StatelessWidget {
  const _EmptyImpactVideoState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_library, size: 52, color: Color(0xFF64748B)),
          SizedBox(height: 12),
          Text('Select a video to preview Impact Cycle metadata.', style: TextStyle(color: Color(0xFF94A3B8))),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: const Color(0xFF451A1A), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF7F1D1D))),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: const TextStyle(color: Color(0xFFFCA5A5))),
      ),
    );
  }
}

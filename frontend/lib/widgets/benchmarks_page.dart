import 'dart:async';

import 'package:flutter/material.dart';

import '../models/benchmark_models.dart';
import '../services/benchmarks_client.dart';
import '../services/mounted_files_client.dart';

class BenchmarksPage extends StatefulWidget {
  const BenchmarksPage({super.key});

  @override
  State<BenchmarksPage> createState() => _BenchmarksPageState();
}

class _BenchmarksPageState extends State<BenchmarksPage> {
  final _client = const BenchmarksClient();
  Timer? _timer;
  List<BenchmarkRun> _runs = const [];
  BenchmarkRun? _selected;
  List<BenchmarkEvent> _events = const [];
  int _eventCursor = 0;
  String? _error;
  var _loading = true;
  var _countBlacklistedQaPairs = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
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
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Benchmark Runs', style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 4),
                          Text(
                            'Evaluate selected LM Studio models against mounted qa_pairs.json files.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8)),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _openCreateDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('New benchmark'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 18),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(width: 430, child: _buildRunList()),
                      const SizedBox(width: 18),
                      Expanded(child: _buildDetails()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRunList() {
    if (_loading) {
      return const Card(child: Center(child: CircularProgressIndicator()));
    }
    if (_runs.isEmpty) {
      return const Card(child: Center(child: Text('No benchmark runs yet.')));
    }
    return Card(
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _runs.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final run = _runs[index];
          final selected = run.id == _selected?.id;
          return ListTile(
            selected: selected,
            leading: Icon(run.isRunning ? Icons.sync : Icons.assessment),
            title: Text(run.name.isEmpty ? run.id : run.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${run.status} - ${run.creationDate}', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(run.isRunning ? '${run.progress.percent}%' : '${run.metrics.total.percent.toStringAsFixed(1)}%'),
                IconButton(onPressed: run.isRunning ? null : () => _openEditDialog(run), icon: const Icon(Icons.edit), tooltip: 'Edit'),
                IconButton(onPressed: run.isRunning ? null : () => _deleteRun(run), icon: const Icon(Icons.delete), tooltip: 'Delete'),
              ],
            ),
            onTap: () => _selectRun(run),
          );
        },
      ),
    );
  }

  Widget _buildDetails() {
    final run = _selected;
    if (run == null) {
      return const Card(child: Center(child: Text('Select a benchmark run.')));
    }
    final metrics = _countBlacklistedQaPairs ? run.metricsIncludingBlacklisted : run.metrics;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(run.name, style: Theme.of(context).textTheme.titleLarge)),
                FilledButton.icon(
                  onPressed: run.canPause
                      ? () => _pauseRun(run)
                      : (run.canResume ? () => _resumeRun(run) : (run.canStart ? () => _startRun(run) : null)),
                  icon: Icon(run.canPause ? Icons.pause : (run.canResume ? Icons.replay : Icons.play_arrow)),
                  label: Text(run.canPause ? 'Pause' : (run.canResume ? 'Resume' : 'Start')),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: run.isRunning ? null : () => _openEditDialog(run), icon: const Icon(Icons.edit), tooltip: 'Edit'),
                const SizedBox(width: 8),
                IconButton(onPressed: run.isRunning ? null : () => _deleteRun(run), icon: const Icon(Icons.delete), tooltip: 'Delete'),
              ],
            ),
            const SizedBox(height: 8),
            Text(run.description.isEmpty ? 'No description.' : run.description, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _InfoChip(label: 'Status', value: run.status),
                _InfoChip(label: 'Model', value: run.model),
                _InfoChip(label: 'Frame sample rate', value: '${run.frameSampleRate}'),
                _InfoChip(label: 'Save sample frames', value: run.saveSampleFrames ? 'yes' : 'no'),
                _InfoChip(label: 'Batch same evidence spans', value: run.batchSameEvidenceSpans ? 'yes' : 'no'),
                _InfoChip(
                  label: 'Evidence threshold',
                  value: run.skipEvidenceAboveThreshold ? '${run.evidenceDurationThresholdSeconds}s' : 'off',
                ),
                _InfoChip(label: 'QA files', value: '${run.qaFiles.length}'),
                _InfoChip(label: 'Output', value: '${run.outputFolder}/${run.id}'),
              ],
            ),
            if (run.isRunning) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: run.progress.percent / 100),
              const SizedBox(height: 6),
              Text('${run.progress.processedQuestions}/${run.progress.totalQuestions} questions'),
            ],
            if (run.error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(run.error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            Text('Details', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Processed QA pairs: ${run.details.processedQaPairs} (plus skipped QA pairs: ${run.details.skippedBlacklistedQaPairs})'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('count blacklisted QA pairs'),
              value: _countBlacklistedQaPairs,
              onChanged: (value) => setState(() => _countBlacklistedQaPairs = value),
            ),
            const SizedBox(height: 12),
            Text('Metrics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            _MetricRow(name: 'Total correct', bucket: metrics.total),
            const SizedBox(height: 8),
            _MetricSection(title: 'Correct by family', buckets: metrics.byFamily),
            const SizedBox(height: 8),
            _MetricSection(title: 'Correct by day/night', buckets: metrics.dayNight),
            const SizedBox(height: 14),
            Text('QA files', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(run.qaFiles.join('\n'), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFCBD5E1))),
            const SizedBox(height: 14),
            Text('Events', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(color: const Color(0xFF0B1020), borderRadius: BorderRadius.circular(12)),
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: _events.length,
                  itemBuilder: (context, index) {
                    final event = _events[index];
                    return Text('${event.timestamp} ${event.type}: ${event.message}', style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1)));
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    try {
      final runs = await _client.listRuns();
      BenchmarkRun? selected;
      if (_selected != null) {
        for (final run in runs) {
          if (run.id == _selected!.id) {
            selected = run;
            break;
          }
        }
      }
      if (selected != null) {
        await _refreshEvents(selected.id);
      }
      if (mounted) {
        setState(() {
          _runs = runs;
          _selected = selected ?? (runs.isNotEmpty ? runs.first : null);
          _loading = false;
          _error = null;
        });
        if (_selected != null && selected == null) {
          _eventCursor = 0;
          _events = const [];
          await _refreshEvents(_selected!.id);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load benchmark runs: $error';
        });
      }
    }
  }

  Future<void> _refreshEvents(String runId) async {
    final page = await _client.getEvents(runId, _eventCursor);
    if (!mounted || page.events.isEmpty) {
      _eventCursor = page.next;
      return;
    }
    setState(() {
      _events = [..._events, ...page.events];
      _eventCursor = page.next;
    });
  }

  void _selectRun(BenchmarkRun run) {
    setState(() {
      _selected = run;
      _events = const [];
      _eventCursor = 0;
    });
    _refreshEvents(run.id);
  }

  Future<void> _openCreateDialog() async {
    final request = await showDialog<BenchmarkCreateRequest>(context: context, barrierDismissible: false, builder: (context) => const _CreateBenchmarkDialog());
    if (request == null) {
      return;
    }
    try {
      final run = await _client.createRun(request);
      await _refresh();
      _selectRun(run);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not create benchmark run: $error');
      }
    }
  }

  Future<void> _openEditDialog(BenchmarkRun run) async {
    final request = await showDialog<BenchmarkUpdateRequest>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CreateBenchmarkDialog(initialRun: run),
    );
    if (request == null) {
      return;
    }
    try {
      final updated = await _client.updateRun(run.id, request);
      await _refresh();
      _selectRun(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not edit benchmark run: $error');
      }
    }
  }

  Future<void> _startRun(BenchmarkRun run) async {
    try {
      final updated = await _client.startRun(run.id);
      setState(() => _selected = updated);
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not start benchmark run: $error');
      }
    }
  }

  Future<void> _resumeRun(BenchmarkRun run) async {
    try {
      final updated = await _client.resumeRun(run.id);
      setState(() => _selected = updated);
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not resume benchmark run: $error');
      }
    }
  }

  Future<void> _pauseRun(BenchmarkRun run) async {
    try {
      final updated = await _client.pauseRun(run.id);
      setState(() => _selected = updated);
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not pause benchmark run: $error');
      }
    }
  }

  Future<void> _deleteRun(BenchmarkRun run) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete benchmark run?'),
        content: Text('This removes ${run.outputFolder}/${run.id} including details and results.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _client.deleteRun(run.id);
      setState(() {
        _selected = null;
        _events = const [];
        _eventCursor = 0;
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not delete benchmark run: $error');
      }
    }
  }
}

class _CreateBenchmarkDialog extends StatefulWidget {
  const _CreateBenchmarkDialog({this.initialRun});

  final BenchmarkRun? initialRun;

  @override
  State<_CreateBenchmarkDialog> createState() => _CreateBenchmarkDialogState();
}

class _CreateBenchmarkDialogState extends State<_CreateBenchmarkDialog> {
  final _mountedClient = const MountedFilesClient();
  late final TextEditingController _nameController;
  late final TextEditingController _creationDateController;
  late final TextEditingController _runDateController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _lmStudioUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _frameSampleRateController;
  late final TextEditingController _evidenceDurationThresholdController;
  late final TextEditingController _outputFolderController;
  List<String> _qaFiles = const [];
  var _saveSampleFrames = false;
  var _batchSameEvidenceSpans = true;
  var _skipEvidenceAboveThreshold = true;

  @override
  void initState() {
    super.initState();
    final run = widget.initialRun;
    final now = DateTime.now().toUtc().toIso8601String();
    _nameController = TextEditingController(text: run?.name ?? '');
    _creationDateController = TextEditingController(text: run?.creationDate ?? now);
    _runDateController = TextEditingController(text: run?.runDate ?? '');
    _descriptionController = TextEditingController(text: run?.description ?? '');
    _lmStudioUrlController = TextEditingController(text: run?.lmStudioUrl ?? 'http://host.docker.internal:1234/v1');
    _modelController = TextEditingController(text: run?.model ?? 'google/gemma-4-31b');
    _frameSampleRateController = TextEditingController(text: run == null ? '15' : '${run.frameSampleRate}');
    _evidenceDurationThresholdController = TextEditingController(text: run == null ? '25' : '${run.evidenceDurationThresholdSeconds}');
    _outputFolderController = TextEditingController(text: run?.outputFolder ?? 'benchmark_runs');
    _qaFiles = run?.qaFiles ?? const [];
    _saveSampleFrames = run?.saveSampleFrames ?? false;
    _batchSameEvidenceSpans = run?.batchSameEvidenceSpans ?? true;
    _skipEvidenceAboveThreshold = run?.skipEvidenceAboveThreshold ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _creationDateController.dispose();
    _runDateController.dispose();
    _descriptionController.dispose();
    _lmStudioUrlController.dispose();
    _modelController.dispose();
    _frameSampleRateController.dispose();
    _evidenceDurationThresholdController.dispose();
    _outputFolderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initialRun != null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.assessment, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(editing ? 'Edit benchmark run' : 'Create benchmark run', style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close), tooltip: 'Close'),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _field(_nameController, 'Name'),
                      const SizedBox(height: 12),
                      _field(_creationDateController, 'creation_date'),
                      const SizedBox(height: 12),
                      _field(_runDateController, 'run_date'),
                      const SizedBox(height: 12),
                      _field(_descriptionController, 'Description', maxLines: 3),
                      const SizedBox(height: 12),
                      _field(_lmStudioUrlController, 'LM Studio URL'),
                      const SizedBox(height: 12),
                      if (editing)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.lock),
                          title: const Text('Model'),
                          subtitle: Text(_modelController.text.isEmpty ? 'No model configured.' : _modelController.text),
                        )
                      else
                        _field(_modelController, 'Model'),
                      const SizedBox(height: 12),
                      _field(_frameSampleRateController, 'Frame Sample Rate', keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Save sample frames'),
                        subtitle: const Text('Store each sampled frame in this benchmark run\'s frames directory.'),
                        value: _saveSampleFrames,
                        onChanged: (value) => setState(() => _saveSampleFrames = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Batch process QA Pairs with same evicende spans'),
                        subtitle: const Text('Send QA pairs with identical evidence start/end seconds for the same video in one LLM request.'),
                        value: _batchSameEvidenceSpans,
                        onChanged: (value) => setState(() => _batchSameEvidenceSpans = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('skip QA pairs with evidence span above threshold'),
                        subtitle: const Text('Ignore QA pairs whose evidence duration exceeds the configured threshold.'),
                        value: _skipEvidenceAboveThreshold,
                        onChanged: (value) => setState(() => _skipEvidenceAboveThreshold = value),
                      ),
                      if (_skipEvidenceAboveThreshold) ...[
                        const SizedBox(height: 12),
                        _field(
                          _evidenceDurationThresholdController,
                          'Maximum evidence duration in seconds',
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _field(_outputFolderController, 'output folder', readOnly: true),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.rule_folder),
                        title: const Text('QA files'),
                        subtitle: Text(_qaFiles.isEmpty ? 'No qa_pairs.json files selected.' : '${_qaFiles.length} file(s) selected'),
                        trailing: FilledButton.tonal(onPressed: _selectQaFiles, child: const Text('Select')),
                      ),
                      if (_qaFiles.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_qaFiles.join('\n'), maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFCBD5E1))),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const Spacer(),
                  FilledButton.icon(onPressed: _submit, icon: Icon(editing ? Icons.save : Icons.add), label: Text(editing ? 'Save' : 'Create')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label, {int maxLines = 1, TextInputType? keyboardType, bool readOnly = false}) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      readOnly: readOnly,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

  Future<void> _selectQaFiles() async {
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) => _QaFilePickerDialog(client: _mountedClient, initialSelection: _qaFiles),
    );
    if (selected != null) {
      setState(() => _qaFiles = selected);
    }
  }

  void _submit() {
    final frameSampleRate = int.tryParse(_frameSampleRateController.text.trim());
    final evidenceDurationThreshold = double.tryParse(_evidenceDurationThresholdController.text.trim());
    if (_nameController.text.trim().isEmpty ||
        frameSampleRate == null ||
        frameSampleRate < 1 ||
        _qaFiles.isEmpty ||
        (_skipEvidenceAboveThreshold && (evidenceDurationThreshold == null || evidenceDurationThreshold <= 0))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name, positive numeric values, and QA files are required.')));
      return;
    }
    if (widget.initialRun != null) {
      Navigator.of(context).pop(BenchmarkUpdateRequest(
        name: _nameController.text.trim(),
        creationDate: _creationDateController.text.trim(),
        runDate: _runDateController.text.trim(),
        description: _descriptionController.text.trim(),
        lmStudioUrl: _lmStudioUrlController.text.trim(),
        frameSampleRate: frameSampleRate,
        saveSampleFrames: _saveSampleFrames,
        batchSameEvidenceSpans: _batchSameEvidenceSpans,
        skipEvidenceAboveThreshold: _skipEvidenceAboveThreshold,
        evidenceDurationThresholdSeconds: evidenceDurationThreshold ?? 25,
        outputFolder: _outputFolderController.text.trim().isEmpty ? 'benchmark_runs' : _outputFolderController.text.trim(),
        qaFiles: _qaFiles,
      ));
      return;
    }
    Navigator.of(context).pop(BenchmarkCreateRequest(
      name: _nameController.text.trim(),
      creationDate: _creationDateController.text.trim(),
      runDate: _runDateController.text.trim(),
      description: _descriptionController.text.trim(),
      lmStudioUrl: _lmStudioUrlController.text.trim(),
      model: _modelController.text.trim(),
      frameSampleRate: frameSampleRate,
      saveSampleFrames: _saveSampleFrames,
      batchSameEvidenceSpans: _batchSameEvidenceSpans,
      skipEvidenceAboveThreshold: _skipEvidenceAboveThreshold,
      evidenceDurationThresholdSeconds: evidenceDurationThreshold ?? 25,
      outputFolder: _outputFolderController.text.trim().isEmpty ? 'benchmark_runs' : _outputFolderController.text.trim(),
      qaFiles: _qaFiles,
    ));
  }
}

class _QaFilePickerDialog extends StatefulWidget {
  const _QaFilePickerDialog({required this.client, required this.initialSelection});

  final MountedFilesClient client;
  final List<String> initialSelection;

  @override
  State<_QaFilePickerDialog> createState() => _QaFilePickerDialogState();
}

class _QaFilePickerDialogState extends State<_QaFilePickerDialog> {
  var _path = '';
  late Future<MountedFileListing> _listingFuture;
  late Set<String> _selected;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelection};
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
              Text('Select qa_pairs.json files', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('Select individual qa_pairs.json files or select a folder to include all nested qa_pairs.json files.'),
              const SizedBox(height: 12),
              Expanded(
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
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(listing.path.isEmpty ? 'Mounted input root' : listing.path, overflow: TextOverflow.ellipsis)),
                            TextButton.icon(onPressed: listing.parent == null ? null : () => _openDirectory(listing.parent!), icon: const Icon(Icons.arrow_upward), label: const Text('Up')),
                          ],
                        ),
                        Expanded(child: _entryList(listing.entries)),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Text('${_selected.length} selected'),
              Row(
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const Spacer(),
                  FilledButton(onPressed: () => Navigator.of(context).pop(_selected.toList()..sort()), child: const Text('Use selection')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _entryList(List<MountedFileEntry> entries) {
    if (entries.isEmpty) {
      return const Center(child: Text('No JSON files or folders in this directory.'));
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isQaFile = entry.isFile && entry.name == 'qa_pairs.json';
        final selected = _selected.contains(entry.path);
        return ListTile(
          leading: Icon(entry.isDirectory ? Icons.folder : Icons.data_object),
          title: Text(entry.name),
          subtitle: Text(entry.path),
          enabled: entry.isDirectory || isQaFile,
          trailing: entry.isDirectory
              ? IconButton(
                  tooltip: 'Open folder',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _openDirectory(entry.path),
                )
              : isQaFile && selected
                  ? const Icon(Icons.check_circle)
                  : null,
          onTap: entry.isDirectory ? () => _selectDirectory(entry.path) : isQaFile ? () => _toggleFile(entry.path) : null,
        );
      },
    );
  }

  void _toggleFile(String path) {
    setState(() {
      if (!_selected.remove(path)) {
        _selected.add(path);
      }
    });
  }

  Future<void> _selectDirectory(String path) async {
    setState(() => _busy = true);
    try {
      final files = await _collectQaFiles(path);
      setState(() => _selected.addAll(files));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<List<String>> _collectQaFiles(String path) async {
    final listing = await widget.client.list(path: path, kind: 'json');
    final files = <String>[];
    for (final entry in listing.entries) {
      if (entry.isDirectory) {
        files.addAll(await _collectQaFiles(entry.path));
      } else if (entry.name == 'qa_pairs.json') {
        files.add(entry.path);
      }
    }
    return files;
  }

  void _openDirectory(String path) {
    setState(() {
      _path = path;
      _listingFuture = _loadListing();
    });
  }

  Future<MountedFileListing> _loadListing() => widget.client.list(path: _path, kind: 'json');
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label: $value'));
  }
}

class _MetricSection extends StatelessWidget {
  const _MetricSection({required this.title, required this.buckets});

  final String title;
  final Map<String, BenchmarkMetricBucket> buckets;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return Text('$title: no results yet', style: const TextStyle(color: Color(0xFF94A3B8)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        for (final entry in buckets.entries) _MetricRow(name: entry.key, bucket: entry.value),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.name, required this.bucket});

  final String name;
  final BenchmarkMetricBucket bucket;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(name)),
          Text('${bucket.percent.toStringAsFixed(1)}% (${bucket.correct}/${bucket.count})'),
        ],
      ),
    );
  }
}

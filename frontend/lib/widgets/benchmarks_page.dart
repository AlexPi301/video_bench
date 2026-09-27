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
  List<Benchmark> _benchmarks = const [];
  Benchmark? _benchmark;
  BenchmarkRun? _run;
  List<BenchmarkEvent> _events = const [];
  int _eventCursor = 0;
  String? _error;
  var _loading = true;
  var _countBlacklisted = false;

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
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Benchmarks', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 4), const Text('Create benchmark definitions and run multiple models independently.')])) ,
                  FilledButton.icon(onPressed: _openCreateDialog, icon: const Icon(Icons.add), label: const Text('New benchmark')),
                  const SizedBox(width: 8),
                  IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
                ]),
                if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
                const SizedBox(height: 18),
                Expanded(child: Row(children: [SizedBox(width: 430, child: _buildBenchmarkList()), const SizedBox(width: 18), Expanded(child: _buildDetails())])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBenchmarkList() {
    if (_loading) return const Card(child: Center(child: CircularProgressIndicator()));
    if (_benchmarks.isEmpty) return const Card(child: Center(child: Text('No benchmarks yet.')));
    return Card(
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _benchmarks.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final benchmark = _benchmarks[index];
          return ListTile(
            selected: benchmark.id == _benchmark?.id,
            leading: Icon(benchmark.hasActiveRuns ? Icons.sync : Icons.assessment),
            title: Text(benchmark.name.isEmpty ? benchmark.id : benchmark.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${benchmark.runs.length} run(s) - ${benchmark.qaFiles.length} QA file(s)', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(benchmark.runs.isEmpty ? 'no runs' : benchmark.runs.first.status),
            onTap: () => _selectBenchmark(benchmark),
          );
        },
      ),
    );
  }

  Widget _buildDetails() {
    final benchmark = _benchmark;
    if (benchmark == null) return const Card(child: Center(child: Text('Select a benchmark.')));
    final run = _run;
    final metrics = run == null ? null : (_countBlacklisted ? run.metricsIncludingBlacklisted : run.metrics);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(benchmark.name, style: Theme.of(context).textTheme.titleLarge)),
            FilledButton.icon(onPressed: benchmark.legacy ? null : () => _openAddRunDialog(benchmark), icon: const Icon(Icons.add), label: const Text('Add benchmark run')),
            const SizedBox(width: 8),
            IconButton(onPressed: benchmark.hasActiveRuns || benchmark.legacy ? null : () => _openEditDialog(benchmark), icon: const Icon(Icons.edit), tooltip: 'Edit benchmark'),
            IconButton(onPressed: benchmark.hasActiveRuns || benchmark.legacy ? null : () => _deleteBenchmark(benchmark), icon: const Icon(Icons.delete), tooltip: 'Delete benchmark'),
          ]),
          const SizedBox(height: 8),
          Text(benchmark.description.isEmpty ? 'No description.' : benchmark.description),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [_InfoChip(label: 'Frame sample rate', value: '${benchmark.frameSampleRate}'), _InfoChip(label: 'Max QA pairs per video', value: benchmark.maxQaPairsPerVideo == -1 ? 'unlimited' : '${benchmark.maxQaPairsPerVideo}'), _InfoChip(label: 'Batch spans', value: benchmark.batchSameEvidenceSpans ? 'yes' : 'no'), _InfoChip(label: 'Evidence threshold', value: benchmark.skipEvidenceAboveThreshold ? '${benchmark.evidenceDurationThresholdSeconds}s' : 'off'), _InfoChip(label: 'QA files', value: '${benchmark.qaFiles.length}')]),
          const SizedBox(height: 14),
          Text('Benchmark runs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(height: 135, child: _buildRunList(benchmark)),
          const SizedBox(height: 12),
          if (run == null) const Expanded(child: Center(child: Text('Select or add a benchmark run.'))) else ...[
            Row(children: [
              Expanded(child: Text('${run.model} (${run.status})', style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
              FilledButton.icon(onPressed: benchmark.legacy ? null : (run.canPause ? () => _pauseRun(run) : (run.canResume ? () => _resumeRun(run) : (run.canStart ? () => _startRun(run) : null))), icon: Icon(run.canPause ? Icons.pause : (run.canResume ? Icons.replay : Icons.play_arrow)), label: Text(run.canPause ? 'Pause' : (run.canResume ? 'Resume' : 'Start'))),
              IconButton(onPressed: benchmark.legacy || run.isRunning ? null : () => _deleteRun(run), icon: const Icon(Icons.delete), tooltip: 'Delete run'),
            ]),
            if (run.isRunning) ...[const SizedBox(height: 10), LinearProgressIndicator(value: run.progress.percent / 100), const SizedBox(height: 6), Text('${run.progress.processedQuestions}/${run.progress.totalQuestions} questions')],
            if (run.error.isNotEmpty) ...[const SizedBox(height: 8), Text(run.error, style: TextStyle(color: Theme.of(context).colorScheme.error))],
            const SizedBox(height: 10),
            Text('Processed QA pairs: ${run.details.processedQaPairs} (plus skipped QA pairs: ${run.details.skippedBlacklistedQaPairs})'),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('count blacklisted QA pairs'), value: _countBlacklisted, onChanged: (value) => setState(() => _countBlacklisted = value)),
            _MetricRow(name: 'Total correct', bucket: metrics!.total),
            const SizedBox(height: 8),
            _MetricSection(title: 'Correct by family', buckets: _orderedFamilyBuckets(metrics.byFamily)),
            const SizedBox(height: 8),
            _MetricSection(title: 'Correct by day/night', buckets: metrics.dayNight),
            const SizedBox(height: 10),
            Text('Events', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Expanded(child: DecoratedBox(decoration: BoxDecoration(color: const Color(0xFF0B1020), borderRadius: BorderRadius.circular(12)), child: ListView.builder(padding: const EdgeInsets.all(10), itemCount: _events.length, itemBuilder: (context, index) { final event = _events[index]; return Text('${event.timestamp} ${event.type}: ${event.message}', style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1))); }))),
          ],
        ]),
      ),
    );
  }

  Widget _buildRunList(Benchmark benchmark) {
    if (benchmark.runs.isEmpty) return const Center(child: Text('No benchmark runs yet.'));
    return ListView.separated(scrollDirection: Axis.horizontal, itemCount: benchmark.runs.length, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (context, index) { final run = benchmark.runs[index]; final selected = run.selectionKey == _run?.selectionKey; return SizedBox(width: 280, child: Card.filled(color: selected ? Theme.of(context).colorScheme.primaryContainer : null, child: ListTile(selected: selected, title: Text(run.model, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('${run.status} - ${run.isRunning ? '${run.progress.percent}%' : '${run.metrics.total.percent.toStringAsFixed(1)}%'}'), onTap: () => _selectRun(run)))); });
  }

  Future<void> _refresh() async {
    try {
      final benchmarks = await _client.listBenchmarks();
      final selectedBenchmark = _benchmark == null ? (benchmarks.isNotEmpty ? benchmarks.first : null) : _firstOrNull(benchmarks.where((item) => item.id == _benchmark!.id));
      final selectedRun = selectedBenchmark == null ? null : (_run == null ? (selectedBenchmark.runs.isNotEmpty ? selectedBenchmark.runs.first : null) : _firstOrNull(selectedBenchmark.runs.where((item) => item.id == _run!.id)));
      if (selectedRun != null) {
        try {
          await _refreshEvents(selectedRun, reset: false);
        } catch (_) {
          _events = const [];
          _eventCursor = 0;
        }
      }
      if (!mounted) return;
      setState(() { _benchmarks = benchmarks; _benchmark = selectedBenchmark; _run = selectedRun; _loading = false; _error = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load benchmarks: $error'; });
    }
  }

  Future<void> _refreshEvents(BenchmarkRun run, {required bool reset}) async {
    if (run.benchmarkId.isEmpty) return;
    if (reset) { _events = const []; _eventCursor = 0; }
    final page = await _client.getEvents(run.benchmarkId, run.id, _eventCursor);
    if (!mounted) return;
    setState(() { _events = [..._events, ...page.events]; _eventCursor = page.next; });
  }

  void _selectBenchmark(Benchmark benchmark) { final run = benchmark.runs.isNotEmpty ? benchmark.runs.first : null; setState(() { _benchmark = benchmark; _run = run; _events = const []; _eventCursor = 0; }); if (run != null) _refreshEvents(run, reset: true); }
  void _selectRun(BenchmarkRun run) { setState(() { _run = run; _events = const []; _eventCursor = 0; }); _refreshEvents(run, reset: true); }

  Future<void> _openCreateDialog() async { final request = await showDialog<BenchmarkCreateRequest>(context: context, barrierDismissible: false, builder: (context) => const _BenchmarkDialog()); if (request == null) return; try { final benchmark = await _client.createBenchmark(request); await _refresh(); _selectBenchmark(benchmark); } catch (error) { if (mounted) setState(() => _error = 'Could not create benchmark: $error'); } }
  Future<void> _openEditDialog(Benchmark benchmark) async { final request = await showDialog<BenchmarkUpdateRequest>(context: context, barrierDismissible: false, builder: (context) => _BenchmarkDialog(initial: benchmark)); if (request == null) return; try { final updated = await _client.updateBenchmark(benchmark.id, request); await _refresh(); _selectBenchmark(updated); } catch (error) { if (mounted) setState(() => _error = 'Could not edit benchmark: $error'); } }
  Future<void> _openAddRunDialog(Benchmark benchmark) async { final request = await showDialog<BenchmarkRunCreateRequest>(context: context, builder: (context) => const _AddRunDialog()); if (request == null) return; try { final run = await _client.addRun(benchmark.id, request); await _refresh(); _selectRun(run); } catch (error) { if (mounted) setState(() => _error = 'Could not add benchmark run: $error'); } }
  Future<void> _startRun(BenchmarkRun run) async { try { final updated = await _client.startRun(run.benchmarkId, run.id); setState(() => _run = updated); await _refresh(); } catch (error) { if (mounted) setState(() => _error = 'Could not start benchmark run: $error'); } }
  Future<void> _resumeRun(BenchmarkRun run) async { try { final updated = await _client.resumeRun(run.benchmarkId, run.id); setState(() => _run = updated); await _refresh(); } catch (error) { if (mounted) setState(() => _error = 'Could not resume benchmark run: $error'); } }
  Future<void> _pauseRun(BenchmarkRun run) async { try { final updated = await _client.pauseRun(run.benchmarkId, run.id); setState(() => _run = updated); await _refresh(); } catch (error) { if (mounted) setState(() => _error = 'Could not pause benchmark run: $error'); } }

  Future<void> _deleteRun(BenchmarkRun run) async { final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Delete benchmark run?'), content: Text('This removes run ${run.id} including events and results.'), actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete'))])); if (confirmed != true) return; try { await _client.deleteRun(run.benchmarkId, run.id); setState(() { _run = null; _events = const []; _eventCursor = 0; }); await _refresh(); } catch (error) { if (mounted) setState(() => _error = 'Could not delete benchmark run: $error'); } }
  Future<void> _deleteBenchmark(Benchmark benchmark) async { final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Delete benchmark?'), content: Text('This removes ${benchmark.name} and all ${benchmark.runs.length} benchmark run(s).'), actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete'))])); if (confirmed != true) return; try { await _client.deleteBenchmark(benchmark.id); setState(() { _benchmark = null; _run = null; _events = const []; _eventCursor = 0; }); await _refresh(); } catch (error) { if (mounted) setState(() => _error = 'Could not delete benchmark: $error'); } }
}

class _BenchmarkDialog extends StatefulWidget {
  const _BenchmarkDialog({this.initial});

  final Benchmark? initial;

  @override
  State<_BenchmarkDialog> createState() => _BenchmarkDialogState();
}

class _BenchmarkDialogState extends State<_BenchmarkDialog> {
  final _mountedClient = const MountedFilesClient();
  late final TextEditingController _name;
  late final TextEditingController _creationDate;
  late final TextEditingController _runDate;
  late final TextEditingController _description;
  late final TextEditingController _lmStudioUrl;
  late final TextEditingController _frameSampleRate;
  late final TextEditingController _maxQaPairsPerVideo;
  late final TextEditingController _threshold;
  late final TextEditingController _outputFolder;
  late final TextEditingController _qaFiles;
  List<String> _selectedQaFiles = const [];
  var _saveFrames = false;
  var _batch = true;
  var _skipThreshold = true;

  @override
  void initState() {
    super.initState();
    final b = widget.initial;
    _selectedQaFiles = b?.qaFiles ?? const [];
    _name = TextEditingController(text: b?.name ?? '');
    _creationDate = TextEditingController(text: b?.creationDate ?? DateTime.now().toUtc().toIso8601String());
    _runDate = TextEditingController(text: b?.runDate ?? '');
    _description = TextEditingController(text: b?.description ?? '');
    _lmStudioUrl = TextEditingController(text: b?.lmStudioUrl ?? 'http://host.docker.internal:1234/v1');
    _frameSampleRate = TextEditingController(text: b == null ? '15' : '${b.frameSampleRate}');
    _maxQaPairsPerVideo = TextEditingController(text: b == null ? '-1' : '${b.maxQaPairsPerVideo}');
    _threshold = TextEditingController(text: b == null ? '25' : '${b.evidenceDurationThresholdSeconds}');
    _outputFolder = TextEditingController(text: b?.outputFolder ?? 'benchmark_runs');
    _qaFiles = TextEditingController(text: _selectedQaFiles.join('\n'));
    _saveFrames = b?.saveSampleFrames ?? false;
    _batch = b?.batchSameEvidenceSpans ?? true;
    _skipThreshold = b?.skipEvidenceAboveThreshold ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _creationDate.dispose();
    _runDate.dispose();
    _description.dispose();
    _lmStudioUrl.dispose();
    _frameSampleRate.dispose();
    _maxQaPairsPerVideo.dispose();
    _threshold.dispose();
    _outputFolder.dispose();
    _qaFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(editing ? 'Edit benchmark' : 'Create benchmark', style: Theme.of(context).textTheme.titleLarge)),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(children: [
                    _field(_name, 'Name'),
                    const SizedBox(height: 12),
                    _field(_creationDate, 'creation_date'),
                    const SizedBox(height: 12),
                    _field(_runDate, 'run_date'),
                    const SizedBox(height: 12),
                    _field(_description, 'Description', maxLines: 3),
                    const SizedBox(height: 12),
                    _field(_lmStudioUrl, 'LM Studio URL'),
                    const SizedBox(height: 12),
                    _field(_frameSampleRate, 'Frame Sample Rate', keyboardType: TextInputType.number),
                    const SizedBox(height: 12),
                    _field(_maxQaPairsPerVideo, 'Max QA pairs per Video', keyboardType: TextInputType.number),
                    const Align(alignment: Alignment.centerLeft, child: Text('-1 means unlimited. The limit applies separately to each selected QA file; evidence-threshold skips do not use this allowance.')),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Save sample frames'), value: _saveFrames, onChanged: (value) => setState(() => _saveFrames = value)),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Batch process QA Pairs with same evidence spans'), value: _batch, onChanged: (value) => setState(() => _batch = value)),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('skip QA pairs with evidence span above threshold'), value: _skipThreshold, onChanged: (value) => setState(() => _skipThreshold = value)),
                    if (_skipThreshold) ...[
                      const SizedBox(height: 12),
                      _field(_threshold, 'Maximum evidence duration in seconds', keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    ],
                    const SizedBox(height: 12),
                    _field(_outputFolder, 'output folder', readOnly: true),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.rule_folder),
                      title: const Text('QA files'),
                      subtitle: Text(_selectedQaFiles.isEmpty ? 'No qa_pairs.json files selected.' : '${_selectedQaFiles.length} file(s) selected'),
                      trailing: FilledButton.tonal(onPressed: _selectQaFiles, child: const Text('Browse')),
                    ),
                    if (_selectedQaFiles.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_selectedQaFiles.join('\n'), maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFCBD5E1))),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const Spacer(),
                FilledButton.icon(onPressed: _submit, icon: Icon(editing ? Icons.save : Icons.add), label: Text(editing ? 'Save' : 'Create')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label, {int maxLines = 1, TextInputType? keyboardType, bool readOnly = false}) => TextField(controller: controller, maxLines: maxLines, keyboardType: keyboardType, readOnly: readOnly, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()));

  Future<void> _selectQaFiles() async {
    final selected = await showDialog<List<String>>(context: context, builder: (context) => _QaFilePickerDialog(client: _mountedClient, initialSelection: _selectedQaFiles));
    if (selected != null) setState(() { _selectedQaFiles = selected; _qaFiles.text = selected.join('\n'); });
  }

  void _submit() {
    final frameSampleRate = int.tryParse(_frameSampleRate.text.trim());
    final maxQaPairsPerVideo = int.tryParse(_maxQaPairsPerVideo.text.trim());
    final threshold = double.tryParse(_threshold.text.trim());
    if (_name.text.trim().isEmpty || frameSampleRate == null || frameSampleRate < 1 || maxQaPairsPerVideo == null || (maxQaPairsPerVideo != -1 && maxQaPairsPerVideo < 1) || _selectedQaFiles.isEmpty || (_skipThreshold && (threshold == null || threshold <= 0))) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name, valid numeric values, and QA files are required. Max QA pairs per Video must be -1 or a positive integer.')));
      return;
    }
    Navigator.of(context).pop(BenchmarkCreateRequest(name: _name.text.trim(), creationDate: _creationDate.text.trim(), runDate: _runDate.text.trim(), description: _description.text.trim(), lmStudioUrl: _lmStudioUrl.text.trim(), frameSampleRate: frameSampleRate, maxQaPairsPerVideo: maxQaPairsPerVideo, saveSampleFrames: _saveFrames, batchSameEvidenceSpans: _batch, skipEvidenceAboveThreshold: _skipThreshold, evidenceDurationThresholdSeconds: threshold ?? 25, outputFolder: _outputFolder.text.trim().isEmpty ? 'benchmark_runs' : _outputFolder.text.trim(), qaFiles: _selectedQaFiles));
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

  Future<MountedFileListing> _loadListing() => widget.client.list(path: _path, kind: 'all');

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
              Expanded(child: _buildListing()),
              const SizedBox(height: 12),
              Row(children: [
                Text('${_selected.length} selected'),
                const Spacer(),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => Navigator.of(context).pop(_selected.toList()..sort()), child: const Text('Apply')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListing() {
    if (_busy) return const Center(child: CircularProgressIndicator());
    return FutureBuilder<MountedFileListing>(
      future: _listingFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: Text('Could not browse mounted files: ${snapshot.error}'));
        final listing = snapshot.data!;
        return Column(children: [
          Row(children: [
            Expanded(child: Text(listing.path.isEmpty ? '/' : listing.path, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (listing.parent != null) TextButton.icon(onPressed: () => _goTo(listing.parent!), icon: const Icon(Icons.arrow_upward), label: const Text('Up')),
          ]),
          const Divider(),
          Expanded(
            child: ListView.separated(
              itemCount: listing.entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) => _buildEntry(listing.entries[index]),
            ),
          ),
        ]);
      },
    );
  }

  Widget _buildEntry(MountedFileEntry entry) {
    final isQaFile = entry.isFile && entry.name == 'qa_pairs.json';
    if (entry.isDirectory) {
      return ListTile(
        leading: const Icon(Icons.folder),
        title: Text(entry.name),
        subtitle: Text(entry.path),
        trailing: FilledButton.tonal(onPressed: () => _selectNested(entry.path), child: const Text('Select nested')),
        onTap: () => _goTo(entry.path),
      );
    }
    return CheckboxListTile(
      value: _selected.contains(entry.path),
      onChanged: isQaFile ? (_) => _toggle(entry.path) : null,
      secondary: const Icon(Icons.description),
      title: Text(entry.name),
      subtitle: Text(entry.path),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }

  void _goTo(String path) {
    setState(() { _path = path; _listingFuture = _loadListing(); });
  }

  void _toggle(String path) {
    setState(() { if (!_selected.remove(path)) _selected.add(path); });
  }

  Future<void> _selectNested(String path) async {
    setState(() => _busy = true);
    try {
      final next = {..._selected};
      await _collectQaFiles(path, next);
      setState(() => _selected = next);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _collectQaFiles(String path, Set<String> selected) async {
    final listing = await widget.client.list(path: path, kind: 'all');
    for (final entry in listing.entries) {
      if (entry.isFile && entry.name == 'qa_pairs.json') selected.add(entry.path);
      if (entry.isDirectory) await _collectQaFiles(entry.path, selected);
    }
  }
}

class _AddRunDialog extends StatefulWidget { const _AddRunDialog(); @override State<_AddRunDialog> createState() => _AddRunDialogState(); }
class _AddRunDialogState extends State<_AddRunDialog> { final _model = TextEditingController(text: 'google/gemma-4-31b'); @override void dispose() { _model.dispose(); super.dispose(); } @override Widget build(BuildContext context) => AlertDialog(title: const Text('Add benchmark run'), content: TextField(controller: _model, decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder())), actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')), FilledButton(onPressed: () { if (_model.text.trim().isEmpty) return; Navigator.of(context).pop(BenchmarkRunCreateRequest(model: _model.text.trim())); }, child: const Text('Add'))]); }
class _InfoChip extends StatelessWidget { const _InfoChip({required this.label, required this.value}); final String label; final String value; @override Widget build(BuildContext context) => Chip(label: Text('$label: $value')); }
class _MetricRow extends StatelessWidget { const _MetricRow({required this.name, required this.bucket}); final String name; final BenchmarkMetricBucket bucket; @override Widget build(BuildContext context) => Row(children: [Expanded(child: Text(name)), Text('${bucket.percent.toStringAsFixed(1)}% (${bucket.correct}/${bucket.count})')]); }
class _MetricSection extends StatelessWidget { const _MetricSection({required this.title, required this.buckets}); final String title; final Map<String, BenchmarkMetricBucket> buckets; @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.titleSmall), if (buckets.isEmpty) const Text('No data yet.') else ...buckets.entries.map((entry) => _MetricRow(name: entry.key, bucket: entry.value))]); }
T? _firstOrNull<T>(Iterable<T> values) => values.isEmpty ? null : values.first;

Map<String, BenchmarkMetricBucket> _orderedFamilyBuckets(Map<String, BenchmarkMetricBucket> buckets) {
  const families = ['action_event', 'day_night_robustness', 'object_attribute', 'temporal_reasoning', 'trajectory_grounded'];
  const empty = BenchmarkMetricBucket(correct: 0, count: 0, percent: 0);
  return {for (final family in families) family: buckets[family] ?? empty};
}

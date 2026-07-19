import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/benchmark_models.dart';
import '../services/benchmarks_client.dart';
import '../services/qa_pairs_client.dart';

class QaPairsPage extends StatefulWidget {
  const QaPairsPage({super.key});

  @override
  State<QaPairsPage> createState() => _QaPairsPageState();
}

class _QaPairsPageState extends State<QaPairsPage> {
  final _benchmarksClient = const BenchmarksClient();
  final _qaPairsClient = const QaPairsClient();
  List<BenchmarkRun> _runs = const [];
  Set<String> _selectedRunIds = const {};
  List<AlwaysWrongQaPair> _alwaysWrong = const [];
  String? _error;
  var _loading = true;
  var _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadRuns();
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
                          Text('QA Pairs', style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 4),
                          Text(
                            'Inspect QA-pair performance across selected benchmark runs.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8)),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _refreshing ? null : _refreshAlwaysWrong,
                      icon: _refreshing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
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
                      SizedBox(width: 430, child: _buildRunSelector()),
                      const SizedBox(width: 18),
                      Expanded(child: _buildAlwaysWrong()),
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

  Widget _buildRunSelector() {
    if (_loading) {
      return const Card(child: Center(child: CircularProgressIndicator()));
    }
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text('Benchmark runs', style: Theme.of(context).textTheme.titleMedium)),
                TextButton(onPressed: _selectAllRuns, child: const Text('All')),
                TextButton(onPressed: () => setState(() => _selectedRunIds = {}), child: const Text('None')),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _runs.length,
              itemBuilder: (context, index) {
                final run = _runs[index];
                final selected = _selectedRunIds.contains(run.id);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (_) => _toggleRun(run.id),
                  title: Text(run.name.isEmpty ? run.id : run.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${run.status} - ${run.id}', maxLines: 1, overflow: TextOverflow.ellipsis),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlwaysWrong() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Always-wrong QA Pairs', style: Theme.of(context).textTheme.titleLarge)),
                Text('${_alwaysWrong.length} item(s)', style: const TextStyle(color: Color(0xFF94A3B8))),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _alwaysWrong.isEmpty
                  ? const Center(child: Text('Refresh to find QA pairs that were never answered correctly.'))
                  : ListView.separated(
                      itemCount: _alwaysWrong.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _alwaysWrong[index];
                        return ListTile(
                          leading: Icon(item.blacklisted ? Icons.block : Icons.quiz),
                          title: Text(item.question, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text('QA ${item.qaId} - ${item.videoId} - attempts: ${item.attempts}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: item.blacklisted ? const Text('blacklisted') : null,
                          onTap: () => _openEditor(index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadRuns() async {
    try {
      final runs = await _benchmarksClient.listRuns();
      setState(() {
        _runs = runs;
        _selectedRunIds = runs.map((run) => run.id).toSet();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      setState(() {
        _error = 'Could not load benchmark runs: $error';
        _loading = false;
      });
    }
  }

  void _selectAllRuns() {
    setState(() => _selectedRunIds = _runs.map((run) => run.id).toSet());
  }

  void _toggleRun(String runId) {
    setState(() {
      final next = Set<String>.from(_selectedRunIds);
      if (!next.remove(runId)) {
        next.add(runId);
      }
      _selectedRunIds = next;
    });
  }

  Future<void> _refreshAlwaysWrong() async {
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final items = await _qaPairsClient.alwaysWrong(runIds: _selectedRunIds.toList()..sort());
      setState(() => _alwaysWrong = items);
    } catch (error) {
      setState(() => _error = 'Could not refresh always-wrong QA pairs: $error');
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _openEditor(int index) async {
    final updated = await showDialog<_QaPairEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _QaPairEditorDialog(items: _alwaysWrong, initialIndex: index, client: _qaPairsClient),
    );
    if (updated == null) {
      return;
    }
    setState(() => _alwaysWrong = updated.items);
  }
}

class _QaPairEditResult {
  const _QaPairEditResult(this.items);

  final List<AlwaysWrongQaPair> items;
}

class _QaPairEditorDialog extends StatefulWidget {
  const _QaPairEditorDialog({required this.items, required this.initialIndex, required this.client});

  final List<AlwaysWrongQaPair> items;
  final int initialIndex;
  final QaPairsClient client;

  @override
  State<_QaPairEditorDialog> createState() => _QaPairEditorDialogState();
}

class _QaPairEditorDialogState extends State<_QaPairEditorDialog> {
  late List<AlwaysWrongQaPair> _items;
  late int _index;
  late final TextEditingController _jsonController;
  late final FocusNode _focusNode;
  String? _error;
  var _saving = false;

  AlwaysWrongQaPair get _item => _items[_index];

  @override
  void initState() {
    super.initState();
    _items = List<AlwaysWrongQaPair>.from(widget.items);
    _index = widget.initialIndex;
    _jsonController = TextEditingController();
    _focusNode = FocusNode();
    _loadCurrentJson();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _jsonController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: (event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyB) {
            _toggleBlacklist();
          }
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 860),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Edit annotation', style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(onPressed: _close, icon: const Icon(Icons.close), tooltip: 'Close'),
                  ],
                ),
                Text('QA ${_index + 1}/${_items.length} - ${_item.qaFile}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF94A3B8))),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('blacklisted'),
                  subtitle: const Text('Shortcut: b'),
                  value: _item.blacklisted,
                  onChanged: (_) => _toggleBlacklist(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: _jsonController,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(labelText: 'QA pair JSON', border: OutlineInputBorder()),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    TextButton.icon(onPressed: _saving ? null : _deleteCurrent, icon: const Icon(Icons.delete), label: const Text('Delete')),
                    const Spacer(),
                    TextButton(onPressed: _saving ? null : _saveCurrent, child: const Text('Save')),
                    const SizedBox(width: 8),
                    FilledButton.icon(onPressed: _saving || _items.isEmpty ? null : _nextQa, icon: const Icon(Icons.skip_next), label: const Text('Next QA')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _loadCurrentJson() {
    _jsonController.text = const JsonEncoder.withIndent('  ').convert(_item.qaPair);
  }

  Map<String, dynamic> _parsedJson() {
    final decoded = jsonDecode(_jsonController.text);
    if (decoded is! Map) {
      throw const FormatException('QA pair JSON must be an object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _saveCurrent() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final parsed = _parsedJson();
      await widget.client.updateQaPair(qaFile: _item.qaFile, qaId: _item.qaId, qaPair: parsed);
      setState(() => _items[_index] = _item.copyWith(qaPair: parsed));
    } catch (error) {
      setState(() => _error = 'Could not save QA pair: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deleteCurrent() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.client.deleteQaPair(qaFile: _item.qaFile, qaId: _item.qaId);
      var shouldClose = false;
      setState(() {
        _items.removeAt(_index);
        if (_items.isEmpty) {
          shouldClose = true;
          return;
        }
        if (_index >= _items.length) {
          _index = _items.length - 1;
        }
        _loadCurrentJson();
      });
      if (shouldClose && mounted) {
        _close();
      }
    } catch (error) {
      setState(() => _error = 'Could not delete QA pair: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _toggleBlacklist() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final next = !_item.blacklisted;
      final applied = await widget.client.setBlacklisted(qaFile: _item.qaFile, qaPair: _item.qaPair, blacklisted: next);
      setState(() => _items[_index] = _item.copyWith(blacklisted: applied));
    } catch (error) {
      setState(() => _error = 'Could not update blacklist: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _nextQa() {
    setState(() {
      _index = (_index + 1) % _items.length;
      _error = null;
      _loadCurrentJson();
    });
  }

  void _close() {
    Navigator.of(context).pop(_QaPairEditResult(_items));
  }
}

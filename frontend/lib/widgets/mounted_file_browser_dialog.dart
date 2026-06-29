import 'package:flutter/material.dart';

import '../services/mounted_files_client.dart';

class MountedFileSelection {
  const MountedFileSelection({required this.video, this.csv, this.metadata});

  final MountedFileEntry video;
  final MountedFileEntry? csv;
  final MountedFileEntry? metadata;
}

class MountedFileBrowserDialog extends StatefulWidget {
  const MountedFileBrowserDialog({
    super.key,
    this.client = const MountedFilesClient(),
  });

  final MountedFilesClient client;

  @override
  State<MountedFileBrowserDialog> createState() => _MountedFileBrowserDialogState();
}

class _MountedFileBrowserDialogState extends State<MountedFileBrowserDialog> {
  var _path = '';
  var _selectingCsv = false;
  MountedFileEntry? _selectedVideo;
  MountedFileEntry? _selectedCsv;
  late Future<MountedFileListing> _listingFuture;

  String get _kind => 'all';

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
                  Icon(
                    _selectingCsv ? Icons.data_object : Icons.video_library,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _selectingCsv ? 'Select optional metadata' : 'Select mounted video file',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _selectingCsv
                    ? 'Choose a saved metadata JSON or CSV report for ${_selectedVideo?.name ?? 'the selected video'}, or load without metadata.'
                    : 'Browse files mounted from the input directory and select a video first. CSV and JSON files are shown for reference.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 16),
              _SelectionSummary(video: _selectedVideo, csv: _selectedCsv),
              const SizedBox(height: 12),
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
                  if (_selectingCsv)
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectingCsv = false;
                          _selectedCsv = null;
                          _path = _selectedVideo?.path.split('/').length == 1
                              ? ''
                              : _selectedVideo!.path.split('/').sublist(0, _selectedVideo!.path.split('/').length - 1).join('/');
                          _listingFuture = _loadListing();
                        });
                      },
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _primaryActionEnabled ? _handlePrimaryAction : null,
                    icon: Icon(_selectingCsv ? Icons.play_circle : Icons.arrow_forward),
                    label: Text(_selectingCsv ? 'Load' : 'Next'),
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
        child: Text(
          'No supported video, CSV, or JSON files in this directory.',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
      );
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.path == (_selectingCsv ? _selectedCsv?.path : _selectedVideo?.path);
        final selectable = entry.isDirectory || (_selectingCsv ? entry.isCsv || entry.isJson : entry.isVideo);
        return ListTile(
          leading: Icon(entry.isDirectory ? Icons.folder : _iconForFile(entry)),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            entry.isDirectory ? 'Directory' : '${entry.kind.toUpperCase()} - ${entry.path}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: selectable,
          selected: selected,
          trailing: selected ? const Icon(Icons.check_circle) : null,
          onTap: () {
            if (entry.isDirectory) {
              _openDirectory(entry.path);
              return;
            }
            setState(() {
              if (_selectingCsv) {
                _selectedCsv = entry;
              } else {
                _selectedVideo = entry;
              }
            });
            if (_selectingCsv && entry.isJson && _selectedVideo != null) {
              Navigator.of(context).pop(MountedFileSelection(video: _selectedVideo!, metadata: entry));
            }
          },
        );
      },
    );
  }

  bool get _primaryActionEnabled => _selectingCsv ? _selectedVideo != null : _selectedVideo != null;

  void _handlePrimaryAction() {
    final video = _selectedVideo;
    if (video == null) {
      return;
    }
    if (!_selectingCsv) {
      setState(() {
        _selectingCsv = true;
        _selectedCsv = null;
        _path = _directoryOf(video.path);
        _listingFuture = _loadListing();
      });
      return;
    }
    Navigator.of(context).pop(MountedFileSelection(
      video: video,
      csv: _selectedCsv?.isCsv == true ? _selectedCsv : null,
      metadata: _selectedCsv?.isJson == true ? _selectedCsv : null,
    ));
  }

  IconData _iconForFile(MountedFileEntry entry) {
    if (entry.isCsv) {
      return Icons.table_chart;
    }
    if (entry.isJson) {
      return Icons.data_object;
    }
    return Icons.movie;
  }

  void _openDirectory(String path) {
    setState(() {
      _path = path;
      _listingFuture = _loadListing();
    });
  }

  Future<MountedFileListing> _loadListing() => widget.client.list(path: _path, kind: _kind);

  String _directoryOf(String path) {
    final parts = path.split('/');
    if (parts.length <= 1) {
      return '';
    }
    return parts.sublist(0, parts.length - 1).join('/');
  }
}

class _SelectionSummary extends StatelessWidget {
  const _SelectionSummary({required this.video, required this.csv});

  final MountedFileEntry? video;
  final MountedFileEntry? csv;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0x121E293B),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryLine(label: 'Video', value: video?.path ?? 'Not selected'),
            const SizedBox(height: 6),
            _SummaryLine(label: 'Metadata', value: csv?.path ?? 'Optional, not selected'),
          ],
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8))),
        ),
        Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

class _DialogError extends StatelessWidget {
  const _DialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFFCA5A5)),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';

typedef DropzoneFilesSelected = Future<void> Function(
  DropzoneViewController controller,
  List<dynamic> files,
);

typedef DropzoneFileSelected = Future<void> Function(
  DropzoneViewController controller,
  dynamic file,
);

class DropZonePanel extends StatefulWidget {
  const DropZonePanel({
    super.key,
    required this.onFilesSelected,
    required this.hasVideo,
  });

  final DropzoneFilesSelected onFilesSelected;
  final bool hasVideo;

  @override
  State<DropZonePanel> createState() => _DropZonePanelState();
}

class AnnotationDropZonePanel extends StatefulWidget {
  const AnnotationDropZonePanel({
    super.key,
    required this.onFileSelected,
    required this.filename,
  });

  final DropzoneFileSelected onFileSelected;
  final String? filename;

  @override
  State<AnnotationDropZonePanel> createState() => _AnnotationDropZonePanelState();
}

class _AnnotationDropZonePanelState extends State<AnnotationDropZonePanel> {
  DropzoneViewController? _controller;
  var _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = _isHovering
        ? const Color(0xFFFACC15)
        : const Color(0xFF334155);

    return Card(
      child: SizedBox(
        height: 104,
        child: Stack(
          children: [
            DropzoneView(
              operation: DragOperation.copy,
              cursor: CursorType.grab,
              onCreated: (controller) => _controller = controller,
              onHover: () => setState(() => _isHovering = true),
              onLeave: () => setState(() => _isHovering = false),
              onDropFiles: (files) async {
                setState(() => _isHovering = false);
                if (files == null || files.isEmpty) {
                  return;
                }
                await widget.onFileSelected(_controller!, files.first);
              },
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: borderColor, width: 1.4),
                    color: _isHovering
                        ? const Color(0x22FACC15)
                        : const Color(0x081E293B),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    const Icon(Icons.star, color: Color(0xFFFACC15), size: 30),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.filename == null
                                ? 'Optional annotation JSON'
                                : 'Annotation JSON: ${widget.filename}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Drop or browse a benchmark annotation file.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF94A3B8),
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse JSON'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    final files = await controller.pickFiles(
      multiple: false,
      mime: const ['application/json', 'text/json'],
    );
    if (files.isEmpty) {
      return;
    }
    await widget.onFileSelected(controller, files.first);
  }
}

class _DropZonePanelState extends State<DropZonePanel> {
  DropzoneViewController? _controller;
  var _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = _isHovering
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFF334155);

    return Card(
      child: SizedBox(
        height: widget.hasVideo ? 132 : 190,
        child: Stack(
          children: [
            DropzoneView(
              operation: DragOperation.copy,
              cursor: CursorType.grab,
              onCreated: (controller) => _controller = controller,
              onHover: () => setState(() => _isHovering = true),
              onLeave: () => setState(() => _isHovering = false),
              onDropFiles: (files) async {
                setState(() => _isHovering = false);
                if (files == null || files.isEmpty) {
                  return;
                }
                await widget.onFilesSelected(_controller!, List<dynamic>.from(files));
              },
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: borderColor, width: 1.4),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _isHovering
                          ? const [Color(0x3334D399), Color(0x221D4ED8)]
                          : const [Color(0x121E293B), Color(0x081D4ED8)],
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      widget.hasVideo ? Icons.add_chart : Icons.upload_file,
                      size: 34,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.hasVideo
                          ? 'Drop a replacement video or optional CSV report'
                          : 'Drop a video and optional analyzer CSV report',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Accepted: video files and video_analyzer CSV reports',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF94A3B8),
                          ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      onPressed: _pickFiles,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse files'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    final files = await controller.pickFiles(
      multiple: true,
      mime: const [
        'video/*',
        'video/mp4',
        'video/quicktime',
        'text/csv',
        'application/csv',
        'application/vnd.ms-excel',
      ],
    );
    if (files.isEmpty) {
      return;
    }
    await widget.onFilesSelected(controller, List<dynamic>.from(files));
  }
}

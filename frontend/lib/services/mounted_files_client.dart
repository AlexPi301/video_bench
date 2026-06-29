import 'dart:convert';
import 'dart:html' as html;

class MountedFileEntry {
  const MountedFileEntry({
    required this.name,
    required this.path,
    required this.type,
    required this.kind,
    this.url,
  });

  final String name;
  final String path;
  final String type;
  final String kind;
  final String? url;

  bool get isDirectory => type == 'directory';
  bool get isFile => type == 'file';
  bool get isVideo => kind == 'video';
  bool get isCsv => kind == 'csv';
  bool get isJson => kind == 'json';

  factory MountedFileEntry.fromJson(Map<String, dynamic> json) {
    return MountedFileEntry(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      url: json['url']?.toString(),
    );
  }
}

class MountedFileListing {
  const MountedFileListing({
    required this.path,
    required this.entries,
    this.parent,
  });

  final String path;
  final String? parent;
  final List<MountedFileEntry> entries;

  factory MountedFileListing.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return MountedFileListing(
      path: json['path']?.toString() ?? '',
      parent: json['parent']?.toString(),
      entries: rawEntries is List
          ? rawEntries
              .whereType<Map>()
              .map((entry) => MountedFileEntry.fromJson(Map<String, dynamic>.from(entry)))
              .toList(growable: false)
          : const [],
    );
  }
}

class MountedFilesClient {
  const MountedFilesClient();

  Future<MountedFileListing> list({required String path, required String kind}) async {
    final uri = Uri(
      path: '/api/mounted-files/',
      queryParameters: {
        'path': path,
        'kind': kind,
      },
    );
    final response = await html.HttpRequest.getString(uri.toString());
    return MountedFileListing.fromJson(jsonDecode(response) as Map<String, dynamic>);
  }

  Future<MountedFileEntry> saveJson({required String path, required String content}) async {
    final response = await html.HttpRequest.request(
      '/api/mounted-files/save/',
      method: 'POST',
      sendData: jsonEncode({'path': path, 'content': content}),
      requestHeaders: {'Content-Type': 'application/json'},
    );
    final body = response.responseText ?? '{}';
    return MountedFileEntry.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }
}

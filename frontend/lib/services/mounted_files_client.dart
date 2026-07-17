import 'dart:convert';
import 'dart:html' as html;

class MountedFilesException implements Exception {
  const MountedFilesException(this.message);

  final String message;

  @override
  String toString() => message;
}

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
    html.HttpRequest response;
    try {
      response = await html.HttpRequest.request(
        '/api/mounted-files/save/',
        method: 'POST',
        sendData: jsonEncode({'path': path, 'content': content}),
        requestHeaders: {'Content-Type': 'application/json'},
      );
    } on html.ProgressEvent catch (error) {
      final request = error.target;
      if (request is html.HttpRequest) {
        throw MountedFilesException(_saveErrorMessage(request, path));
      }
      throw MountedFilesException('Could not save $path: network request failed before the server returned a response.');
    }

    final body = response.responseText ?? '{}';
    try {
      return MountedFileEntry.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on FormatException catch (error) {
      throw MountedFilesException('Could not parse save response for $path: ${error.message}. Response body: $body');
    } catch (error) {
      throw MountedFilesException('Could not parse save response for $path: $error. Response body: $body');
    }
  }

  String _saveErrorMessage(html.HttpRequest request, String path) {
    final status = request.status ?? 0;
    final statusText = request.statusText ?? '';
    final body = request.responseText ?? '';
    final serverMessage = _serverErrorMessage(body);
    final statusPart = status == 0 ? 'network error' : 'HTTP $status${statusText.isEmpty ? '' : ' $statusText'}';
    if (serverMessage.isNotEmpty) {
      return 'Could not save $path: $serverMessage ($statusPart).';
    }
    if (body.trim().isNotEmpty) {
      return 'Could not save $path: server returned $statusPart. Response body: $body';
    }
    return 'Could not save $path: server returned $statusPart with an empty response body.';
  }

  String _serverErrorMessage(String body) {
    if (body.trim().isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error']?.toString() ?? '';
        if (error.isNotEmpty) {
          return error;
        }
        final detail = decoded['detail']?.toString() ?? '';
        if (detail.isNotEmpty) {
          return detail;
        }
      }
    } catch (_) {
      return '';
    }
    return '';
  }
}

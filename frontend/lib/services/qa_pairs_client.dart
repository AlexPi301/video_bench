import 'dart:convert';
import 'dart:html' as html;

class AlwaysWrongQaPair {
  const AlwaysWrongQaPair({
    required this.qaFile,
    required this.qaPair,
    required this.attempts,
    required this.runIds,
    required this.blacklisted,
  });

  final String qaFile;
  final Map<String, dynamic> qaPair;
  final int attempts;
  final List<String> runIds;
  final bool blacklisted;

  String get qaId => qaPair['id']?.toString() ?? qaPair['qa_id']?.toString() ?? '';
  String get question => qaPair['question']?.toString() ?? '';
  String get videoId => qaPair['video_id']?.toString() ?? '';

  AlwaysWrongQaPair copyWith({Map<String, dynamic>? qaPair, bool? blacklisted}) {
    return AlwaysWrongQaPair(
      qaFile: qaFile,
      qaPair: qaPair ?? this.qaPair,
      attempts: attempts,
      runIds: runIds,
      blacklisted: blacklisted ?? this.blacklisted,
    );
  }

  factory AlwaysWrongQaPair.fromJson(Map<String, dynamic> json) {
    final rawPair = json['qaPair'];
    final rawRuns = json['runIds'];
    return AlwaysWrongQaPair(
      qaFile: json['qaFile']?.toString() ?? '',
      qaPair: Map<String, dynamic>.from((rawPair as Map?) ?? const {}),
      attempts: _int(json['attempts']),
      runIds: rawRuns is List ? rawRuns.map((item) => item.toString()).toList(growable: false) : const [],
      blacklisted: json['blacklisted'] == true,
    );
  }
}

class QaPairsClient {
  const QaPairsClient();

  Future<List<AlwaysWrongQaPair>> alwaysWrong({required List<String> runIds}) async {
    final response = await html.HttpRequest.request(
      '/api/qa-pairs/always-wrong/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode({'runIds': runIds}),
    );
    final json = jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>;
    final rawItems = json['items'];
    return rawItems is List
        ? rawItems.whereType<Map>().map((item) => AlwaysWrongQaPair.fromJson(Map<String, dynamic>.from(item))).toList(growable: false)
        : const [];
  }

  Future<void> updateQaPair({required String qaFile, required String qaId, required Map<String, dynamic> qaPair}) async {
    await html.HttpRequest.request(
      '/api/qa-pairs/update/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode({'qaFile': qaFile, 'qaId': qaId, 'qaPair': qaPair}),
    );
  }

  Future<void> deleteQaPair({required String qaFile, required String qaId}) async {
    await html.HttpRequest.request(
      '/api/qa-pairs/delete/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode({'qaFile': qaFile, 'qaId': qaId}),
    );
  }

  Future<bool> setBlacklisted({required String qaFile, required Map<String, dynamic> qaPair, required bool blacklisted}) async {
    final response = await html.HttpRequest.request(
      '/api/qa-pairs/blacklist/set/',
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json'},
      sendData: jsonEncode({'qaFile': qaFile, 'qaPair': qaPair, 'blacklisted': blacklisted}),
    );
    final json = jsonDecode(response.responseText ?? '{}') as Map<String, dynamic>;
    return json['blacklisted'] == true;
  }
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

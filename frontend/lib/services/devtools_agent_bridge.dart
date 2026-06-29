import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;

typedef AgentCommand = FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic> args);
typedef AgentStateProvider = Map<String, dynamic> Function();

class DevtoolsAgentBridge {
  DevtoolsAgentBridge._();

  static final instance = DevtoolsAgentBridge._();

  final _commands = <String, _RegisteredCommand>{};
  final _stateProviders = <String, _RegisteredStateProvider>{};
  final _readyCompleter = Completer<void>();
  var _installed = false;
  js.JsObject? _apiObject;

  bool get installed => _installed;

  Future<void> enable() async {
    if (_installed) {
      return;
    }
    _installed = true;

    final api = js.JsObject(js.context['Object'] as js.JsFunction);
    api['version'] = 1;
    api['ready'] = _futureToPromise(_readyCompleter.future);
    api['call'] = js.allowInterop((String command, [dynamic args]) {
      return _futureToPromise(_call(command, args));
    });
    api['getState'] = js.allowInterop(() => js.JsObject.jsify(state));
    api['waitForState'] = js.allowInterop((dynamic predicate, [dynamic options]) {
      return _futureToPromise(_waitForState(predicate, options));
    });
    api['emitStateChanged'] = js.allowInterop(() {
      emitStateChanged();
      return js.JsObject.jsify(state);
    });

    _apiObject = api;
    js.context['videoBenchAgent'] = api;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    emitStateChanged();
  }

  Future<void> enableFromDebugConfig() async {
    try {
      final text = await html.HttpRequest.getString('/debug-config.json');
      final config = jsonDecode(text);
      if (config is Map && config['agentControl'] == true) {
        await enable();
      }
    } catch (error) {
      html.window.console.warn('Video Bench agent bridge was not enabled: $error');
    }
  }

  void registerCommand(Object owner, String name, AgentCommand command) {
    _commands[name] = _RegisteredCommand(owner, command);
  }

  void registerStateProvider(Object owner, String name, AgentStateProvider provider) {
    _stateProviders[name] = _RegisteredStateProvider(owner, provider);
    emitStateChanged();
  }

  void unregisterOwner(Object owner) {
    _commands.removeWhere((_, command) => identical(command.owner, owner));
    _stateProviders.removeWhere((_, provider) => identical(provider.owner, owner));
    emitStateChanged();
  }

  Map<String, dynamic> get state {
    final result = <String, dynamic>{
      'version': 1,
      'installed': _installed,
      'namespaces': _stateProviders.keys.toList()..sort(),
    };
    final entries = _stateProviders.entries.toList()..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in entries) {
      try {
        result[entry.key] = entry.value.provider();
      } catch (error) {
        result[entry.key] = {'error': error.toString()};
      }
    }
    return result;
  }

  void emitStateChanged() {
    if (!_installed) {
      return;
    }
    final currentState = state;
    final api = _apiObject;
    if (api != null) {
      api['lastState'] = js.JsObject.jsify(currentState);
    }
    html.window.dispatchEvent(html.CustomEvent('video-bench:state', detail: js.JsObject.jsify(currentState)));
  }

  Future<Object?> _call(String commandName, dynamic rawArgs) async {
    final command = _commands[commandName];
    if (command == null) {
      throw StateError('Unknown Video Bench agent command: $commandName');
    }
    final args = _argsMap(rawArgs);
    final result = await command.command(args);
    emitStateChanged();
    return js.JsObject.jsify(result ?? state);
  }

  Future<Object?> _waitForState(dynamic predicate, dynamic rawOptions) async {
    final options = _argsMap(rawOptions);
    final timeoutMs = _intOption(options['timeoutMs'], 10000);
    final intervalMs = _intOption(options['intervalMs'], 50);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));

    while (true) {
      final currentState = state;
      final matched = predicate == null || js_util.callMethod(predicate, 'call', [html.window, js.JsObject.jsify(currentState)]) == true;
      if (matched) {
        return js.JsObject.jsify(currentState);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for Video Bench agent state.', Duration(milliseconds: timeoutMs));
      }
      await Future<void>.delayed(Duration(milliseconds: intervalMs));
    }
  }

  Map<String, dynamic> _argsMap(dynamic rawArgs) {
    if (rawArgs == null) {
      return const {};
    }
    final jsonText = (js.context['JSON'] as js.JsObject).callMethod('stringify', [rawArgs])?.toString();
    if (jsonText == null || jsonText.isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(jsonText);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return const {};
  }

  int _intOption(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  Object _futureToPromise(Future<dynamic> future) {
    return js.JsObject(js.context['Promise'] as js.JsFunction, [
      js.allowInterop((dynamic resolve, dynamic reject) {
        future.then(
          (value) => (resolve as js.JsFunction).apply([value]),
          onError: (Object error) => (reject as js.JsFunction).apply([error.toString()]),
        );
      }),
    ]);
  }
}

class _RegisteredCommand {
  const _RegisteredCommand(this.owner, this.command);

  final Object owner;
  final AgentCommand command;
}

class _RegisteredStateProvider {
  const _RegisteredStateProvider(this.owner, this.provider);

  final Object owner;
  final AgentStateProvider provider;
}

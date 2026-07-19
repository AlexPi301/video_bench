import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'services/devtools_agent_bridge.dart';
import 'widgets/benchmarks_page.dart';
import 'widgets/impact_cycle_page.dart';
import 'widgets/qa_pairs_page.dart';
import 'widgets/video_bench_page.dart';

const _experimentalEnabled = bool.fromEnvironment('VIDEO_BENCH_EXPERIMENTAL');
SemanticsHandle? videoBenchAgentSemanticsHandle;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DevtoolsAgentBridge.instance.enable();
  videoBenchAgentSemanticsHandle = SemanticsBinding.instance.ensureSemantics();
  runApp(const VideoBenchApp());
}

class VideoBenchApp extends StatelessWidget {
  const VideoBenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF10141F);
    const panel = Color(0xFF171D2B);
    const accent = Color(0xFF6EE7B7);

    return MaterialApp(
      title: 'Video Bench',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: surface,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: Color(0xFF93C5FD),
          surface: panel,
        ),
        cardTheme: CardThemeData(
          color: panel,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF273044)),
          ),
        ),
      ),
      home: const _VideoBenchShell(),
    );
  }
}

class _VideoBenchShell extends StatefulWidget {
  const _VideoBenchShell();

  @override
  State<_VideoBenchShell> createState() => _VideoBenchShellState();
}

class _VideoBenchShellState extends State<_VideoBenchShell> {
  var _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _registerAgentHooks();
  }

  @override
  void dispose() {
    DevtoolsAgentBridge.instance.unregisterOwner(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Bench'),
        actions: [
          if (_experimentalEnabled)
            _NavButton(
              identifier: 'app.nav.qa-pairs',
              label: 'QA Pairs',
              selected: _selectedIndex == 1,
              onPressed: () => _selectPage(1),
            ),
          if (_experimentalEnabled)
            _NavButton(
              identifier: 'app.nav.benchmarks',
              label: 'Benchmarks',
              selected: _selectedIndex == 2,
              onPressed: () => _selectPage(2),
            ),
          _NavButton(
            identifier: 'app.nav.video-bench',
            label: 'Video Bench',
            selected: _selectedIndex == 0,
            onPressed: () => _selectPage(0),
          ),
          if (_experimentalEnabled)
            _NavButton(
              identifier: 'app.nav.impact-cycle',
              label: 'Impact Cycle',
              selected: _selectedIndex == 3,
              onPressed: () => _selectPage(3),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: IndexedStack(
        index: _stackIndex,
        children: const [
          VideoBenchPage(),
          if (_experimentalEnabled) QaPairsPage(),
          if (_experimentalEnabled) BenchmarksPage(),
          if (_experimentalEnabled) ImpactCyclePage(),
        ],
      ),
    );
  }

  void _selectPage(int index) {
    setState(() => _selectedIndex = index);
    DevtoolsAgentBridge.instance.emitStateChanged();
  }

  void _registerAgentHooks() {
    final bridge = DevtoolsAgentBridge.instance;
    bridge.registerStateProvider(this, 'app', () => {
          'selectedPage': _selectedPageName,
          'experimentalEnabled': _experimentalEnabled,
        });
    bridge.registerCommand(this, 'app.selectPage', (args) {
      final page = args['page']?.toString();
      if (page == 'impactCycle') {
        if (!_experimentalEnabled) {
          throw StateError('Impact Cycle is not enabled in this build.');
        }
        _selectPage(3);
      } else if (page == 'benchmarks') {
        if (!_experimentalEnabled) {
          throw StateError('Benchmarks is not enabled in this build.');
        }
        _selectPage(2);
      } else if (page == 'qaPairs') {
        if (!_experimentalEnabled) {
          throw StateError('QA Pairs is not enabled in this build.');
        }
        _selectPage(1);
      } else if (page == 'videoBench') {
        _selectPage(0);
      } else {
        throw ArgumentError('Expected page to be "videoBench", "qaPairs", "benchmarks", or "impactCycle".');
      }
      return bridge.state;
    });
  }

  int get _stackIndex {
    if (!_experimentalEnabled || _selectedIndex <= 0) {
      return 0;
    }
    return _selectedIndex;
  }

  String get _selectedPageName {
    if (_selectedIndex == 1) {
      return _experimentalEnabled ? 'qaPairs' : 'videoBench';
    }
    if (_selectedIndex == 2) {
      return _experimentalEnabled ? 'benchmarks' : 'videoBench';
    }
    if (_selectedIndex == 3) {
      return _experimentalEnabled ? 'impactCycle' : 'videoBench';
    }
    return 'videoBench';
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.identifier, required this.label, required this.selected, required this.onPressed});

  final String identifier;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        identifier: identifier,
        button: true,
        selected: selected,
        label: label,
        child: selected
            ? FilledButton.tonal(onPressed: onPressed, child: Text(label))
            : TextButton(onPressed: onPressed, child: Text(label)),
      ),
    );
  }
}

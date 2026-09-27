Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
import 'package:flutter_test/flutter_test.dart';
import 'package:video_bench_frontend/models/benchmark_models.dart';
import 'package:video_bench_frontend/services/benchmarks_client.dart';

void main() {
  test('old benchmark responses default max QA pairs per video to unlimited', () {
    final benchmark = Benchmark.fromJson({'id': 'legacy'});

    expect(benchmark.maxQaPairsPerVideo, -1);
  });

  test('benchmark response reads configured max QA pairs per video', () {
    final benchmark = Benchmark.fromJson({'id': 'limited', 'max_qa_pairs_per_video': 6});

    expect(benchmark.maxQaPairsPerVideo, 6);
  });

  test('benchmark request serializes max QA pairs per video', () {
    const request = BenchmarkCreateRequest(
      name: 'test',
      creationDate: '',
      runDate: '',
      description: '',
      lmStudioUrl: '',
      frameSampleRate: 15,
      maxQaPairsPerVideo: 4,
      saveSampleFrames: false,
      batchSameEvidenceSpans: true,
      skipEvidenceAboveThreshold: true,
      evidenceDurationThresholdSeconds: 25,
      outputFolder: 'benchmark_runs',
      qaFiles: ['video/qa_pairs.json'],
    );

    expect(request.toJson()['maxQaPairsPerVideo'], 4);
  });
}

Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
import csv
import json
import tempfile
import threading
from pathlib import Path
from unittest.mock import patch
from django.test import Client, SimpleTestCase
from video_bench_backend import benchmarks
from video_bench_backend.benchmarks import _parse_model_answer, _parse_model_answers_batch


class ModelResponseTests(SimpleTestCase):
    def setUp(self):
        self.items = [{"id": "qa_0001"}, {"id": "qa_0002"}]
        self.payload = {"answers": [
            {"qa_id": "qa_0001", "answer": True},
            {"qa_id": "qa_0002", "answer": True},
        ]}

    def test_lmstudio_repeats_batch_as_fenced_json(self):
        raw = json.dumps(self.payload) + '\n\n```json\n' + json.dumps(self.payload, indent=2) + '\n```'
        parsed = _parse_model_answers_batch(raw, self.items)
        self.assertEqual(set(parsed), {"qa_0001", "qa_0002"})
        self.assertTrue(all(row["answer"] is True for row in parsed.values()))

    def test_braces_inside_answer_string(self):
        raw = json.dumps({"answers": [{"qa_id": "qa_0001", "answer": 'A sign saying "{exit}"'}]})
        self.assertEqual(_parse_model_answers_batch(raw, self.items[:1])["qa_0001"]["answer"], 'A sign saying "{exit}"')

    def test_lmstudio_omits_final_closing_brace(self):
        raw = json.dumps(self.payload)[:-1]
        parsed = _parse_model_answers_batch(raw, self.items)
        self.assertEqual(set(parsed), {"qa_0001", "qa_0002"})

    def test_prose_and_unrelated_object_before_batch(self):
        raw = 'Note {not JSON}. {"note": "example"}\n' + json.dumps(self.payload)
        self.assertEqual(len(_parse_model_answers_batch(raw, self.items)), 2)

    def test_invalid_batch_is_not_accepted_as_success(self):
        for raw in ['No response', '{"answers": "wrong type"}', '{"answers": [']:
            with self.subTest(raw=raw), self.assertRaises(RuntimeError):
                _parse_model_answers_batch(raw, self.items)

    def test_null_answer_requires_individual_retry(self):
        raw = json.dumps({"answers": [
            {"qa_id": "qa_0001", "answer": True},
            {"qa_id": "qa_0002", "answer": None},
        ]})
        with self.assertRaisesRegex(RuntimeError, "empty answer"):
            _parse_model_answers_batch(raw, self.items)

    def test_repeated_single_answer_is_scored_as_boolean(self):
        raw = '{"answer": true, "unanswerable": false}\n```json\n{"answer": true}\n```'
        self.assertEqual(_parse_model_answer(raw), {"answer": True, "unanswerable": False})

    def test_incomplete_single_json_is_not_recorded_as_an_answer(self):
        self.assertEqual(_parse_model_answer('{"answer":'), {"answer": None, "unanswerable": False})

    def test_lmstudio_nested_json_answer(self):
        self.assertEqual(_parse_model_answer('{"json": {"answer": "right branch"}}'), {"answer": "right branch", "unanswerable": False})

    def test_batch_falls_back_to_individual_questions(self):
        items = [
            {"id": "qa_0001", "video_id": "test", "question": "First?", "answer": True, "answer_format": "yes_no"},
            {"id": "qa_0002", "video_id": "test", "question": "Second?", "answer": True, "answer_format": "yes_no"},
        ]
        responses = ['{"qa_0001": true, "qa_0002": true}', '{"answer": true}', '{"answer": true}']
        with patch.object(benchmarks, "_request_model_completion", side_effect=responses) as request, patch.object(benchmarks, "_append_execution_event"):
            rows = benchmarks._complete_answers_batch(None, {"model": "qwen3-vl-2b-instruct"}, items, [{"role": "user", "content": [{"type": "text", "text": "batch"}]}])
        self.assertEqual([row["qa_id"] for row in rows], ["qa_0001", "qa_0002"])
        self.assertEqual([row["parsed_model_answer"] for row in rows], ["True", "True"])
        self.assertEqual(request.call_count, 3)


class EvidenceFrameLimitTests(SimpleTestCase):
    def test_minus_one_preserves_all_sampled_frames(self):
        frames = list(range(100))
        with patch.dict(benchmarks.os.environ, {"VIDEO_BENCH_MAX_EVIDENCE_FRAMES": "-1"}):
            self.assertEqual(benchmarks._max_evidence_frames(), -1)
        with patch.object(benchmarks, "MAX_EVIDENCE_FRAMES", -1):
            self.assertEqual(benchmarks._limited_frame_indices(frames), frames)

    def test_positive_limit_still_reduces_frames(self):
        with patch.dict(benchmarks.os.environ, {"VIDEO_BENCH_MAX_EVIDENCE_FRAMES": "3"}):
            self.assertEqual(benchmarks._max_evidence_frames(), 3)
        with patch.object(benchmarks, "MAX_EVIDENCE_FRAMES", 3):
            self.assertEqual(len(benchmarks._limited_frame_indices(list(range(100)))), 3)

    def test_other_nonpositive_values_keep_minimum_of_one(self):
        for value in ("0", "-2"):
            with self.subTest(value=value), patch.dict(benchmarks.os.environ, {"VIDEO_BENCH_MAX_EVIDENCE_FRAMES": value}):
                self.assertEqual(benchmarks._max_evidence_frames(), 1)


class MaxQaPairsPerVideoTests(SimpleTestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        (self.root / "video_a").mkdir()
        (self.root / "video_b").mkdir()
        (self.root / "video_a" / "qa_pairs.json").write_text('{"qa_pairs": []}', encoding="utf-8")
        (self.root / "video_b" / "qa_pairs.json").write_text('{"qa_pairs": []}', encoding="utf-8")
        self.client = Client()

    def test_limit_is_per_file_and_evidence_skips_do_not_consume_allowance(self):
        def item(qa_id, qa_file, span_seconds=1):
            return {
                "id": qa_id,
                "_qa_file": qa_file,
                "evidence_spans": [{"start_seconds": 0, "end_seconds": span_seconds}],
            }

        questions = [
            item("a-long-first", "a/qa_pairs.json", 10),
            item("a-1", "a/qa_pairs.json"),
            item("a-2", "a/qa_pairs.json"),
            item("a-after-cap-long", "a/qa_pairs.json", 10),
            item("a-after-cap", "a/qa_pairs.json"),
            item("b-1", "b/qa_pairs.json"),
            item("b-2", "b/qa_pairs.json"),
            item("b-after-cap", "b/qa_pairs.json"),
        ]

        limited = benchmarks._limit_qa_pairs_per_file(
            questions,
            2,
            skip_evidence_above_threshold=True,
            evidence_duration_threshold=5,
        )

        self.assertEqual([item["id"] for item in limited], ["a-long-first", "a-1", "a-2", "b-1", "b-2"])

    def test_unlimited_keeps_every_question(self):
        questions = [{"id": "one", "_qa_file": "a"}, {"id": "two", "_qa_file": "a"}]
        self.assertIs(benchmarks._limit_qa_pairs_per_file(questions, -1, skip_evidence_above_threshold=False, evidence_duration_threshold=5), questions)

    def test_execution_caps_model_calls_per_file_and_continues_to_next_file(self):
        questions = [
            {"id": "a-skipped", "_qa_file": "a/qa_pairs.json", "evidence_spans": [{"start_seconds": 0, "end_seconds": 10}]},
            {"id": "a-1", "_qa_file": "a/qa_pairs.json", "evidence_spans": []},
            {"id": "a-after-cap", "_qa_file": "a/qa_pairs.json", "evidence_spans": []},
            {"id": "b-1", "_qa_file": "b/qa_pairs.json", "evidence_spans": []},
            {"id": "b-after-cap", "_qa_file": "b/qa_pairs.json", "evidence_spans": []},
        ]
        results_path = self.root / "results.csv"
        evaluated = []

        def answer(_cv2, _litellm, _run, item):
            evaluated.append(item["id"])
            return {"qa_id": item["id"]}

        with (
            patch.object(benchmarks, "_import_required", return_value=object()),
            patch.object(benchmarks, "_load_all_questions", return_value=questions),
            patch.object(benchmarks, "_answer_question", side_effect=answer),
            patch.object(benchmarks, "_results_path_for_run", return_value=results_path),
            patch.object(benchmarks, "_events_path_for_run", return_value=self.root / "events.jsonl"),
            patch.object(benchmarks, "_update_execution_run"),
            patch.object(benchmarks, "_append_execution_event"),
        ):
            benchmarks._execute_benchmark(
                {
                    "id": "run",
                    "qa_files": ["a/qa_pairs.json", "b/qa_pairs.json"],
                    "max_qa_pairs_per_video": 1,
                    "batch_same_evidence_spans": False,
                    "skip_evidence_above_threshold": True,
                    "evidence_duration_threshold_seconds": 5,
                },
                threading.Event(),
            )

        self.assertEqual(evaluated, ["a-1", "b-1"])
        with results_path.open(encoding="utf-8", newline="") as handle:
            self.assertEqual([row["qa_id"] for row in csv.DictReader(handle)], ["a-1", "b-1"])

    def test_batch_at_file_limit_contains_only_remaining_allowed_pairs(self):
        questions = [
            {"id": f"qa-{index}", "_qa_file": "a/qa_pairs.json", "video_id": "video-a", "evidence_spans": [{"start_seconds": 1, "end_seconds": 2}]}
            for index in range(4)
        ]
        batch_calls = []

        def answer_batch(_cv2, _litellm, _run, items):
            batch_calls.append([item["id"] for item in items])
            return [{"qa_id": item["id"]} for item in items]

        with (
            patch.object(benchmarks, "_import_required", return_value=object()),
            patch.object(benchmarks, "_load_all_questions", return_value=questions),
            patch.object(benchmarks, "_answer_questions_batch", side_effect=answer_batch),
            patch.object(benchmarks, "_results_path_for_run", return_value=self.root / "batch-results.csv"),
            patch.object(benchmarks, "_events_path_for_run", return_value=self.root / "batch-events.jsonl"),
            patch.object(benchmarks, "_update_execution_run"),
            patch.object(benchmarks, "_append_execution_event"),
        ):
            benchmarks._execute_benchmark(
                {
                    "id": "batch-run",
                    "qa_files": ["a/qa_pairs.json"],
                    "max_qa_pairs_per_video": 2,
                    "batch_same_evidence_spans": True,
                    "skip_evidence_above_threshold": False,
                },
                threading.Event(),
            )

        self.assertEqual(batch_calls, [["qa-0", "qa-1"]])

    def test_create_defaults_to_unlimited_and_update_persists_limit(self):
        with patch.object(benchmarks, "_mounted_root", return_value=self.root):
            created = self.client.post(
                "/api/benchmarks/create/",
                data=json.dumps({"name": "test", "qaFiles": ["video_a/qa_pairs.json"]}),
                content_type="application/json",
            )
            self.assertEqual(created.status_code, 201, created.content)
            benchmark = created.json()
            self.assertEqual(benchmark["max_qa_pairs_per_video"], -1)

            updated = self.client.post(
                f"/api/benchmarks/{benchmark['id']}/edit/",
                data=json.dumps({"name": "test", "qaFiles": ["video_a/qa_pairs.json"], "maxQaPairsPerVideo": 4}),
                content_type="application/json",
            )

        self.assertEqual(updated.status_code, 200, updated.content)
        self.assertEqual(updated.json()["max_qa_pairs_per_video"], 4)

    def test_create_rejects_invalid_limit_values(self):
        with patch.object(benchmarks, "_mounted_root", return_value=self.root):
            for value in (0, -2, 2.5, True, "2"):
                with self.subTest(value=value):
                    response = self.client.post(
                        "/api/benchmarks/create/",
                        data=json.dumps({"name": "test", "qaFiles": ["video_a/qa_pairs.json"], "maxQaPairsPerVideo": value}),
                        content_type="application/json",
                    )
                    self.assertEqual(response.status_code, 400)

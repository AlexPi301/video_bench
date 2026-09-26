Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
Failed to create stream fd: Operation not permitted
import json
from unittest.mock import patch
from django.test import SimpleTestCase
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

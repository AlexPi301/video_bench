"""HTTP API and worker for Video Bench benchmark runs."""

from __future__ import annotations

import base64
import csv
import json
import os
import re
import shutil
import tempfile
import threading
import time
import traceback
import urllib.request
from pathlib import Path
from typing import Any

from django.conf import settings
from django.http import Http404, HttpRequest, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST, require_http_methods


VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
RESULT_FIELDS = [
    "qa_key",
    "qa_id",
    "video_id",
    "question",
    "answer_format",
    "family",
    "reasoning_types",
    "difficulty",
    "visibility",
    "day_night",
    "unanswerable_gt",
    "ground_truth_resolved",
    "model",
    "raw_model_answer",
    "parsed_model_answer",
    "is_correct",
    "score_method",
    "model_declared_unanswerable",
]


def _request_timeout_seconds() -> int:
    try:
        return max(1, int(os.environ.get("VIDEO_BENCH_REQUEST_TIMEOUT_SEC", "30")))
    except ValueError:
        return 300


REQUEST_TIMEOUT_SEC = _request_timeout_seconds()
MODEL_REQUEST_ATTEMPTS = 3


def _max_evidence_frames() -> int:
    try:
        return max(1, int(os.environ.get("VIDEO_BENCH_MAX_EVIDENCE_FRAMES", "1")))
    except ValueError:
        return 1


MAX_EVIDENCE_FRAMES = _max_evidence_frames()


def _max_frame_dimension() -> int:
    try:
        return max(1, int(os.environ.get("VIDEO_BENCH_MAX_FRAME_DIMENSION", "768")))
    except ValueError:
        return 768


MAX_FRAME_DIMENSION = _max_frame_dimension()


def _request_cooldown_seconds() -> float:
    try:
        return max(0.0, float(os.environ.get("VIDEO_BENCH_REQUEST_COOLDOWN_SEC", "5")))
    except ValueError:
        return 5.0


REQUEST_COOLDOWN_SEC = _request_cooldown_seconds()
# Benchmark answers are a small JSON object; a large generation budget can stall reasoning-capable models.
MAX_TOKENS = 128
_LOCK = threading.Lock()
_RUNNING: dict[str, threading.Event] = {}
_MODEL_REQUEST_LOCK = threading.Lock()


def _mounted_root() -> Path:
    return Path(getattr(settings, "VIDEO_BENCH_MOUNTED_FILES_ROOT", "/mounted-input")).resolve()


def _benchmark_root() -> Path:
    return _mounted_root() / "benchmark_runs"


def _benchmarks_root() -> Path:
    return _benchmark_root()


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _run_stamp() -> str:
    return time.strftime("%y-%m-%d-%H-%M-%S", time.localtime())


def _json_request(request: HttpRequest) -> dict[str, Any]:
    if not request.body:
        return {}
    payload = json.loads(request.body.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object.")
    return payload


def _safe_resolve(root: Path, relative_path: str) -> Path:
    candidate = (root / str(relative_path or "")).resolve()
    try:
        common = os.path.commonpath([str(root), str(candidate)])
    except ValueError as exc:
        raise Http404("Invalid path.") from exc
    if common != str(root):
        raise Http404("Path escapes the configured root.")
    return candidate


def _safe_run_id(run_id: str) -> str:
    token = str(run_id or "").strip()
    if not re.fullmatch(r"\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}(?:-[A-Za-z0-9_-]+)?", token):
        raise Http404("Invalid benchmark run id.")
    return token


def _safe_benchmark_id(benchmark_id: str) -> str:
    return _safe_run_id(benchmark_id)


def _run_key(benchmark_id: str, run_id: str) -> str:
    return f"{_safe_benchmark_id(benchmark_id)}::{_safe_run_id(run_id)}"


def _run_selection_key(run: dict[str, Any]) -> str:
    benchmark_id = str(run.get("benchmark_id") or "")
    run_id = str(run.get("id") or "")
    return f"{benchmark_id}::{run_id}" if benchmark_id and run_id else run_id


def _benchmark_dir(benchmark_id: str) -> Path:
    return _benchmarks_root() / _safe_benchmark_id(benchmark_id)


def _benchmark_path(benchmark_id: str) -> Path:
    return _benchmark_dir(benchmark_id) / "benchmark.json"


def _benchmark_runs_dir(benchmark_id: str) -> Path:
    return _benchmark_dir(benchmark_id) / "runs"


def _benchmark_run_dir(benchmark_id: str, run_id: str) -> Path:
    return _benchmark_runs_dir(benchmark_id) / _safe_run_id(run_id)


def _benchmark_run_path(benchmark_id: str, run_id: str) -> Path:
    return _benchmark_run_dir(benchmark_id, run_id) / "run.json"


def _benchmark_run_results_path(benchmark_id: str, run_id: str) -> Path:
    return _benchmark_run_dir(benchmark_id, run_id) / "results.csv"


def _benchmark_run_events_path(benchmark_id: str, run_id: str) -> Path:
    return _benchmark_run_dir(benchmark_id, run_id) / "events.jsonl"


def _run_dir(run_id: str) -> Path:
    return _benchmark_root() / _safe_run_id(run_id)


def _details_path(run_id: str) -> Path:
    return _run_dir(run_id) / "details.json"


def _results_path(run_id: str) -> Path:
    return _run_dir(run_id) / "results.csv"


def _blacklist_path() -> Path:
    return _mounted_root() / "qa_pair_blacklist.json"


def _events_path(run_id: str) -> Path:
    return _run_dir(run_id) / "events.jsonl"


def _run_dir_for_run(run: dict[str, Any]) -> Path:
    benchmark_id = str(run.get("benchmark_id") or "")
    run_id = str(run.get("id") or "")
    if benchmark_id and not bool(run.get("legacy", False)):
        return _benchmark_run_dir(benchmark_id, run_id)
    return _run_dir(run_id)


def _results_path_for_run(run: dict[str, Any]) -> Path:
    return _run_dir_for_run(run) / "results.csv"


def _events_path_for_run(run: dict[str, Any]) -> Path:
    return _run_dir_for_run(run) / "events.jsonl"


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=True, indent=2)
        handle.write("\n")
    tmp.replace(path)


def _load_run(run_id: str) -> dict[str, Any]:
    path = _details_path(run_id)
    if not path.is_file():
        raise Http404("Benchmark run not found.")
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise Http404("Benchmark run is invalid.")
    return payload


def _load_benchmark(benchmark_id: str) -> dict[str, Any]:
    path = _benchmark_path(benchmark_id)
    if not path.is_file():
        raise Http404("Benchmark not found.")
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise Http404("Benchmark is invalid.")
    return payload


def _save_benchmark(benchmark: dict[str, Any]) -> None:
    _write_json_atomic(_benchmark_path(str(benchmark.get("id") or "")), benchmark)


def _load_benchmark_run(benchmark_id: str, run_id: str) -> dict[str, Any]:
    path = _benchmark_run_path(benchmark_id, run_id)
    if not path.is_file():
        raise Http404("Benchmark run not found.")
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise Http404("Benchmark run is invalid.")
    payload.setdefault("benchmark_id", benchmark_id)
    return payload


def _save_benchmark_run(run: dict[str, Any]) -> None:
    _write_json_atomic(_benchmark_run_path(str(run.get("benchmark_id") or ""), str(run.get("id") or "")), run)


def _update_benchmark(benchmark_id: str, **updates: Any) -> dict[str, Any]:
    with _LOCK:
        benchmark = _load_benchmark(benchmark_id)
        benchmark.update(updates)
        benchmark["updated_at"] = _now_iso()
        _save_benchmark(benchmark)
        return benchmark


def _update_benchmark_run(benchmark_id: str, run_id: str, **updates: Any) -> dict[str, Any]:
    with _LOCK:
        run = _load_benchmark_run(benchmark_id, run_id)
        run.update(updates)
        run["updated_at"] = _now_iso()
        _save_benchmark_run(run)
        return run


def _effective_run(benchmark: dict[str, Any], run: dict[str, Any]) -> dict[str, Any]:
    merged = dict(benchmark)
    merged.update(run)
    merged["benchmark_id"] = str(benchmark.get("id") or run.get("benchmark_id") or "")
    merged["benchmark_name"] = str(benchmark.get("name") or "")
    return merged


def _save_run(run: dict[str, Any]) -> None:
    _write_json_atomic(_details_path(str(run.get("id") or "")), run)


def _update_run(run_id: str, **updates: Any) -> dict[str, Any]:
    with _LOCK:
        run = _load_run(run_id)
        run.update(updates)
        run["updated_at"] = _now_iso()
        _save_run(run)
        return run


def _append_event(run_id: str, event_type: str, message: str, **fields: Any) -> None:
    row = {"ts": _now_iso(), "type": event_type, "message": str(message or "")}
    row.update(fields)
    path = _events_path(run_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=True) + "\n")


def _append_run_event(benchmark_id: str, run_id: str, event_type: str, message: str, **fields: Any) -> None:
    row = {"ts": _now_iso(), "type": event_type, "message": str(message or "")}
    row.update(fields)
    path = _benchmark_run_events_path(benchmark_id, run_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=True) + "\n")


def _all_runs() -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    for benchmark in _all_benchmarks(include_legacy=True):
        for run in list(benchmark.get("runs") or []):
            if isinstance(run, dict):
                runs.append(_effective_run(benchmark, run))
    return runs


def _all_benchmarks(*, include_legacy: bool = False) -> list[dict[str, Any]]:
    benchmarks: list[dict[str, Any]] = []
    root = _benchmarks_root()
    root.mkdir(parents=True, exist_ok=True)
    for path in sorted(root.glob("*/benchmark.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        try:
            with path.open("r", encoding="utf-8") as handle:
                benchmark = json.load(handle)
            if isinstance(benchmark, dict):
                benchmark["runs"] = _all_benchmark_runs(str(benchmark.get("id") or ""))
                benchmarks.append(benchmark)
        except Exception:
            continue
    if include_legacy:
        known_ids = {str(item.get("id") or "") for item in benchmarks}
        for path in sorted(root.glob("*/details.json"), key=lambda item: item.stat().st_mtime, reverse=True):
            try:
                with path.open("r", encoding="utf-8") as handle:
                    legacy_run = json.load(handle)
                if not isinstance(legacy_run, dict):
                    continue
                legacy_id = str(legacy_run.get("id") or path.parent.name)
                if legacy_id in known_ids:
                    continue
                benchmark = _legacy_benchmark_from_run(legacy_run, legacy_id)
                benchmark["runs"] = [_legacy_child_run_from_run(legacy_run, legacy_id)]
                benchmarks.append(benchmark)
            except Exception:
                continue
    return benchmarks


def _all_benchmark_runs(benchmark_id: str) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    runs_dir = _benchmark_runs_dir(benchmark_id)
    if not runs_dir.is_dir():
        return runs
    for path in sorted(runs_dir.glob("*/run.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        try:
            with path.open("r", encoding="utf-8") as handle:
                run = json.load(handle)
            if isinstance(run, dict):
                run.setdefault("benchmark_id", benchmark_id)
                runs.append(run)
        except Exception:
            continue
    return runs


def pause_running_benchmark_runs_on_startup() -> int:
    """Recover runs abandoned by a previous backend process."""
    try:
        benchmarks = _all_benchmarks(include_legacy=True)
    except Exception:
        return 0

    paused = 0
    for benchmark in benchmarks:
        benchmark_id = str(benchmark.get("id") or "")
        if bool(benchmark.get("legacy", False)):
            try:
                run = _load_run(benchmark_id)
                if str(run.get("status") or "") != "running":
                    continue
                _update_run(benchmark_id, status="paused")
                _append_event(benchmark_id, "paused", "Benchmark execution was paused because the backend restarted.")
                paused += 1
            except Exception:
                continue
            continue

        for run in list(benchmark.get("runs") or []):
            run_id = str(run.get("id") or "")
            if not benchmark_id or not run_id or str(run.get("status") or "") != "running":
                continue
            try:
                _update_benchmark_run(benchmark_id, run_id, status="paused")
                _append_run_event(benchmark_id, run_id, "paused", "Benchmark execution was paused because the backend restarted.")
                paused += 1
            except Exception:
                continue
    return paused


def _legacy_benchmark_from_run(run: dict[str, Any], benchmark_id: str) -> dict[str, Any]:
    return {
        "id": benchmark_id,
        "name": str(run.get("name") or benchmark_id),
        "creation_date": str(run.get("creation_date") or ""),
        "run_date": str(run.get("run_date") or ""),
        "description": str(run.get("description") or ""),
        "lm_studio_url": str(run.get("lm_studio_url") or ""),
        "frame_sample_rate": int(run.get("frame_sample_rate") or 15),
        "save_sample_frames": bool(run.get("save_sample_frames", False)),
        "batch_same_evidence_spans": bool(run.get("batch_same_evidence_spans", True)),
        "skip_evidence_above_threshold": bool(run.get("skip_evidence_above_threshold", True)),
        "evidence_duration_threshold_seconds": float(run.get("evidence_duration_threshold_seconds") or 25),
        "output_folder": str(run.get("output_folder") or "benchmark_runs"),
        "qa_files": list(run.get("qa_files") or []),
        "created_at": str(run.get("created_at") or ""),
        "updated_at": str(run.get("updated_at") or ""),
        "legacy": True,
    }


def _legacy_child_run_from_run(run: dict[str, Any], benchmark_id: str) -> dict[str, Any]:
    return {
        "id": str(run.get("id") or benchmark_id),
        "benchmark_id": benchmark_id,
        "model": str(run.get("model") or ""),
        "status": str(run.get("status") or "created"),
        "created_at": str(run.get("created_at") or ""),
        "updated_at": str(run.get("updated_at") or ""),
        "started_at": str(run.get("started_at") or ""),
        "completed_at": str(run.get("completed_at") or ""),
        "progress": dict(run.get("progress") or {}),
        "error": str(run.get("error") or ""),
        "legacy": True,
    }


def _is_legacy_benchmark_id(benchmark_id: str) -> bool:
    return _details_path(benchmark_id).is_file() and not _benchmark_path(benchmark_id).is_file()


@require_GET
def list_benchmarks(_request: HttpRequest) -> JsonResponse:
    return JsonResponse({"benchmarks": [_benchmark_response(benchmark) for benchmark in _all_benchmarks(include_legacy=True)]})


@require_GET
def list_benchmark_runs(_request: HttpRequest) -> JsonResponse:
    return JsonResponse({"runs": [_run_response(run) for run in _all_runs()]})


def _validated_qa_files(payload: dict[str, Any]) -> tuple[list[str] | None, JsonResponse | None]:
    qa_files = [str(item).strip() for item in list(payload.get("qaFiles") or []) if str(item).strip()]
    if not qa_files:
        return None, JsonResponse({"error": "Select at least one qa_pairs.json file."}, status=400)
    for rel_path in qa_files:
        try:
            qa_path = _safe_resolve(_mounted_root(), rel_path)
        except Http404 as exc:
            return None, JsonResponse({"error": str(exc)}, status=400)
        if not qa_path.is_file() or qa_path.name != "qa_pairs.json":
            return None, JsonResponse({"error": f"QA file is not a qa_pairs.json file: {rel_path}"}, status=400)
    return sorted(set(qa_files)), None


def _validated_output_folder(payload: dict[str, Any]) -> tuple[str | None, JsonResponse | None]:
    output_folder = str(payload.get("outputFolder") or "benchmark_runs").strip() or "benchmark_runs"
    if output_folder.strip("/") != "benchmark_runs":
        return None, JsonResponse({"error": "Benchmark runs are stored under the mounted benchmark_runs directory."}, status=400)
    return output_folder, None


def _bool_payload(payload: dict[str, Any], key: str, default: bool = False) -> bool:
    value = payload.get(key)
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


@csrf_exempt
@require_POST
def create_benchmark(request: HttpRequest) -> JsonResponse:
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)

    name = str(payload.get("name") or "").strip()
    if not name:
        return JsonResponse({"error": "Name is required."}, status=400)
    qa_files, error = _validated_qa_files(payload)
    if error is not None:
        return error
    output_folder, error = _validated_output_folder(payload)
    if error is not None:
        return error
    output_base = _benchmark_root()
    output_base.mkdir(parents=True, exist_ok=True)

    benchmark_id = _run_stamp()
    benchmark_dir = output_base / benchmark_id
    suffix = 1
    while benchmark_dir.exists():
        suffix += 1
        benchmark_dir = output_base / f"{benchmark_id}-{suffix}"
    benchmark_id = benchmark_dir.name
    benchmark_dir.mkdir(parents=True, exist_ok=False)

    now = _now_iso()
    benchmark = {
        "id": benchmark_id,
        "name": name,
        "creation_date": str(payload.get("creationDate") or now),
        "run_date": str(payload.get("runDate") or ""),
        "description": str(payload.get("description") or ""),
        "lm_studio_url": str(payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip(),
        "frame_sample_rate": max(1, int(payload.get("frameSampleRate") or 15)),
        "save_sample_frames": _bool_payload(payload, "saveSampleFrames"),
        "batch_same_evidence_spans": _bool_payload(payload, "batchSameEvidenceSpans", True),
        "skip_evidence_above_threshold": _bool_payload(payload, "skipEvidenceAboveThreshold", True),
        "evidence_duration_threshold_seconds": max(0.0, float(payload.get("evidenceDurationThresholdSeconds") or 25)),
        "output_folder": output_folder,
        "qa_files": qa_files,
        "created_at": now,
        "updated_at": now,
    }
    _save_benchmark(benchmark)
    return JsonResponse(_benchmark_response(benchmark), status=201)


@csrf_exempt
@require_POST
def create_benchmark_run(request: HttpRequest) -> JsonResponse:
    """Legacy endpoint: create a benchmark and its first run from the old flat form."""
    benchmark_response = create_benchmark(request)
    if benchmark_response.status_code >= 400:
        return benchmark_response
    benchmark = json.loads(benchmark_response.content.decode("utf-8"))
    benchmark_id = str(benchmark.get("id") or "")
    payload = _json_request(request)
    run_payload = {"model": str(payload.get("model") or "google/gemma-4-31b").strip()}
    fake_request = HttpRequest()
    fake_request.method = "POST"
    fake_request._body = json.dumps(run_payload).encode("utf-8")
    return add_benchmark_run(fake_request, benchmark_id)


@require_GET
def get_benchmark(_request: HttpRequest, benchmark_id: str) -> JsonResponse:
    return JsonResponse(_benchmark_response(_load_benchmark(benchmark_id)))


@csrf_exempt
@require_http_methods(["PATCH", "POST"])
def update_benchmark(request: HttpRequest, benchmark_id: str) -> JsonResponse:
    benchmark = _load_benchmark(benchmark_id)
    if _benchmark_has_active_runs(benchmark_id):
        return JsonResponse({"error": "Cannot edit a benchmark while one of its runs is active."}, status=409)
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    name = str(payload.get("name") or "").strip()
    if not name:
        return JsonResponse({"error": "Name is required."}, status=400)
    qa_files, error = _validated_qa_files(payload)
    if error is not None:
        return error
    output_folder, error = _validated_output_folder(payload)
    if error is not None:
        return error
    benchmark.update({
        "name": name,
        "creation_date": str(payload.get("creationDate") or benchmark.get("creation_date") or ""),
        "run_date": str(payload.get("runDate") or benchmark.get("run_date") or ""),
        "description": str(payload.get("description") or ""),
        "lm_studio_url": str(payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip(),
        "frame_sample_rate": max(1, int(payload.get("frameSampleRate") or 15)),
        "save_sample_frames": _bool_payload(payload, "saveSampleFrames"),
        "batch_same_evidence_spans": _bool_payload(payload, "batchSameEvidenceSpans", True),
        "skip_evidence_above_threshold": _bool_payload(payload, "skipEvidenceAboveThreshold", True),
        "evidence_duration_threshold_seconds": max(0.0, float(payload.get("evidenceDurationThresholdSeconds") or 25)),
        "output_folder": output_folder,
        "qa_files": qa_files,
        "updated_at": _now_iso(),
    })
    _save_benchmark(benchmark)
    return JsonResponse(_benchmark_response(benchmark))


@csrf_exempt
@require_http_methods(["DELETE", "POST"])
def delete_benchmark(_request: HttpRequest, benchmark_id: str) -> JsonResponse:
    _load_benchmark(benchmark_id)
    if _benchmark_has_active_runs(benchmark_id):
        return JsonResponse({"error": "Cannot delete a benchmark while one of its runs is active."}, status=409)
    directory = _benchmark_dir(benchmark_id)
    if directory.exists():
        shutil.rmtree(directory)
    return JsonResponse({"deleted": True, "id": benchmark_id})


@csrf_exempt
@require_POST
def add_benchmark_run(request: HttpRequest, benchmark_id: str) -> JsonResponse:
    _load_benchmark(benchmark_id)
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    model = str(payload.get("model") or "google/gemma-4-31b").strip()
    if not model:
        return JsonResponse({"error": "Model is required."}, status=400)
    run_id = _run_stamp()
    run_dir = _benchmark_run_dir(benchmark_id, run_id)
    suffix = 1
    while run_dir.exists():
        suffix += 1
        run_dir = _benchmark_run_dir(benchmark_id, f"{run_id}-{suffix}")
    run_id = run_dir.name
    run_dir.mkdir(parents=True, exist_ok=False)
    now = _now_iso()
    run = {
        "id": run_id,
        "benchmark_id": benchmark_id,
        "model": model,
        "status": "created",
        "created_at": now,
        "updated_at": now,
        "started_at": "",
        "completed_at": "",
        "progress": {"processedQuestions": 0, "totalQuestions": 0, "percent": 0},
        "error": "",
    }
    _save_benchmark_run(run)
    _append_run_event(benchmark_id, run_id, "created", "Benchmark run created.")
    return JsonResponse(_benchmark_run_response(_load_benchmark(benchmark_id), run), status=201)


@require_GET
def get_benchmark_run(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id:
        if _is_legacy_benchmark_id(benchmark_id):
            return JsonResponse(_run_response(_load_run(run_id)))
        benchmark = _load_benchmark(benchmark_id)
        return JsonResponse(_benchmark_run_response(benchmark, _load_benchmark_run(benchmark_id, run_id)))
    return JsonResponse(_run_response(_load_run(run_id)))


@csrf_exempt
@require_http_methods(["PATCH", "POST"])
def update_benchmark_run(request: HttpRequest, run_id: str) -> JsonResponse:
    run = _load_run(run_id)
    if run_id in _RUNNING or str(run.get("status")) in {"queued", "running"}:
        return JsonResponse({"error": "Cannot edit a running benchmark run."}, status=409)
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)

    name = str(payload.get("name") or "").strip()
    if not name:
        return JsonResponse({"error": "Name is required."}, status=400)
    qa_files, error = _validated_qa_files(payload)
    if error is not None:
        return error
    output_folder, error = _validated_output_folder(payload)
    if error is not None:
        return error

    run.update(
        {
            "name": name,
            "creation_date": str(payload.get("creationDate") or run.get("creation_date") or ""),
            "run_date": str(payload.get("runDate") or run.get("run_date") or ""),
            "description": str(payload.get("description") or ""),
            "lm_studio_url": str(payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip(),
            "frame_sample_rate": max(1, int(payload.get("frameSampleRate") or 15)),
            "save_sample_frames": _bool_payload(payload, "saveSampleFrames"),
            "batch_same_evidence_spans": _bool_payload(payload, "batchSameEvidenceSpans", True),
            "skip_evidence_above_threshold": _bool_payload(payload, "skipEvidenceAboveThreshold", True),
            "evidence_duration_threshold_seconds": max(0.0, float(payload.get("evidenceDurationThresholdSeconds") or 25)),
            "output_folder": output_folder,
            "qa_files": qa_files,
            "updated_at": _now_iso(),
        }
    )
    _save_run(run)
    _append_event(run_id, "edited", "Benchmark run edited.")
    return JsonResponse(_run_response(run))


@csrf_exempt
@require_http_methods(["DELETE", "POST"])
def delete_benchmark_run(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id:
        if _is_legacy_benchmark_id(benchmark_id):
            return delete_benchmark_run(_request, run_id)
        run = _load_benchmark_run(benchmark_id, run_id)
        key = _run_key(benchmark_id, run_id)
        if str(run.get("status")) in {"queued", "running", "pausing"} or key in _RUNNING:
            return JsonResponse({"error": "Cannot delete a running benchmark run."}, status=409)
        directory = _benchmark_run_dir(benchmark_id, run_id)
        if directory.exists():
            shutil.rmtree(directory)
        return JsonResponse({"deleted": True, "benchmarkId": benchmark_id, "id": run_id})
    run = _load_run(run_id)
    if str(run.get("status")) in {"queued", "running", "pausing"} or run_id in _RUNNING:
        return JsonResponse({"error": "Cannot delete a running benchmark run."}, status=409)
    directory = _run_dir(run_id)
    if directory.exists():
        shutil.rmtree(directory)
    return JsonResponse({"deleted": True, "id": run_id})


@csrf_exempt
@require_POST
def start_benchmark_run(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id and _is_legacy_benchmark_id(benchmark_id):
        return start_benchmark_run(_request, run_id)
    if not benchmark_id:
        run = _load_run(run_id)
        if run_id in _RUNNING or str(run.get("status")) in {"queued", "running"}:
            return JsonResponse({"error": "Benchmark run is already running."}, status=409)
        if str(run.get("status")) == "failed":
            return JsonResponse({"error": "Failed benchmark runs must be resumed, not started."}, status=409)
        results_path = _results_path(run_id)
        if _result_count(results_path) > 0:
            return JsonResponse({"error": "Benchmark run already has results and cannot be started again."}, status=409)
        event = threading.Event()
        _RUNNING[run_id] = event
        _update_run(run_id, status="queued", error="")
        _append_event(run_id, "queued", "Benchmark run queued.")
        thread = threading.Thread(target=_run_benchmark_worker, args=(run_id, event), daemon=True)
        thread.start()
        return JsonResponse(_run_response(_load_run(run_id)))
    benchmark = _load_benchmark(benchmark_id)
    run = _load_benchmark_run(benchmark_id, run_id)
    key = _run_key(benchmark_id, run_id)
    if key in _RUNNING or str(run.get("status")) in {"queued", "running"}:
        return JsonResponse({"error": "Benchmark run is already running."}, status=409)
    if str(run.get("status")) == "failed":
        return JsonResponse({"error": "Failed benchmark runs must be resumed, not started."}, status=409)
    results_path = _benchmark_run_results_path(benchmark_id, run_id)
    if _result_count(results_path) > 0:
        return JsonResponse({"error": "Benchmark run already has results and cannot be started again."}, status=409)
    event = threading.Event()
    _RUNNING[key] = event
    _update_benchmark_run(benchmark_id, run_id, status="queued", error="")
    _append_run_event(benchmark_id, run_id, "queued", "Benchmark run queued.")
    thread = threading.Thread(target=_run_benchmark_worker, args=(benchmark_id, run_id, event), daemon=True)
    thread.start()
    return JsonResponse(_benchmark_run_response(benchmark, _load_benchmark_run(benchmark_id, run_id)))


@csrf_exempt
@require_POST
def resume_benchmark_run(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id and _is_legacy_benchmark_id(benchmark_id):
        return resume_benchmark_run(_request, run_id)
    if not benchmark_id:
        run = _load_run(run_id)
        if run_id in _RUNNING or str(run.get("status")) in {"queued", "running"}:
            return JsonResponse({"error": "Benchmark run is already running."}, status=409)
        if str(run.get("status")) not in {"failed", "paused"}:
            return JsonResponse({"error": "Only failed or paused benchmark runs can be resumed."}, status=409)
        event = threading.Event()
        _RUNNING[run_id] = event
        _update_run(run_id, status="queued", error="")
        _append_event(run_id, "queued", "Benchmark run queued for resume.")
        thread = threading.Thread(target=_run_benchmark_worker, args=(run_id, event, True), daemon=True)
        thread.start()
        return JsonResponse(_run_response(_load_run(run_id)))
    benchmark = _load_benchmark(benchmark_id)
    run = _load_benchmark_run(benchmark_id, run_id)
    key = _run_key(benchmark_id, run_id)
    if key in _RUNNING or str(run.get("status")) in {"queued", "running"}:
        return JsonResponse({"error": "Benchmark run is already running."}, status=409)
    if str(run.get("status")) not in {"failed", "paused"}:
        return JsonResponse({"error": "Only failed or paused benchmark runs can be resumed."}, status=409)
    event = threading.Event()
    _RUNNING[key] = event
    _update_benchmark_run(benchmark_id, run_id, status="queued", error="")
    _append_run_event(benchmark_id, run_id, "queued", "Benchmark run queued for resume.")
    thread = threading.Thread(target=_run_benchmark_worker, args=(benchmark_id, run_id, event, True), daemon=True)
    thread.start()
    return JsonResponse(_benchmark_run_response(benchmark, _load_benchmark_run(benchmark_id, run_id)))


@csrf_exempt
@require_POST
def pause_benchmark_run(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id and _is_legacy_benchmark_id(benchmark_id):
        return pause_benchmark_run(_request, run_id)
    if not benchmark_id:
        run = _load_run(run_id)
        cancel_event = _RUNNING.get(run_id)
        if cancel_event is None or str(run.get("status")) not in {"queued", "running"}:
            return JsonResponse({"error": "Only active benchmark runs can be paused."}, status=409)
        _update_run(run_id, status="pausing")
        _append_event(run_id, "pause_requested", "Benchmark pause requested; stopping after the current QA pair finishes.")
        cancel_event.set()
        return JsonResponse(_run_response(_load_run(run_id)))
    benchmark = _load_benchmark(benchmark_id)
    run = _load_benchmark_run(benchmark_id, run_id)
    key = _run_key(benchmark_id, run_id)
    cancel_event = _RUNNING.get(key)
    if cancel_event is None or str(run.get("status")) not in {"queued", "running"}:
        return JsonResponse({"error": "Only active benchmark runs can be paused."}, status=409)
    _update_benchmark_run(benchmark_id, run_id, status="pausing")
    _append_run_event(benchmark_id, run_id, "pause_requested", "Benchmark pause requested; stopping after the current QA pair finishes.")
    cancel_event.set()
    return JsonResponse(_benchmark_run_response(benchmark, _load_benchmark_run(benchmark_id, run_id)))


@require_GET
def get_benchmark_run_events(request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id:
        if _is_legacy_benchmark_id(benchmark_id):
            _load_run(run_id)
            benchmark_id = None
        else:
            _load_benchmark_run(benchmark_id, run_id)
    else:
        _load_run(run_id)
    after = int(request.GET.get("after", "0") or 0)
    rows: list[dict[str, Any]] = []
    path = _benchmark_run_events_path(benchmark_id, run_id) if benchmark_id else _events_path(run_id)
    if path.is_file():
        with path.open("r", encoding="utf-8") as handle:
            for index, line in enumerate(handle, start=1):
                if index <= after:
                    continue
                try:
                    row = json.loads(line)
                    if isinstance(row, dict):
                        row["index"] = index
                        rows.append(row)
                except Exception:
                    continue
    return JsonResponse({"events": rows, "next": after + len(rows)})


def _benchmark_response(benchmark: dict[str, Any]) -> dict[str, Any]:
    out = dict(benchmark)
    out.pop("run_dir", None)
    runs = _all_benchmark_runs(str(benchmark.get("id") or "")) if not bool(benchmark.get("legacy", False)) else list(benchmark.get("runs") or [])
    out["runs"] = [_benchmark_run_response(benchmark, run) for run in runs if isinstance(run, dict)]
    return out


def _benchmark_run_response(benchmark: dict[str, Any], run: dict[str, Any]) -> dict[str, Any]:
    effective = _effective_run(benchmark, run)
    out = dict(run)
    out["benchmark_id"] = str(benchmark.get("id") or run.get("benchmark_id") or "")
    blacklisted_keys = _blacklisted_qa_keys_for_run(effective)
    results_path = _results_path_for_run(effective)
    out["metrics"] = _calculate_metrics(results_path, blacklisted_keys=blacklisted_keys)
    out["metricsIncludingBlacklisted"] = _calculate_metrics(results_path, blacklisted_keys=set())
    processed_count = _result_count_excluding(results_path, blacklisted_keys)
    out["details"] = {"processedQaPairs": processed_count, "skippedBlacklistedQaPairs": len(blacklisted_keys)}
    out["canStart"] = _can_start(effective)
    out["canResume"] = _can_resume(effective)
    out["resultsUrl"] = f"/api/benchmarks/{out['benchmark_id']}/runs/{run.get('id')}/results/"
    return out


def _run_response(run: dict[str, Any]) -> dict[str, Any]:
    benchmark_id = str(run.get("benchmark_id") or "")
    if benchmark_id and not bool(run.get("legacy", False)):
        return _benchmark_run_response(_load_benchmark(benchmark_id), run)
    benchmark = _legacy_benchmark_from_run(run, str(run.get("id") or ""))
    return _benchmark_run_response(benchmark, _legacy_child_run_from_run(run, str(run.get("id") or "")))


@require_GET
def get_benchmark_results(_request: HttpRequest, run_id: str, benchmark_id: str | None = None) -> JsonResponse:
    if benchmark_id:
        if _is_legacy_benchmark_id(benchmark_id):
            _load_run(run_id)
            path = _results_path(run_id)
        else:
            _load_benchmark_run(benchmark_id, run_id)
            path = _benchmark_run_results_path(benchmark_id, run_id)
    else:
        _load_run(run_id)
        path = _results_path(run_id)
    rows: list[dict[str, str]] = []
    if path.is_file():
        with path.open("r", encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
    return JsonResponse({"rows": rows})


@csrf_exempt
@require_POST
def get_always_wrong_qa_pairs(request: HttpRequest) -> JsonResponse:
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    selected_ids = {str(item).strip() for item in list(payload.get("runIds") or []) if str(item).strip()}
    runs = [
        run
        for run in _all_runs()
        if not selected_ids
        or str(run.get("id") or "") in selected_ids
        or _run_selection_key(run) in selected_ids
    ]
    stats: dict[str, dict[str, Any]] = {}
    qa_lookup: dict[str, dict[str, Any]] = {}
    legacy_key_map: dict[str, str] = {}
    qa_id_map: dict[str, set[str]] = {}
    for qa_file in _discover_qa_pair_files():
        for pair in _load_qa_pairs_from_file(qa_file):
            item = dict(pair)
            item["_qa_file"] = qa_file
            qa_key = _qa_pair_key(item)
            qa_id = str(item.get("id") or item.get("qa_id") or "")
            if not qa_key:
                continue
            qa_lookup.setdefault(qa_key, {"qaFile": qa_file, "qaPair": pair})
            stats.setdefault(qa_key, {"attempts": 0, "correct": 0, "runs": set()})
            legacy_key_map.setdefault(_qa_pair_file_key(item), qa_key)
            if qa_id:
                qa_id_map.setdefault(qa_id, set()).add(qa_key)
    unique_qa_id_map = {qa_id: next(iter(keys)) for qa_id, keys in qa_id_map.items() if len(keys) == 1}
    for run in runs:
        results_path = _results_path_for_run(run)
        if not results_path.is_file():
            continue
        with results_path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                qa_key = _result_row_key(row, legacy_key_map=legacy_key_map, unique_qa_id_map=unique_qa_id_map)
                if not qa_key or qa_key not in stats:
                    continue
                stat = stats[qa_key]
                stat["attempts"] += 1
                stat["runs"].add(_run_selection_key(run) or str(run.get("id") or ""))
                if str(row.get("is_correct") or "").lower() == "true":
                    stat["correct"] += 1
    blacklist = _load_blacklist_entries()
    items = []
    for qa_key, stat in sorted(stats.items(), key=lambda entry: str(entry[0])):
        if int(stat.get("correct") or 0) > 0:
            continue
        qa_info = qa_lookup.get(qa_key)
        if not qa_info:
            continue
        qa_file = str(qa_info.get("qaFile") or "")
        pair = dict(qa_info.get("qaPair") or {})
        items.append({
            "qaKey": qa_key,
            "qaFile": qa_file,
            "qaPair": pair,
            "attempts": int(stat.get("attempts") or 0),
            "runIds": sorted(str(item) for item in stat.get("runs") or []),
            "blacklisted": _qa_pair_is_blacklisted(blacklist, qa_file, pair),
        })
    return JsonResponse({"items": items})


@require_GET
def get_qa_pair_blacklist(_request: HttpRequest) -> JsonResponse:
    return JsonResponse({"entries": _load_blacklist_entries()})


@csrf_exempt
@require_POST
def set_qa_pair_blacklist(request: HttpRequest) -> JsonResponse:
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    qa_file = str(payload.get("qaFile") or "").strip()
    qa_pair = dict(payload.get("qaPair") or {})
    blacklisted = _bool_payload(payload, "blacklisted")
    entries = _load_blacklist_entries()
    key = _qa_pair_blacklist_key(qa_file, qa_pair)
    entries = [entry for entry in entries if _blacklist_entry_key(entry) != key]
    if blacklisted:
        entries.append({
            "qa_file": qa_file,
            "qa_key": key[1],
            "qa_id": str(qa_pair.get("id") or qa_pair.get("qa_id") or ""),
            "video_id": _normalized_qa_video_id(qa_pair),
            "question": str(qa_pair.get("question") or ""),
            "blacklisted_at": _now_iso(),
        })
    _write_json_atomic(_blacklist_path(), {"entries": entries})
    return JsonResponse({"entries": entries, "blacklisted": blacklisted})


@csrf_exempt
@require_POST
def update_qa_pair(request: HttpRequest) -> JsonResponse:
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    qa_file = str(payload.get("qaFile") or "").strip()
    qa_pair = dict(payload.get("qaPair") or {})
    qa_id = str(payload.get("qaId") or qa_pair.get("id") or qa_pair.get("qa_id") or "").strip()
    old_pair = dict(payload.get("oldQaPair") or {})
    match_key = _qa_pair_key({**old_pair, "_qa_file": qa_file}) if old_pair else ""
    if not qa_file or not qa_id:
        return JsonResponse({"error": "qaFile and qaPair.id are required."}, status=400)
    path = _safe_resolve(_mounted_root(), qa_file)
    payload_json = _load_qa_payload(path)
    pairs = _qa_pairs_list(payload_json)
    for index, pair in enumerate(pairs):
        item = dict(pair)
        item["_qa_file"] = qa_file
        if (match_key and _qa_pair_key(item) == match_key) or (not match_key and str(pair.get("id") or pair.get("qa_id") or "") == qa_id):
            pairs[index] = qa_pair
            _write_json_atomic(path, payload_json)
            return JsonResponse({"qaFile": qa_file, "qaPair": qa_pair})
    return JsonResponse({"error": f"QA pair {qa_id} not found."}, status=404)


@csrf_exempt
@require_POST
def delete_qa_pair(request: HttpRequest) -> JsonResponse:
    try:
        payload = _json_request(request)
    except Exception as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    qa_file = str(payload.get("qaFile") or "").strip()
    qa_id = str(payload.get("qaId") or "").strip()
    qa_pair = dict(payload.get("qaPair") or {})
    match_key = _qa_pair_key({**qa_pair, "_qa_file": qa_file}) if qa_pair else ""
    if not qa_file or not qa_id:
        return JsonResponse({"error": "qaFile and qaId are required."}, status=400)
    path = _safe_resolve(_mounted_root(), qa_file)
    payload_json = _load_qa_payload(path)
    pairs = _qa_pairs_list(payload_json)
    original_len = len(pairs)
    pairs[:] = [
        pair
        for pair in pairs
        if not (
            (match_key and _qa_pair_key({**dict(pair), "_qa_file": qa_file}) == match_key)
            or (not match_key and str(pair.get("id") or pair.get("qa_id") or "") == qa_id)
        )
    ]
    if len(pairs) == original_len:
        return JsonResponse({"error": f"QA pair {qa_id} not found."}, status=404)
    _write_json_atomic(path, payload_json)
    return JsonResponse({"deleted": True, "qaFile": qa_file, "qaId": qa_id})


def _can_start(run: dict[str, Any]) -> bool:
    run_id = str(run.get("id") or "")
    benchmark_id = str(run.get("benchmark_id") or "")
    key = _run_key(benchmark_id, run_id) if benchmark_id else run_id
    if key in _RUNNING or str(run.get("status")) != "created":
        return False
    path = _results_path_for_run(run)
    return not path.exists() or _result_count(path) == 0


def _can_resume(run: dict[str, Any]) -> bool:
    run_id = str(run.get("id") or "")
    benchmark_id = str(run.get("benchmark_id") or "")
    key = _run_key(benchmark_id, run_id) if benchmark_id else run_id
    return key not in _RUNNING and str(run.get("status")) in {"failed", "paused"}


def _benchmark_has_active_runs(benchmark_id: str) -> bool:
    return any(str(run.get("status") or "") in {"queued", "running", "pausing"} or _run_key(benchmark_id, str(run.get("id") or "")) in _RUNNING for run in _all_benchmark_runs(benchmark_id))


def _update_execution_run(run: dict[str, Any], **updates: Any) -> dict[str, Any]:
    benchmark_id = str(run.get("benchmark_id") or "")
    run_id = str(run.get("id") or "")
    if benchmark_id and not bool(run.get("legacy", False)):
        return _update_benchmark_run(benchmark_id, run_id, **updates)
    return _update_run(run_id, **updates)


def _append_execution_event(run: dict[str, Any], event_type: str, message: str, **fields: Any) -> None:
    benchmark_id = str(run.get("benchmark_id") or "")
    run_id = str(run.get("id") or "")
    if benchmark_id and not bool(run.get("legacy", False)):
        _append_run_event(benchmark_id, run_id, event_type, message, **fields)
    else:
        _append_event(run_id, event_type, message, **fields)


def _calculate_metrics(path: Path, *, blacklisted_keys: set[str]) -> dict[str, Any]:
    if not path.is_file() or path.stat().st_size == 0:
        return {"total": {"correct": 0, "count": 0, "percent": 0.0}, "byFamily": {}, "dayNight": {}}
    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = [row for row in csv.DictReader(handle) if _result_row_key(row) not in blacklisted_keys]

    def bucket_percent(bucket_rows: list[dict[str, str]]) -> dict[str, Any]:
        count = len(bucket_rows)
        correct = sum(1 for row in bucket_rows if str(row.get("is_correct") or "").lower() == "true")
        return {"correct": correct, "count": count, "percent": round(correct * 100.0 / count, 2) if count else 0.0}

    by_family: dict[str, Any] = {}
    day_night: dict[str, Any] = {}
    for row in rows:
        family = row.get("family") or "unknown"
        light = row.get("day_night") or "unknown"
        by_family.setdefault(family, []).append(row)
        day_night.setdefault(light, []).append(row)
    return {
        "total": bucket_percent(rows),
        "byFamily": {key: bucket_percent(value) for key, value in sorted(by_family.items())},
        "dayNight": {key: bucket_percent(value) for key, value in sorted(day_night.items())},
    }


def _run_benchmark_worker(benchmark_id_or_run_id: str, run_id_or_event: str | threading.Event, cancel_event: threading.Event | None = None, resume: bool = False) -> None:
    if isinstance(run_id_or_event, threading.Event):
        benchmark_id = ""
        run_id = benchmark_id_or_run_id
        event = run_id_or_event
        running_key = run_id
        legacy = True
    else:
        benchmark_id = benchmark_id_or_run_id
        run_id = run_id_or_event
        event = cancel_event
        running_key = _run_key(benchmark_id, run_id)
        legacy = False
    if event is None:
        return
    try:
        if legacy:
            run = _update_run(run_id, status="running", started_at=_now_iso(), run_date=_now_iso())
            _append_event(run_id, "started", "Benchmark execution resumed." if resume else "Benchmark execution started.")
        else:
            benchmark = _load_benchmark(benchmark_id)
            child_run = _update_benchmark_run(benchmark_id, run_id, status="running", started_at=_now_iso())
            run = _effective_run(benchmark, child_run)
            _append_run_event(benchmark_id, run_id, "started", "Benchmark execution resumed." if resume else "Benchmark execution started.")
        _execute_benchmark(run, event, resume=resume)
        current_status = str((_load_run(run_id) if legacy else _load_benchmark_run(benchmark_id, run_id)).get("status"))
        if current_status in {"cancelled", "paused"}:
            return
        completed_run = _load_run(run_id) if legacy else _load_benchmark_run(benchmark_id, run_id)
        progress = dict(completed_run.get("progress") or {})
        total_questions = int(progress.get("totalQuestions") or _result_count(_results_path_for_run(run)))
        if legacy:
            _update_run(run_id, status="completed", completed_at=_now_iso(), progress={"processedQuestions": total_questions, "totalQuestions": total_questions, "percent": 100})
            _append_event(run_id, "completed", "Benchmark execution completed.")
        else:
            _update_benchmark_run(benchmark_id, run_id, status="completed", completed_at=_now_iso(), progress={"processedQuestions": total_questions, "totalQuestions": total_questions, "percent": 100})
            _append_run_event(benchmark_id, run_id, "completed", "Benchmark execution completed.")
    except Exception as exc:
        if legacy:
            _update_run(run_id, status="failed", error=str(exc))
            _append_event(run_id, "error", str(exc), traceback=traceback.format_exc(limit=8))
        else:
            _update_benchmark_run(benchmark_id, run_id, status="failed", error=str(exc))
            _append_run_event(benchmark_id, run_id, "error", str(exc), traceback=traceback.format_exc(limit=8))
    finally:
        _RUNNING.pop(running_key, None)


def _execute_benchmark(run: dict[str, Any], cancel_event: threading.Event, resume: bool = False) -> None:
    cv2 = _import_required("cv2", "OpenCV is required for benchmark frame extraction.")
    litellm = _import_required("litellm", "LiteLLM is required for LM Studio benchmark calls.")
    run_id = str(run.get("id") or "")
    questions = _load_all_questions(list(run.get("qa_files") or []))
    total = len(questions)
    batch_same_evidence_spans = bool(run.get("batch_same_evidence_spans", True))
    skip_evidence_above_threshold = bool(run.get("skip_evidence_above_threshold", True))
    evidence_duration_threshold = float(run.get("evidence_duration_threshold_seconds") or 25)
    results_path = _results_path_for_run(run)
    events_path = _events_path_for_run(run)
    completed_qa_keys = (_completed_qa_keys_from_results(results_path) | _completed_qa_keys_from_events(events_path)) if resume and batch_same_evidence_spans else set()
    resume_index = _resume_index_from_events(events_path, questions) if resume and not batch_same_evidence_spans else 0
    processed_indices = {
        index
        for index, item in enumerate(questions)
        if _qa_pair_key(item) in completed_qa_keys
    } if completed_qa_keys else set(range(resume_index))
    processed_count = len(processed_indices)
    percent = round(processed_count * 100 / max(1, total))
    _update_execution_run(run, progress={"processedQuestions": processed_count, "totalQuestions": total, "percent": percent})
    if resume:
        _append_execution_event(run, "qa_loaded", f"Loaded {total} benchmark question(s). Resuming after {processed_count} completed question(s).")
    else:
        _append_execution_event(run, "qa_loaded", f"Loaded {total} benchmark question(s).")

    results_path.parent.mkdir(parents=True, exist_ok=True)
    if resume:
        _ensure_results_fields(results_path)
    if resume and not batch_same_evidence_spans:
        _trim_results_for_resume(results_path, resume_index)
    mode = "a" if resume else "w"
    with results_path.open(mode, encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=RESULT_FIELDS)
        if mode == "w":
            writer.writeheader()
        index = 0 if batch_same_evidence_spans else resume_index
        while index < total:
            if index in processed_indices:
                index += 1
                continue
            item = questions[index]
            if cancel_event.is_set():
                _update_execution_run(run, status="paused")
                _append_execution_event(run, "paused", "Benchmark execution paused.")
                return
            qa_id = str(item.get("id") or item.get("qa_id") or "")
            qa_key = _qa_pair_key(item)
            if skip_evidence_above_threshold and _qa_pair_exceeds_evidence_threshold(item, evidence_duration_threshold):
                processed_indices.add(index)
                processed_count = len(processed_indices)
                percent = round(processed_count * 100 / max(1, total))
                _update_execution_run(run, progress={"processedQuestions": processed_count, "totalQuestions": total, "percent": percent})
                _append_execution_event(
                    run,
                    "question_skipped",
                    f"Skipped QA pair {qa_id or '<unknown>'} because evidence duration exceeds {evidence_duration_threshold:g}s.",
                    qaId=qa_id,
                    qaKey=qa_key,
                    qaFile=str(item.get("_qa_file") or ""),
                    thresholdSeconds=evidence_duration_threshold,
                    maxEvidenceDurationSeconds=_max_evidence_duration_seconds(item),
                    percent=percent,
                )
                index += 1
                continue
            try:
                if batch_same_evidence_spans:
                    batch_indices = [
                        item_index
                        for item_index in _batch_indices_for_same_evidence_span(questions, processed_indices, index)
                        if not skip_evidence_above_threshold or not _qa_pair_exceeds_evidence_threshold(questions[item_index], evidence_duration_threshold)
                    ]
                    rows = _answer_questions_batch(cv2, litellm, run, [questions[item_index] for item_index in batch_indices])
                else:
                    batch_indices = [index]
                    rows = [_answer_question(cv2, litellm, run, item)]
            except Exception as exc:
                raise RuntimeError(f"Failed processing QA pair {qa_id or '<unknown>'}: {exc}") from exc
            if len(rows) != len(batch_indices):
                raise RuntimeError(f"Benchmark batch returned {len(rows)} answer(s) for {len(batch_indices)} QA pair(s).")
            for item_index, row in zip(batch_indices, rows):
                writer.writerow(row)
                processed_indices.add(item_index)
                handle.flush()
                processed_count = len(processed_indices)
                percent = round(processed_count * 100 / max(1, total))
                _update_execution_run(run, progress={"processedQuestions": processed_count, "totalQuestions": total, "percent": percent})
                _append_execution_event(run, "question_done", f"Answered question {processed_count}/{total}.", qaId=row["qa_id"], qaKey=row.get("qa_key", ""), qaFile=str(questions[item_index].get("_qa_file") or ""), percent=percent)
            index += 1


def _resume_index_from_events(path: Path, questions: list[dict[str, Any]]) -> int:
    last_completed_qa_key = ""
    last_completed_qa_id = ""
    completed_count = 0
    if path.is_file():
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if not isinstance(row, dict) or row.get("type") not in {"question_done", "question_skipped"}:
                    continue
                completed_count += 1
                last_completed_qa_key = str(row.get("qaKey") or "")
                last_completed_qa_id = str(row.get("qaId") or "")
    if last_completed_qa_key:
        for index, item in enumerate(questions):
            if _qa_pair_key(item) == last_completed_qa_key:
                return min(index + 1, len(questions))
    if last_completed_qa_id:
        for index, item in enumerate(questions):
            qa_id = str(item.get("id") or item.get("qa_id") or "")
            if qa_id == last_completed_qa_id:
                return min(index + 1, len(questions))
    return min(completed_count, len(questions))


def _trim_results_for_resume(path: Path, keep_count: int) -> None:
    rows: list[dict[str, str]] = []
    if path.is_file() and path.stat().st_size > 0:
        with path.open("r", encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))[: max(0, keep_count)]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in RESULT_FIELDS})


def _ensure_results_fields(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        return
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        if list(reader.fieldnames or []) == RESULT_FIELDS:
            return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in RESULT_FIELDS})


def _load_all_questions(qa_files: list[str]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for rel_path in qa_files:
        path = _safe_resolve(_mounted_root(), rel_path)
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict) and isinstance(payload.get("qa_pairs"), list):
            raw_items = payload["qa_pairs"]
        elif isinstance(payload, list):
            raw_items = payload
        elif isinstance(payload, dict):
            raw_items = [payload]
        else:
            raw_items = []
        for raw in raw_items:
            if isinstance(raw, dict):
                item = dict(raw)
                item["_qa_file"] = rel_path
                items.append(item)
    return items


def _qa_pair_key(item: dict[str, Any]) -> str:
    video_id = _normalized_qa_video_id(item)
    qa_id = str(item.get("id") or item.get("qa_id") or "").strip()
    if not video_id or not qa_id:
        return ""
    return f"{video_id}::{qa_id}"


def _qa_pair_file_key(item: dict[str, Any]) -> str:
    qa_file = str(item.get("_qa_file") or "").strip()
    qa_id = str(item.get("id") or item.get("qa_id") or "").strip()
    if not qa_file or not qa_id:
        return ""
    return f"{qa_file}::{qa_id}"


def _result_row_key(row: dict[str, Any], *, legacy_key_map: dict[str, str] | None = None, unique_qa_id_map: dict[str, str] | None = None) -> str:
    qa_id = str(row.get("qa_id") or "").strip()
    video_id = str(row.get("video_id") or "").strip()
    suffix = Path(video_id).suffix.lower()
    if suffix in VIDEO_EXTENSIONS:
        video_id = video_id[: -len(suffix)]
    if video_id and qa_id:
        return f"{video_id}::{qa_id}"
    qa_key = str(row.get("qa_key") or "")
    if qa_key:
        return (legacy_key_map or {}).get(qa_key, qa_key)
    if qa_id:
        return (unique_qa_id_map or {}).get(qa_id, "")
    return ""


def _discover_qa_pair_files() -> list[str]:
    root = _mounted_root()
    if not root.is_dir():
        return []
    paths: list[str] = []
    for path in root.rglob("qa_pairs.json"):
        if not path.is_file():
            continue
        try:
            paths.append(path.resolve().relative_to(root).as_posix())
        except Exception:
            continue
    return sorted(set(paths))


def _load_qa_pairs_from_file(rel_path: str) -> list[dict[str, Any]]:
    try:
        payload = _load_qa_payload(_safe_resolve(_mounted_root(), rel_path))
    except Exception:
        return []
    return [dict(item) for item in _qa_pairs_list(payload) if isinstance(item, dict)]


def _load_qa_payload(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _qa_pairs_list(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict) and isinstance(payload.get("qa_pairs"), list):
        return payload["qa_pairs"]
    if isinstance(payload, list):
        return payload
    raise RuntimeError("QA file must contain a qa_pairs list.")


def _load_blacklist_entries() -> list[dict[str, Any]]:
    path = _blacklist_path()
    if not path.is_file():
        return []
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict) and isinstance(payload.get("entries"), list):
            return [dict(item) for item in payload["entries"] if isinstance(item, dict)]
        if isinstance(payload, list):
            return [dict(item) for item in payload if isinstance(item, dict)]
    except Exception:
        return []
    return []


def _blacklisted_qa_keys_for_run(run: dict[str, Any]) -> set[str]:
    entries = _load_blacklist_entries()
    blacklisted: set[str] = set()
    for qa_file in list(run.get("qa_files") or []):
        for pair in _load_qa_pairs_from_file(str(qa_file)):
            item = dict(pair)
            item["_qa_file"] = str(qa_file)
            if _qa_pair_is_blacklisted(entries, str(qa_file), item):
                qa_key = _qa_pair_key(item)
                if qa_key:
                    blacklisted.add(qa_key)
    return blacklisted


def _qa_pair_is_blacklisted(entries: list[dict[str, Any]], qa_file: str, qa_pair: dict[str, Any]) -> bool:
    key = _qa_pair_blacklist_key(qa_file, qa_pair)
    return any(_blacklist_entry_key(entry) == key for entry in entries)


def _qa_pair_blacklist_key(qa_file: str, qa_pair: dict[str, Any]) -> tuple[str, str]:
    item = dict(qa_pair)
    item["_qa_file"] = qa_file
    return (str(qa_file or ""), _qa_pair_key(item))


def _blacklist_entry_key(entry: dict[str, Any]) -> tuple[str, str]:
    qa_file = str(entry.get("qa_file") or entry.get("qaFile") or "")
    qa_key = str(entry.get("qa_key") or entry.get("qaKey") or "")
    if not qa_key:
        qa_id = str(entry.get("qa_id") or entry.get("qaId") or "")
        video_id = str(entry.get("video_id") or entry.get("videoId") or "")
        item = {"_qa_file": qa_file, "id": qa_id, "video_id": video_id}
        qa_key = _qa_pair_key(item) or qa_id
    return (qa_file, qa_key)


def _batch_indices_for_same_evidence_span(questions: list[dict[str, Any]], processed_indices: set[int], first_index: int) -> list[int]:
    first_key = _batch_evidence_key(questions[first_index])
    if first_key is None:
        return [first_index]
    indices = [first_index]
    for index in range(first_index + 1, len(questions)):
        if index in processed_indices:
            continue
        if _batch_evidence_key(questions[index]) == first_key:
            indices.append(index)
    return indices


def _batch_evidence_key(item: dict[str, Any]) -> tuple[str, float, float] | None:
    spans = list(item.get("evidence_spans") or [])
    if not spans or not isinstance(spans[0], dict):
        return None
    span = spans[0]
    try:
        start = float(span.get("start_seconds"))
        end = float(span.get("end_seconds"))
    except Exception:
        return None
    return (_normalized_qa_video_id(item), start, end)


def _qa_pair_exceeds_evidence_threshold(item: dict[str, Any], threshold_seconds: float) -> bool:
    return _max_evidence_duration_seconds(item) > threshold_seconds


def _max_evidence_duration_seconds(item: dict[str, Any]) -> float:
    max_duration = 0.0
    for span in list(item.get("evidence_spans") or []):
        if not isinstance(span, dict):
            continue
        try:
            start = float(span.get("start_seconds") or 0)
            end = float(span.get("end_seconds") if span.get("end_seconds") is not None else start)
        except Exception:
            continue
        max_duration = max(max_duration, max(0.0, end - start))
    return max_duration


def _answer_question(cv2: Any, litellm: Any, run: dict[str, Any], item: dict[str, Any]) -> dict[str, str]:
    video_path = _resolve_video_path(item)
    if bool(run.get("save_sample_frames", False)):
        frame_paths = _sample_evidence_frames(cv2, video_path, item, int(run.get("frame_sample_rate") or 15), _run_dir_for_run(run) / "frames")
        messages = [{"role": "user", "content": _prompt_content(item, frame_paths)}]
    else:
        with tempfile.TemporaryDirectory(prefix="video-bench-frames-") as tmp_dir:
            frame_paths = _sample_evidence_frames(cv2, video_path, item, int(run.get("frame_sample_rate") or 15), Path(tmp_dir))
            messages = [{"role": "user", "content": _prompt_content(item, frame_paths)}]
            return _complete_answer(litellm, run, item, messages)

    return _complete_answer(litellm, run, item, messages)


def _answer_questions_batch(cv2: Any, litellm: Any, run: dict[str, Any], items: list[dict[str, Any]]) -> list[dict[str, str]]:
    if len(items) <= 1:
        return [_answer_question(cv2, litellm, run, items[0])]
    video_path = _resolve_video_path(items[0])
    frame_dir = _run_dir_for_run(run) / "frames"
    if bool(run.get("save_sample_frames", False)):
        frame_paths = _sample_evidence_frames(cv2, video_path, items[0], int(run.get("frame_sample_rate") or 15), frame_dir)
        messages = [{"role": "user", "content": _batch_prompt_content(items, frame_paths)}]
    else:
        with tempfile.TemporaryDirectory(prefix="video-bench-frames-") as tmp_dir:
            frame_paths = _sample_evidence_frames(cv2, video_path, items[0], int(run.get("frame_sample_rate") or 15), Path(tmp_dir))
            messages = [{"role": "user", "content": _batch_prompt_content(items, frame_paths)}]
            return _complete_answers_batch(litellm, run, items, messages)

    return _complete_answers_batch(litellm, run, items, messages)


def _request_model_completion(litellm: Any, run: dict[str, Any], items: list[dict[str, Any]], messages: list[dict[str, Any]], max_tokens: int) -> Any:
    qa_ids = [str(item.get("id") or item.get("qa_id") or "") for item in items]
    _append_execution_event(
        run,
        "question_request_started",
        f"Sending {len(items)} QA pair(s) to the model.",
        qaId=qa_ids[0] if len(qa_ids) == 1 else "",
        qaIds=qa_ids,
        qaFile=str(items[0].get("_qa_file") or "") if items else "",
        timeoutSeconds=REQUEST_TIMEOUT_SEC,
    )
    model = str(run.get("model") or "").strip()
    api_base = str(run.get("lm_studio_url") or "").strip().rstrip("/")
    request = urllib.request.Request(
            f"{api_base}/chat/completions",
            data=json.dumps(
                {
                    "model": model.removeprefix("openai/"),
                    "messages": messages,
                    "temperature": 0,
                    "max_tokens": max_tokens,
                    "stream": True,
                    "reasoning_effort": "none",
                }
            ).encode("utf-8"),
            headers={"Authorization": "Bearer lm-studio", "Connection": "close", "Content-Type": "application/json"},
            method="POST",
    )
    last_error: Exception | None = None
    for attempt in range(1, MODEL_REQUEST_ATTEMPTS + 1):
        try:
            with _MODEL_REQUEST_LOCK:
                with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SEC) as response:
                    answer = _stream_completion_text(response)
                if REQUEST_COOLDOWN_SEC:
                    time.sleep(REQUEST_COOLDOWN_SEC)
                return answer
        except Exception as exc:
            last_error = exc
            if attempt < MODEL_REQUEST_ATTEMPTS:
                _append_execution_event(run, "question_request_retry", f"Retrying model request ({attempt + 1}/{MODEL_REQUEST_ATTEMPTS}).", qaIds=qa_ids, error=str(exc))
                time.sleep(REQUEST_COOLDOWN_SEC)
    requested_ids = ", ".join(qa_id or "<unknown>" for qa_id in qa_ids)
    raise RuntimeError(f"Model request failed for QA pair(s) {requested_ids} after {MODEL_REQUEST_ATTEMPTS} attempt(s) of up to {REQUEST_TIMEOUT_SEC}s: {last_error}") from last_error


def _complete_answer(litellm: Any, run: dict[str, Any], item: dict[str, Any], messages: list[dict[str, Any]]) -> dict[str, str]:
    model = str(run.get("model") or "").strip()
    response = _request_model_completion(litellm, run, [item], messages, MAX_TOKENS)
    raw_answer = _completion_text(response)
    parsed = _parse_model_answer(raw_answer)
    correct = _score_answer(item, parsed)
    return _benchmark_result_row(item, model, raw_answer, parsed, correct)


def _complete_answers_batch(litellm: Any, run: dict[str, Any], items: list[dict[str, Any]], messages: list[dict[str, Any]]) -> list[dict[str, str]]:
    model = str(run.get("model") or "").strip()
    response = _request_model_completion(litellm, run, items, messages, max(MAX_TOKENS, 400 * len(items)))
    raw_answer = _completion_text(response)
    parsed_answers = _parse_model_answers_batch(raw_answer, items)
    rows: list[dict[str, str]] = []
    for item in items:
        qa_id = str(item.get("id") or item.get("qa_id") or "")
        parsed = parsed_answers.get(qa_id)
        if parsed is None:
            raise RuntimeError(f"Batched model response did not include an answer for QA pair {qa_id or '<unknown>'}.")
        correct = _score_answer(item, parsed)
        rows.append(_benchmark_result_row(item, model, raw_answer, parsed, correct))
    return rows


def _benchmark_result_row(item: dict[str, Any], model: str, raw_answer: str, parsed: dict[str, Any], correct: bool) -> dict[str, str]:
    return {
        "qa_key": _qa_pair_key(item),
        "qa_id": str(item.get("id") or item.get("qa_id") or ""),
        "video_id": _normalized_qa_video_id(item),
        "question": str(item.get("question") or ""),
        "answer_format": str(item.get("answer_format") or ""),
        "family": str(item.get("family") or ""),
        "reasoning_types": ",".join(str(x) for x in list(item.get("reasoning_types") or [])),
        "difficulty": str(item.get("difficulty") or ""),
        "visibility": str(item.get("visibility") or ""),
        "day_night": str(item.get("day_night") or ""),
        "unanswerable_gt": _bool_text(bool(item.get("unanswerable", False))),
        "ground_truth_resolved": _answer_text(item.get("answer")),
        "model": model,
        "raw_model_answer": raw_answer,
        "parsed_model_answer": _answer_text(parsed.get("answer")),
        "is_correct": _bool_text(correct),
        "score_method": "rule_based",
        "model_declared_unanswerable": _bool_text(bool(parsed.get("unanswerable", False))),
    }


def _resolve_video_path(item: dict[str, Any]) -> Path:
    video_id = _normalized_qa_video_id(item)
    qa_dir = _safe_resolve(_mounted_root(), str(item.get("_qa_file") or "")).parent
    candidates: list[Path] = []
    for root in (qa_dir, qa_dir.parent, _mounted_root()):
        for ext in VIDEO_EXTENSIONS:
            candidates.extend(root.glob(f"{video_id}{ext}"))
            candidates.extend(root.glob(f"{video_id}.*{ext}"))
    if not candidates:
        for path in _mounted_root().rglob("*"):
            if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS and path.stem == video_id:
                candidates.append(path)
                break
    if not candidates:
        raise RuntimeError(f"Could not resolve video file for video_id '{video_id}'.")
    return candidates[0].resolve()


def _normalized_qa_video_id(item: dict[str, Any]) -> str:
    video_id = str(item.get("video_id") or "").strip()
    suffix = Path(video_id).suffix.lower()
    if suffix in VIDEO_EXTENSIONS:
        return video_id[: -len(suffix)]
    return video_id


def _sample_evidence_frames(cv2: Any, video_path: Path, item: dict[str, Any], frame_sample_rate: int, frame_dir: Path) -> list[Path]:
    spans = list(item.get("evidence_spans") or [])
    if not spans:
        spans = [{"start_seconds": 0, "end_seconds": 0}]
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video file: {video_path.name}")
    try:
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0) or 1.0
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        selected: list[int] = []
        for span in spans:
            if not isinstance(span, dict):
                continue
            start = max(0, int(float(span.get("start_seconds") or 0) * fps))
            end = int(float(span.get("end_seconds") if span.get("end_seconds") is not None else span.get("start_seconds") or 0) * fps)
            end = max(start, min(max(0, frame_count - 1), end))
            selected.extend(range(start, end + 1, max(1, frame_sample_rate)))
        if not selected:
            selected = [0]
        paths: list[Path] = []
        for frame_idx in _limited_frame_indices(sorted(set(selected))):
            paths.append(_extract_frame(cv2, cap, video_path, frame_idx, frame_dir))
        return paths
    finally:
        cap.release()


def _limited_frame_indices(indices: list[int]) -> list[int]:
    if len(indices) <= MAX_EVIDENCE_FRAMES:
        return indices
    if MAX_EVIDENCE_FRAMES == 1:
        return [indices[len(indices) // 2]]
    return [indices[round(index * (len(indices) - 1) / (MAX_EVIDENCE_FRAMES - 1))] for index in range(MAX_EVIDENCE_FRAMES)]


def _extract_frame(cv2: Any, cap: Any, video_path: Path, frame_idx: int, frame_dir: Path) -> Path:
    frame_dir.mkdir(parents=True, exist_ok=True)
    safe_stem = re.sub(r"[^A-Za-z0-9._-]+", "_", video_path.stem).strip("._-") or "video"
    out_path = frame_dir / f"{safe_stem}_f{frame_idx:06d}.jpg"
    if out_path.is_file():
        return out_path
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(frame_idx))
    ok, frame = cap.read()
    if not ok or frame is None:
        raise RuntimeError(f"Unable to extract frame {frame_idx} from {video_path.name}.")
    height, width = frame.shape[:2]
    longest_edge = max(width, height)
    if longest_edge > MAX_FRAME_DIMENSION:
        scale = MAX_FRAME_DIMENSION / longest_edge
        frame = cv2.resize(frame, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA)
    if not cv2.imwrite(str(out_path), frame, [cv2.IMWRITE_JPEG_QUALITY, 85]):
        raise RuntimeError(f"Unable to write extracted frame: {out_path}")
    return out_path


def _prompt_content(item: dict[str, Any], frame_paths: list[Path]) -> list[dict[str, Any]]:
    answer_format = str(item.get("answer_format") or "open_ended")
    choices = list(item.get("choices") or [])
    prompt = (
        "You are evaluating a benchmark question against sampled frames from the relevant video evidence span. "
        "Answer only from the provided frames. If the frames do not contain enough evidence, mark the question unanswerable.\n\n"
        f"Question: {item.get('question') or ''}\n"
        f"Expected answer format: {answer_format}\n"
        f"Choices, if any: {json.dumps(choices, ensure_ascii=True)}\n\n"
        "Return exactly one JSON object with this schema and no markdown:\n"
        "{\"answer\": <string|number|boolean|null>, \"unanswerable\": <true|false>}\n"
        "For yes_no, use true for yes and false for no. For multiple_choice, answer with one of the choices exactly. "
        "For numeric, answer with only the number."
    )
    content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
    for path in frame_paths:
        with path.open("rb") as handle:
            image_b64 = base64.b64encode(handle.read()).decode("ascii")
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}})
    return content


def _batch_prompt_content(items: list[dict[str, Any]], frame_paths: list[Path]) -> list[dict[str, Any]]:
    questions = []
    for item in items:
        questions.append({
            "qa_id": str(item.get("id") or item.get("qa_id") or ""),
            "question": str(item.get("question") or ""),
            "answer_format": str(item.get("answer_format") or "open_ended"),
            "choices": list(item.get("choices") or []),
        })
    prompt = (
        "You are evaluating benchmark questions against one shared set of sampled frames from the same video evidence span. "
        "Answer every question only from the provided frames. If the frames do not contain enough evidence for a question, mark that question unanswerable.\n\n"
        f"Questions: {json.dumps(questions, ensure_ascii=True)}\n\n"
        "Return exactly one JSON object with this schema and no markdown:\n"
        "{\"answers\": [{\"qa_id\": <string>, \"answer\": <string|number|boolean|null>, \"unanswerable\": <true|false>}]}\n"
        "Return one answers item for every qa_id. For yes_no, use true for yes and false for no. "
        "For multiple_choice, answer with one of that question's choices exactly. For numeric, answer with only the number."
    )
    content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
    for path in frame_paths:
        with path.open("rb") as handle:
            image_b64 = base64.b64encode(handle.read()).decode("ascii")
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}})
    return content


def _parse_model_answer(raw: str) -> dict[str, Any]:
    text = raw.strip()
    match = re.search(r"\{.*\}", text, flags=re.S)
    if match:
        try:
            payload = json.loads(match.group(0))
            if isinstance(payload, dict):
                return {"answer": payload.get("answer"), "unanswerable": bool(payload.get("unanswerable", False))}
        except Exception:
            pass
    lowered = text.lower()
    if "unanswerable" in lowered or "cannot determine" in lowered or "not enough evidence" in lowered:
        return {"answer": None, "unanswerable": True}
    if lowered in {"yes", "true"}:
        return {"answer": True, "unanswerable": False}
    if lowered in {"no", "false"}:
        return {"answer": False, "unanswerable": False}
    return {"answer": text, "unanswerable": False}


def _parse_model_answers_batch(raw: str, items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    text = raw.strip()
    match = re.search(r"\{.*\}", text, flags=re.S)
    if not match:
        raise RuntimeError("Batched model response did not contain a JSON object.")
    payload = json.loads(match.group(0))
    if not isinstance(payload, dict) or not isinstance(payload.get("answers"), list):
        raise RuntimeError("Batched model response must contain an answers list.")
    expected_ids = {str(item.get("id") or item.get("qa_id") or "") for item in items}
    parsed: dict[str, dict[str, Any]] = {}
    for answer_item in payload["answers"]:
        if not isinstance(answer_item, dict):
            continue
        qa_id = str(answer_item.get("qa_id") or answer_item.get("id") or "")
        if qa_id not in expected_ids:
            continue
        parsed[qa_id] = {"answer": answer_item.get("answer"), "unanswerable": bool(answer_item.get("unanswerable", False))}
    return parsed


def _score_answer(item: dict[str, Any], parsed: dict[str, Any]) -> bool:
    if bool(item.get("unanswerable", False)):
        return bool(parsed.get("unanswerable", False))
    if bool(parsed.get("unanswerable", False)):
        return False
    expected = item.get("answer")
    actual = parsed.get("answer")
    answer_format = str(item.get("answer_format") or "").lower()
    if answer_format == "numeric":
        try:
            return abs(float(expected) - float(actual)) <= 1e-6
        except Exception:
            return False
    expected_norms = {_normalize_answer(expected)}
    expected_norms.update(_normalize_answer(alias) for alias in list(item.get("answer_aliases") or []))
    return _normalize_answer(actual) in expected_norms


def _normalize_answer(value: Any) -> str:
    if isinstance(value, bool):
        return "yes" if value else "no"
    text = str(value if value is not None else "").strip().lower()
    if text in {"true", "yes", "y"}:
        return "yes"
    if text in {"false", "no", "n"}:
        return "no"
    return re.sub(r"\s+", " ", text)


def _answer_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=True, sort_keys=True)
    return str(value)


def _bool_text(value: bool) -> str:
    return "true" if value else "false"


def _completion_text(response: Any) -> str:
    if isinstance(response, str):
        return response.strip()
    try:
        content = response["choices"][0]["message"].get("content", "")
        return content.strip() if isinstance(content, str) else str(content).strip()
    except Exception:
        pass
    for attr in ("to_dict_recursive", "model_dump", "dict"):
        fn = getattr(response, attr, None)
        if callable(fn):
            try:
                payload = fn()
                content = (((payload.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
                return content.strip() if isinstance(content, str) else str(content).strip()
            except Exception:
                pass
    return ""


def _stream_completion_text(stream: Any) -> str:
    parts: list[str] = []
    for chunk in stream:
        if isinstance(chunk, bytes):
            chunk = chunk.decode("utf-8").strip()
        if isinstance(chunk, str):
            if not chunk.startswith("data:"):
                continue
            data = chunk.removeprefix("data:").strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
        content = _stream_chunk_content(chunk)
        if content:
            parts.append(content)
    return "".join(parts).strip()


def _stream_chunk_content(chunk: Any) -> str:
    if isinstance(chunk, dict):
        payload = chunk
    else:
        payload = None
        for attr in ("to_dict_recursive", "model_dump", "dict"):
            fn = getattr(chunk, attr, None)
            if callable(fn):
                try:
                    payload = fn()
                    break
                except Exception:
                    continue
    if not isinstance(payload, dict):
        return ""
    choices = payload.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return ""
    delta = choices[0].get("delta") or {}
    content = delta.get("content") if isinstance(delta, dict) else ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(str(part.get("text") or "") for part in content if isinstance(part, dict))
    return ""


def _result_count(path: Path) -> int:
    if not path.is_file():
        return 0
    with path.open("r", encoding="utf-8", newline="") as handle:
        return max(0, sum(1 for _ in handle) - 1)


def _result_count_excluding(path: Path, excluded_qa_keys: set[str]) -> int:
    if not path.is_file() or path.stat().st_size == 0:
        return 0
    with path.open("r", encoding="utf-8", newline="") as handle:
        return sum(1 for row in csv.DictReader(handle) if _result_row_key(row) not in excluded_qa_keys)


def _completed_qa_keys_from_results(path: Path) -> set[str]:
    if not path.is_file() or path.stat().st_size == 0:
        return set()
    with path.open("r", encoding="utf-8", newline="") as handle:
        keys: set[str] = set()
        for row in csv.DictReader(handle):
            key = _result_row_key(row)
            if key:
                keys.add(key)
        return keys


def _completed_qa_keys_from_events(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    keys: set[str] = set()
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except Exception:
                continue
            if not isinstance(row, dict) or row.get("type") not in {"question_done", "question_skipped"}:
                continue
            qa_key = str(row.get("qaKey") or "")
            if qa_key:
                keys.add(qa_key)
    return keys


def _import_required(module_name: str, message: str) -> Any:
    try:
        return __import__(module_name)
    except Exception as exc:
        raise RuntimeError(message) from exc

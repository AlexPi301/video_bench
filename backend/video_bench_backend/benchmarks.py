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
from pathlib import Path
from typing import Any

from django.conf import settings
from django.http import Http404, HttpRequest, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST, require_http_methods


VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
RESULT_FIELDS = [
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
REQUEST_TIMEOUT_SEC = 2000
MAX_TOKENS = 1200
_LOCK = threading.Lock()
_RUNNING: dict[str, threading.Event] = {}


def _mounted_root() -> Path:
    return Path(getattr(settings, "VIDEO_BENCH_MOUNTED_FILES_ROOT", "/mounted-input")).resolve()


def _benchmark_root() -> Path:
    return _mounted_root() / "benchmark_runs"


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


def _run_dir(run_id: str) -> Path:
    return _benchmark_root() / _safe_run_id(run_id)


def _details_path(run_id: str) -> Path:
    return _run_dir(run_id) / "details.json"


def _results_path(run_id: str) -> Path:
    return _run_dir(run_id) / "results.csv"


def _events_path(run_id: str) -> Path:
    return _run_dir(run_id) / "events.jsonl"


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


def _all_runs() -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    _benchmark_root().mkdir(parents=True, exist_ok=True)
    for path in sorted(_benchmark_root().glob("*/details.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        try:
            with path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            if isinstance(payload, dict):
                runs.append(payload)
        except Exception:
            continue
    return runs


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
def create_benchmark_run(request: HttpRequest) -> JsonResponse:
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

    run_id = _run_stamp()
    run_dir = output_base / run_id
    suffix = 1
    while run_dir.exists():
        suffix += 1
        run_dir = output_base / f"{run_id}-{suffix}"
    run_id = run_dir.name
    run_dir.mkdir(parents=True, exist_ok=False)

    now = _now_iso()
    run = {
        "id": run_id,
        "name": name,
        "creation_date": str(payload.get("creationDate") or now),
        "run_date": str(payload.get("runDate") or ""),
        "description": str(payload.get("description") or ""),
        "lm_studio_url": str(payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip(),
        "model": str(payload.get("model") or "google/gemma-4-31b").strip(),
        "frame_sample_rate": max(1, int(payload.get("frameSampleRate") or 15)),
        "save_sample_frames": _bool_payload(payload, "saveSampleFrames"),
        "output_folder": output_folder,
        "qa_files": qa_files,
        "status": "created",
        "created_at": now,
        "updated_at": now,
        "started_at": "",
        "completed_at": "",
        "progress": {"processedQuestions": 0, "totalQuestions": 0, "percent": 0},
        "error": "",
        "run_dir": str(run_dir),
        "results_path": str(run_dir / "results.csv"),
    }
    _save_run(run)
    _append_event(run_id, "created", "Benchmark run created.")
    return JsonResponse(_run_response(run), status=201)


@require_GET
def get_benchmark_run(_request: HttpRequest, run_id: str) -> JsonResponse:
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
def delete_benchmark_run(_request: HttpRequest, run_id: str) -> JsonResponse:
    run = _load_run(run_id)
    if str(run.get("status")) == "running" or run_id in _RUNNING:
        return JsonResponse({"error": "Cannot delete a running benchmark run."}, status=409)
    directory = _run_dir(run_id)
    if directory.exists():
        shutil.rmtree(directory)
    return JsonResponse({"deleted": True, "id": run_id})


@csrf_exempt
@require_POST
def start_benchmark_run(_request: HttpRequest, run_id: str) -> JsonResponse:
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


@csrf_exempt
@require_POST
def resume_benchmark_run(_request: HttpRequest, run_id: str) -> JsonResponse:
    run = _load_run(run_id)
    if run_id in _RUNNING or str(run.get("status")) in {"queued", "running"}:
        return JsonResponse({"error": "Benchmark run is already running."}, status=409)
    if str(run.get("status")) != "failed":
        return JsonResponse({"error": "Only failed benchmark runs can be resumed."}, status=409)
    event = threading.Event()
    _RUNNING[run_id] = event
    _update_run(run_id, status="queued", error="")
    _append_event(run_id, "queued", "Benchmark run queued for resume.")
    thread = threading.Thread(target=_run_benchmark_worker, args=(run_id, event, True), daemon=True)
    thread.start()
    return JsonResponse(_run_response(_load_run(run_id)))


@require_GET
def get_benchmark_run_events(request: HttpRequest, run_id: str) -> JsonResponse:
    _load_run(run_id)
    after = int(request.GET.get("after", "0") or 0)
    rows: list[dict[str, Any]] = []
    path = _events_path(run_id)
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


def _run_response(run: dict[str, Any]) -> dict[str, Any]:
    out = dict(run)
    out.pop("run_dir", None)
    out["metrics"] = _calculate_metrics(_results_path(str(run.get("id") or "")))
    out["canStart"] = _can_start(run)
    out["canResume"] = _can_resume(run)
    out["resultsUrl"] = f"/api/benchmarks/runs/{run.get('id')}/results/"
    return out


@require_GET
def get_benchmark_results(_request: HttpRequest, run_id: str) -> JsonResponse:
    _load_run(run_id)
    path = _results_path(run_id)
    rows: list[dict[str, str]] = []
    if path.is_file():
        with path.open("r", encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
    return JsonResponse({"rows": rows})


def _can_start(run: dict[str, Any]) -> bool:
    run_id = str(run.get("id") or "")
    if run_id in _RUNNING or str(run.get("status")) != "created":
        return False
    path = _results_path(run_id)
    return not path.exists() or _result_count(path) == 0


def _can_resume(run: dict[str, Any]) -> bool:
    run_id = str(run.get("id") or "")
    return run_id not in _RUNNING and str(run.get("status")) == "failed"


def _calculate_metrics(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.stat().st_size == 0:
        return {"total": {"correct": 0, "count": 0, "percent": 0.0}, "byFamily": {}, "dayNight": {}}
    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))

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


def _run_benchmark_worker(run_id: str, cancel_event: threading.Event, resume: bool = False) -> None:
    try:
        run = _update_run(run_id, status="running", started_at=_now_iso(), run_date=_now_iso())
        _append_event(run_id, "started", "Benchmark execution resumed." if resume else "Benchmark execution started.")
        _execute_benchmark(run, cancel_event, resume=resume)
        if str(_load_run(run_id).get("status")) == "cancelled":
            return
        _update_run(run_id, status="completed", completed_at=_now_iso(), progress={"processedQuestions": _result_count(_results_path(run_id)), "totalQuestions": _result_count(_results_path(run_id)), "percent": 100})
        _append_event(run_id, "completed", "Benchmark execution completed.")
    except Exception as exc:
        _update_run(run_id, status="failed", error=str(exc))
        _append_event(run_id, "error", str(exc), traceback=traceback.format_exc(limit=8))
    finally:
        _RUNNING.pop(run_id, None)


def _execute_benchmark(run: dict[str, Any], cancel_event: threading.Event, resume: bool = False) -> None:
    cv2 = _import_required("cv2", "OpenCV is required for benchmark frame extraction.")
    litellm = _import_required("litellm", "LiteLLM is required for LM Studio benchmark calls.")
    run_id = str(run.get("id") or "")
    questions = _load_all_questions(list(run.get("qa_files") or []))
    total = len(questions)
    resume_index = _resume_index_from_events(run_id, questions) if resume else 0
    percent = round(resume_index * 100 / max(1, total))
    _update_run(run_id, progress={"processedQuestions": resume_index, "totalQuestions": total, "percent": percent})
    if resume:
        _append_event(run_id, "qa_loaded", f"Loaded {total} benchmark question(s). Resuming at question {min(resume_index + 1, total + 1)}/{total}.")
    else:
        _append_event(run_id, "qa_loaded", f"Loaded {total} benchmark question(s).")

    results_path = _results_path(run_id)
    results_path.parent.mkdir(parents=True, exist_ok=True)
    if resume:
        _trim_results_for_resume(results_path, resume_index)
    mode = "a" if resume else "w"
    with results_path.open(mode, encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=RESULT_FIELDS)
        if mode == "w":
            writer.writeheader()
        for index, item in enumerate(questions[resume_index:], start=resume_index + 1):
            if cancel_event.is_set():
                _update_run(run_id, status="cancelled")
                _append_event(run_id, "cancelled", "Benchmark execution cancelled.")
                return
            qa_id = str(item.get("id") or item.get("qa_id") or "")
            try:
                row = _answer_question(cv2, litellm, run, item)
            except Exception as exc:
                raise RuntimeError(f"Failed processing QA pair {qa_id or '<unknown>'}: {exc}") from exc
            writer.writerow(row)
            handle.flush()
            percent = round(index * 100 / max(1, total))
            _update_run(run_id, progress={"processedQuestions": index, "totalQuestions": total, "percent": percent})
            _append_event(run_id, "question_done", f"Answered question {index}/{total}.", qaId=row["qa_id"], percent=percent)


def _resume_index_from_events(run_id: str, questions: list[dict[str, Any]]) -> int:
    last_completed_qa_id = ""
    completed_count = 0
    path = _events_path(run_id)
    if path.is_file():
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if not isinstance(row, dict) or row.get("type") != "question_done":
                    continue
                completed_count += 1
                last_completed_qa_id = str(row.get("qaId") or "")
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


def _answer_question(cv2: Any, litellm: Any, run: dict[str, Any], item: dict[str, Any]) -> dict[str, str]:
    video_path = _resolve_video_path(item)
    if bool(run.get("save_sample_frames", False)):
        frame_paths = _sample_evidence_frames(cv2, video_path, item, int(run.get("frame_sample_rate") or 15), _run_dir(str(run.get("id") or "")) / "frames")
        messages = [{"role": "user", "content": _prompt_content(item, frame_paths)}]
    else:
        with tempfile.TemporaryDirectory(prefix="video-bench-frames-") as tmp_dir:
            frame_paths = _sample_evidence_frames(cv2, video_path, item, int(run.get("frame_sample_rate") or 15), Path(tmp_dir))
            messages = [{"role": "user", "content": _prompt_content(item, frame_paths)}]
            return _complete_answer(litellm, run, item, messages)

    return _complete_answer(litellm, run, item, messages)


def _complete_answer(litellm: Any, run: dict[str, Any], item: dict[str, Any], messages: list[dict[str, Any]]) -> dict[str, str]:
    model = str(run.get("model") or "").strip()
    litellm_model = model if model.startswith("openai/") else f"openai/{model}"
    response = litellm.completion(
        model=litellm_model,
        api_base=str(run.get("lm_studio_url") or "").strip(),
        api_key="lm-studio",
        messages=messages,
        temperature=0,
        max_tokens=MAX_TOKENS,
        timeout=REQUEST_TIMEOUT_SEC,
    )
    raw_answer = _completion_text(response)
    parsed = _parse_model_answer(raw_answer)
    correct = _score_answer(item, parsed)
    return {
        "qa_id": str(item.get("id") or item.get("qa_id") or ""),
        "video_id": str(item.get("video_id") or ""),
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
    video_id = str(item.get("video_id") or "").strip()
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
        for frame_idx in sorted(set(selected)):
            paths.append(_extract_frame(cv2, cap, video_path, frame_idx, frame_dir))
        return paths
    finally:
        cap.release()


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
    if not cv2.imwrite(str(out_path), frame):
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


def _result_count(path: Path) -> int:
    if not path.is_file():
        return 0
    with path.open("r", encoding="utf-8", newline="") as handle:
        return max(0, sum(1 for _ in handle) - 1)


def _import_required(module_name: str, message: str) -> Any:
    try:
        return __import__(module_name)
    except Exception as exc:
        raise RuntimeError(message) from exc

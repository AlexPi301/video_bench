"""HTTP API for running IMPACT_CYCLE metadata generation jobs."""

from __future__ import annotations

import json
import math
import mimetypes
import os
import re
import shutil
import sys
import threading
import time
import traceback
import uuid
import csv
import base64
from pathlib import Path
from typing import Any
from urllib.parse import quote

from django.conf import settings
from django.http import Http404, HttpRequest, HttpResponse, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST, require_safe


VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
WORKFLOW_OPERATIONS = {"vqa_generate", "track_objects", "cycle_verify", "scene_graph_eval", "vqa_eval", "caption_generate", "qa_pairs_generate"}
TRACKED_LABELS = {"person", "truck", "plane", "car"}
DEFAULT_SAM3_PROMPT_LABELS = ("car", "truck", "person", "plane", "bicycle", "traffic light", "boat", "train", "tram")
CAPTION_MAX_TOKENS = 20000
CAPTION_REQUEST_TIMEOUT_SEC = 2000
CAPTION_TIMEOUT_ATTEMPTS = 20
QA_PAIR_RETRY_ATTEMPTS = 5
QA_CORE_FAMILIES = ("object_attribute", "action_event", "temporal_reasoning", "trajectory_grounded", "day_night_robustness")
QA_ALLOWED_ANSWER_FORMATS = ("multiple_choice", "yes_no", "numeric")
_STORE_LOCK = threading.Lock()
_RUNNING: dict[str, threading.Event] = {}
_LM_STUDIO_FAILURES: list[dict[str, Any]] = []


def _impact_root() -> Path:
    return Path(getattr(settings, "VIDEO_BENCH_IMPACT_CYCLE_ROOT", "/data/impact-cycle")).resolve()


def _mounted_root() -> Path:
    return Path(getattr(settings, "VIDEO_BENCH_MOUNTED_FILES_ROOT", "/mounted-input")).resolve()


def _jobs_dir() -> Path:
    return _impact_root() / "jobs"


def _uploads_dir() -> Path:
    return _impact_root() / "uploads"


def _runs_dir() -> Path:
    return _impact_root() / "runs"


def _safe_resolve(root: Path, relative_path: str) -> Path:
    candidate = (root / str(relative_path or "")).resolve()
    try:
        common = os.path.commonpath([str(root), str(candidate)])
    except ValueError as exc:
        raise Http404("Invalid path.") from exc
    if common != str(root):
        raise Http404("Path escapes the configured root.")
    return candidate


def _safe_filename(name: str) -> str:
    stem = Path(str(name or "video")).name
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._-")
    return stem or "video"


def _json_request(request: HttpRequest) -> dict[str, Any]:
    if not request.body:
        return {}
    try:
        payload = json.loads(request.body.decode("utf-8"))
    except Exception as exc:
        raise ValueError(f"Invalid JSON body: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object.")
    return payload


def _job_path(job_id: str) -> Path:
    token = str(job_id or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
        raise Http404("Invalid job id.")
    return _jobs_dir() / f"{token}.json"


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=True, indent=2)
        f.write("\n")
    tmp.replace(path)


def _load_job(job_id: str) -> dict[str, Any]:
    path = _job_path(job_id)
    if not path.is_file():
        raise Http404("Impact Cycle job not found.")
    with path.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        raise Http404("Impact Cycle job is invalid.")
    return payload


def _save_job(job: dict[str, Any]) -> None:
    _write_json_atomic(_job_path(str(job.get("id", ""))), job)


def _update_job(job_id: str, **updates: Any) -> dict[str, Any]:
    with _STORE_LOCK:
        job = _load_job(job_id)
        job.update(updates)
        job["updated_at"] = _now_iso()
        _save_job(job)
        return job


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _append_event(job: dict[str, Any], event_type: str, message: str, **fields: Any) -> None:
    events_path = Path(str(job.get("events_path", "")))
    if not events_path:
        return
    events_path.parent.mkdir(parents=True, exist_ok=True)
    row = {"ts": _now_iso(), "type": event_type, "message": str(message or "")}
    row.update(fields)
    with events_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=True) + "\n")


def _litellm_response_payload(response: Any) -> dict[str, Any]:
    if isinstance(response, dict):
        return response
    for attr in ("to_dict_recursive", "model_dump", "dict"):
        fn = getattr(response, attr, None)
        if callable(fn):
            try:
                payload = fn()
                if isinstance(payload, dict):
                    return payload
            except Exception:
                pass
    return {}


def _litellm_choice_message(response: Any) -> dict[str, Any]:
    try:
        choices = response["choices"]
        if choices:
            message = choices[0]["message"]
            if isinstance(message, dict):
                return message
            payload = _litellm_response_payload(response)
            choices_payload = list(payload.get("choices") or [])
            if choices_payload:
                message_payload = (choices_payload[0] or {}).get("message") or {}
                if isinstance(message_payload, dict):
                    return message_payload
    except Exception:
        pass
    payload = _litellm_response_payload(response)
    choices_payload = list(payload.get("choices") or [])
    if choices_payload:
        message_payload = (choices_payload[0] or {}).get("message") or {}
        if isinstance(message_payload, dict):
            return message_payload
    return {}


def _litellm_completion_text(response: Any) -> str:
    content = _litellm_choice_message(response).get("content", "")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        chunks: list[str] = []
        for part in content:
            if isinstance(part, str):
                text = part.strip()
            elif isinstance(part, dict):
                text = str(part.get("text", "") or "").strip()
            else:
                text = ""
            if text:
                chunks.append(text)
        return "\n".join(chunks).strip()
    return ""


def _litellm_reasoning_text(response: Any) -> str:
    message = _litellm_choice_message(response)
    for value in (
        message.get("reasoning_content"),
        (message.get("provider_specific_fields") or {}).get("reasoning_content") if isinstance(message.get("provider_specific_fields"), dict) else None,
    ):
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _caption_completion_text(response: Any) -> str:
    text = _litellm_completion_text(response)
    if text:
        return text
    reasoning = _litellm_reasoning_text(response)
    if not reasoning:
        return ""
    for marker in ("Drafting the prose:", "Final caption:", "Caption:", "Final answer:", "Output:"):
        marker_index = reasoning.lower().rfind(marker.lower())
        if marker_index >= 0:
            candidate = reasoning[marker_index + len(marker):].strip()
            if candidate:
                return candidate
    return reasoning


def _litellm_empty_completion_details(response: Any) -> str:
    payload = _litellm_response_payload(response)
    choice = {}
    choices = list(payload.get("choices") or [])
    if choices and isinstance(choices[0], dict):
        choice = choices[0]
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    completion_details = usage.get("completion_tokens_details") if isinstance(usage.get("completion_tokens_details"), dict) else {}
    details = {
        "finish_reason": choice.get("finish_reason"),
        "completion_tokens": usage.get("completion_tokens"),
        "reasoning_tokens": completion_details.get("reasoning_tokens"),
    }
    return ", ".join(f"{key}={value}" for key, value in details.items() if value is not None) or "no response details"


def _is_timeout_error(error: Exception | str) -> bool:
    error_lower = str(error).lower()
    return any(keyword in error_lower for keyword in ("timeout", "timed out", "readtimeout", "apitimeout"))


def _caption_output_payload(
    *,
    video_name: str,
    video_rel: str,
    frame_count: int,
    source_fps: float,
    fps_sampling: int,
    model_name: str,
    lm_studio_url: str,
    captions: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "type": "video_bench_captions",
        "version": 1,
        "video_name": video_name,
        "video_path": video_rel,
        "frame_count": int(frame_count),
        "source_fps": float(source_fps),
        "fps_sampling": int(fps_sampling),
        "model": model_name,
        "lm_studio_url": lm_studio_url,
        "caption_count": len(captions),
        "captions": captions,
    }


def _caption_resume_matches(
    payload: dict[str, Any],
    *,
    video_name: str,
    video_rel: str,
    frame_count: int,
    source_fps: float,
    fps_sampling: int,
    model_name: str,
    lm_studio_url: str,
) -> bool:
    try:
        return (
            str(payload.get("type") or "") == "video_bench_captions"
            and str(payload.get("video_name") or "") == video_name
            and str(payload.get("video_path") or "") == video_rel
            and int(payload.get("frame_count") or 0) == int(frame_count)
            and math.ceil(float(payload.get("source_fps") or 0.0)) == math.ceil(float(source_fps))
            and int(payload.get("fps_sampling") or 0) == int(fps_sampling)
            and str(payload.get("model") or "") == model_name
            and str(payload.get("lm_studio_url") or "") == lm_studio_url
        )
    except Exception:
        return False


def _load_resumable_caption_rows(
    out_path: Path,
    *,
    video_name: str,
    video_rel: str,
    frame_count: int,
    source_fps: float,
    fps_sampling: int,
    model_name: str,
    lm_studio_url: str,
    frame_indices: list[int],
) -> tuple[list[dict[str, Any]], bool]:
    if not out_path.is_file():
        return [], False
    try:
        with out_path.open("r", encoding="utf-8") as f:
            payload = json.load(f)
    except Exception:
        return [], False
    if not isinstance(payload, dict) or not _caption_resume_matches(
        payload,
        video_name=video_name,
        video_rel=video_rel,
        frame_count=frame_count,
        source_fps=source_fps,
        fps_sampling=fps_sampling,
        model_name=model_name,
        lm_studio_url=lm_studio_url,
    ):
        return [], False

    allowed = {int(frame_idx) for frame_idx in frame_indices}
    rows_by_frame: dict[int, dict[str, Any]] = {}
    for row in list(payload.get("captions") or []):
        if not isinstance(row, dict):
            continue
        try:
            frame_idx = int(row.get("frame_index"))
        except Exception:
            continue
        caption = str(row.get("caption") or "").strip()
        if frame_idx in allowed and caption:
            rows_by_frame[frame_idx] = dict(row)
    return [rows_by_frame[frame_idx] for frame_idx in frame_indices if frame_idx in rows_by_frame], True


def _public_impact_url(path: Path) -> str:
    rel = path.resolve().relative_to(_impact_root()).as_posix()
    return f"/api/impact-cycle/file/?path={quote(rel)}"


@csrf_exempt
@require_POST
def upload_impact_cycle_video(request: HttpRequest) -> JsonResponse:
    video = request.FILES.get("video")
    if video is None:
        return JsonResponse({"error": "Missing video file field named 'video'."}, status=400)
    filename = _safe_filename(getattr(video, "name", "video"))
    if Path(filename).suffix.lower() not in VIDEO_EXTENSIONS:
        return JsonResponse({"error": "Unsupported video extension."}, status=400)

    upload_id = uuid.uuid4().hex
    out_dir = _uploads_dir() / upload_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / filename
    with out_path.open("wb") as f:
        for chunk in video.chunks():
            f.write(chunk)

    rel = out_path.relative_to(_uploads_dir()).as_posix()
    return JsonResponse(
        {
            "uploadId": upload_id,
            "filename": filename,
            "path": rel,
            "url": _public_impact_url(out_path),
            "size": out_path.stat().st_size,
        },
        status=201,
    )


@csrf_exempt
def create_impact_cycle_job(request: HttpRequest) -> JsonResponse:
    if request.method == "GET":
        return _list_jobs_response()
    if request.method != "POST":
        return JsonResponse({"error": "Method not allowed."}, status=405)

    try:
        payload = _json_request(request)
        source = dict(payload.get("source") or {})
    except ValueError as exc:
        return JsonResponse({"error": str(exc)}, status=400)

    operation = str(payload.get("operation", "sam3_precompute") or "sam3_precompute").strip().lower()
    if operation in {"sam3", "precompute_sam3"}:
        operation = "sam3_precompute"
    if operation != "sam3_precompute" and operation not in WORKFLOW_OPERATIONS:
        return JsonResponse({"error": "Unsupported Impact Cycle operation."}, status=400)

    if operation != "sam3_precompute":
        return _create_impact_cycle_workflow_job(operation, payload)

    source_type = str(source.get("type", "") or "").strip().lower()
    source_path = str(source.get("path", "") or "").strip()
    if source_type not in {"mounted", "upload"}:
        return JsonResponse({"error": "source.type must be mounted or upload."}, status=400)
    try:
        if source_type == "mounted":
            video_path = _safe_resolve(_mounted_root(), source_path)
        else:
            video_path = _safe_resolve(_uploads_dir(), source_path)
    except Http404 as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    if not video_path.is_file() or video_path.suffix.lower() not in VIDEO_EXTENSIONS:
        return JsonResponse({"error": "Selected video file was not found or is unsupported."}, status=400)

    settings_payload = dict(payload.get("settings") or {})
    backend_provider = str(settings_payload.get("backendProvider", "sam3") or "sam3").strip().lower()
    if backend_provider != "sam3":
        return JsonResponse({"error": "settings.backendProvider must be sam3."}, status=400)

    job_id = uuid.uuid4().hex
    output_directory = str(settings_payload.get("outputDirectory", "") or "").strip()
    direct_output = bool(settings_payload.get("directOutput", False))
    try:
        output_base = _safe_resolve(_mounted_root(), output_directory)
    except Http404 as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    if direct_output:
        output_base.mkdir(parents=True, exist_ok=True)
    if not output_base.exists() or not output_base.is_dir():
        return JsonResponse({"error": "settings.outputDirectory must be an existing mounted directory."}, status=400)

    run_dir = _runs_dir() / job_id
    output_dir = output_base if direct_output else output_base / f"{_safe_filename(video_path.stem)}_sam3_metadata_{job_id[:8]}"
    job = {
        "id": job_id,
        "operation": operation,
        "status": "queued",
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
        "source": {"type": source_type, "path": source_path, "absolute_path": str(video_path)},
        "video": {"name": video_path.name, "url": _public_impact_url(video_path) if source_type == "upload" else f"/api/mounted-files/file/?path={quote(source_path)}"},
        "settings": {
            "samplingFps": float(settings_payload.get("samplingFps", 1.0) or 1.0),
            "maxFrames": int(settings_payload.get("maxFrames", 3) or 3),
            "backendProvider": backend_provider,
            "enableSentenceRefine": bool(settings_payload.get("enableSentenceRefine", False)),
            "runCycleRefine": bool(settings_payload.get("runCycleRefine", False)),
            "directOutput": direct_output,
        },
        "progress": {"processedFrames": 0, "totalFrames": 0, "percent": 0},
        "run_dir": str(run_dir),
        "output_dir": str(output_dir),
        "output_path": output_dir.relative_to(_mounted_root()).as_posix(),
        "bundle_path": str(output_dir / "scene_graph_bundle.json"),
        "events_path": str(run_dir / "events.jsonl"),
        "error": "",
    }
    with _STORE_LOCK:
        _save_job(job)
    _append_event(job, "queued", "SAM3 detection precompute job queued.")
    _start_job_thread(job_id)
    return JsonResponse(_job_response(job), status=201)


def _create_impact_cycle_workflow_job(operation: str, payload: dict[str, Any]) -> JsonResponse:
    settings_payload = dict(payload.get("settings") or {})
    inputs = dict(payload.get("inputs") or {})
    bundle_path = str(inputs.get("bundlePath") or settings_payload.get("bundlePath") or "").strip()
    pred_path = str(inputs.get("predPath") or settings_payload.get("predPath") or "").strip()
    gt_path = str(inputs.get("gtPath") or settings_payload.get("gtPath") or "").strip()
    video_path = str(inputs.get("videoPath") or settings_payload.get("videoPath") or "").strip()
    output_directory = str(settings_payload.get("outputDirectory", "") or "").strip()
    direct_output = bool(settings_payload.get("directOutput", False))
    if not output_directory:
        seed = bundle_path or pred_path or gt_path or video_path
        parent = Path(seed).parent.as_posix() if seed else ""
        output_directory = "" if parent == "." else parent
    try:
        output_base = _safe_resolve(_mounted_root(), output_directory)
    except Http404 as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    if direct_output:
        output_base.mkdir(parents=True, exist_ok=True)
    if not output_base.exists() or not output_base.is_dir():
        return JsonResponse({"error": "settings.outputDirectory must be an existing mounted directory."}, status=400)

    required = {
        "vqa_generate": [bundle_path],
        "track_objects": [bundle_path, video_path],
        "cycle_verify": [bundle_path],
        "scene_graph_eval": [pred_path, gt_path],
        "vqa_eval": [pred_path, gt_path],
        "caption_generate": [video_path],
        "qa_pairs_generate": [video_path],
    }[operation]
    if any(not item for item in required):
        return JsonResponse({"error": "Missing required workflow input path."}, status=400)

    job_id = uuid.uuid4().hex
    run_dir = _runs_dir() / job_id
    output_dir = output_base if direct_output else output_base / f"impact_cycle_{operation}_{job_id[:8]}"
    job = {
        "id": job_id,
        "operation": operation,
        "status": "queued",
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
        "source": {"type": "workflow", "path": bundle_path or pred_path},
        "video": {"name": operation, "url": ""},
        "settings": settings_payload,
        "inputs": {"bundlePath": bundle_path, "predPath": pred_path, "gtPath": gt_path, "videoPath": video_path},
        "progress": {"processedFrames": 0, "totalFrames": 0, "percent": 0},
        "run_dir": str(run_dir),
        "output_dir": str(output_dir),
        "output_path": output_dir.relative_to(_mounted_root()).as_posix(),
        "bundle_path": str(_safe_resolve(_mounted_root(), bundle_path)) if bundle_path else "",
        "events_path": str(run_dir / "events.jsonl"),
        "artifacts": [],
        "error": "",
    }
    with _STORE_LOCK:
        _save_job(job)
    _append_event(job, "queued", f"Impact Cycle {operation} job queued.")
    _start_job_thread(job_id)
    return JsonResponse(_job_response(job), status=201)


@require_GET
def list_impact_cycle_jobs(_request: HttpRequest) -> JsonResponse:
    return _list_jobs_response()


def _list_jobs_response() -> JsonResponse:
    return JsonResponse({"jobs": [_job_response(job) for job in _all_jobs()]})


def _all_jobs() -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    _jobs_dir().mkdir(parents=True, exist_ok=True)
    for path in sorted(_jobs_dir().glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            with path.open("r", encoding="utf-8") as f:
                payload = json.load(f)
            if isinstance(payload, dict):
                jobs.append(payload)
        except Exception:
            continue
    return jobs


@require_GET
def get_impact_cycle_job(_request: HttpRequest, job_id: str) -> JsonResponse:
    return JsonResponse(_job_response(_load_job(job_id)))


@require_GET
def get_impact_cycle_job_events(request: HttpRequest, job_id: str) -> JsonResponse:
    job = _load_job(job_id)
    after = int(request.GET.get("after", "0") or 0)
    rows: list[dict[str, Any]] = []
    path = Path(str(job.get("events_path", "")))
    if path.is_file():
        with path.open("r", encoding="utf-8") as f:
            for index, line in enumerate(f, start=1):
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


@require_GET
def get_impact_cycle_bundle(_request: HttpRequest, job_id: str) -> JsonResponse:
    job = _load_job(job_id)
    path = Path(str(job.get("bundle_path", "")))
    if not path.is_file():
        return JsonResponse({"error": "Scene graph bundle is not available yet."}, status=404)
    with path.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        return JsonResponse({"error": "Scene graph bundle is invalid."}, status=500)
    return JsonResponse(payload)


@require_GET
def get_impact_cycle_activities(_request: HttpRequest) -> JsonResponse:
    activities: list[dict[str, Any]] = []
    for failure in list(_LM_STUDIO_FAILURES):
        activities.append(dict(failure))
    for job in _all_jobs():
        if str(job.get("status")) == "failed":
            activities.append({"type": "job", "status": "failed", "message": str(job.get("error") or "Detection job failed."), "jobId": str(job.get("id") or "")})
    return JsonResponse({"activities": activities})


@csrf_exempt
@require_POST
def cancel_impact_cycle_job(_request: HttpRequest, job_id: str) -> JsonResponse:
    job = _load_job(job_id)
    cancel_event = _RUNNING.get(job_id)
    if cancel_event is not None:
        cancel_event.set()
    if str(job.get("status")) in {"queued", "running"}:
        job = _update_job(job_id, status="cancelled")
        _append_event(job, "cancelled", "Cancellation requested.")
    _cleanup_unfinished_job_files(job)
    return JsonResponse(_job_response(job))


@require_safe
def serve_impact_cycle_file(request: HttpRequest) -> HttpResponse:
    requested_path = str(request.GET.get("path", "") or "")
    if not requested_path:
        raise Http404("Missing file path.")
    path = _safe_resolve(_impact_root(), requested_path)
    if not path.is_file():
        raise Http404("File not found.")
    response = HttpResponse(status=200)
    content_type, _encoding = mimetypes.guess_type(path.name)
    if content_type:
        response["Content-Type"] = content_type
    response["Content-Disposition"] = f'inline; filename="{path.name}"'
    response["X-Accel-Redirect"] = "/_impact-cycle-internal/" + quote(path.relative_to(_impact_root()).as_posix())
    return response


def _job_response(job: dict[str, Any]) -> dict[str, Any]:
    out = dict(job)
    out.pop("events_path", None)
    out.pop("source", None)
    bundle_path = Path(str(job.get("bundle_path", "")))
    if bundle_path.is_file():
        out["bundleUrl"] = f"/api/impact-cycle/jobs/{job.get('id')}/bundle/"
    artifacts = []
    for artifact in list(job.get("artifacts") or []):
        if not isinstance(artifact, dict):
            continue
        row = dict(artifact)
        mounted_path = str(row.get("mountedPath") or "").strip()
        if mounted_path:
            row["url"] = f"/api/mounted-files/file/?path={quote(mounted_path)}"
        artifacts.append(row)
    out["artifacts"] = artifacts
    return out


def _start_job_thread(job_id: str) -> None:
    cancel_event = threading.Event()
    _RUNNING[job_id] = cancel_event
    thread = threading.Thread(target=_run_job, args=(job_id, cancel_event), daemon=True)
    thread.start()


def _run_job(job_id: str, cancel_event: threading.Event) -> None:
    try:
        job = _update_job(job_id, status="running")
        operation = str(job.get("operation") or "sam3_precompute")
        _append_event(job, "started", f"Impact Cycle {operation} started.")
        if operation == "sam3_precompute":
            _run_metadata_generation(job_id, cancel_event)
        else:
            _run_workflow_operation(job_id, cancel_event)
    except Exception as exc:
        tb = traceback.format_exc(limit=8)
        error_str = str(exc)
        job = _update_job(job_id, status="failed", error=error_str)
        _append_event(job, "error", error_str, traceback=tb)
        _record_lm_studio_failure_if_connection(error_str, job_id)
    finally:
        _RUNNING.pop(job_id, None)


def _run_workflow_operation(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    operation = str(job.get("operation") or "").strip().lower()
    if operation == "vqa_generate":
        _run_vqa_generate(job_id, cancel_event)
    elif operation == "track_objects":
        _run_track_objects(job_id, cancel_event)
    elif operation == "cycle_verify":
        _run_cycle_verify(job_id, cancel_event)
    elif operation == "scene_graph_eval":
        _run_scene_graph_eval(job_id, cancel_event)
    elif operation == "vqa_eval":
        _run_vqa_eval(job_id, cancel_event)
    elif operation == "caption_generate":
        _run_caption_generate(job_id, cancel_event)
    elif operation == "qa_pairs_generate":
        _run_qa_pairs_generate(job_id, cancel_event)
    else:
        raise RuntimeError(f"Unsupported Impact Cycle operation: {operation}")


def _run_metadata_generation(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    video_path = Path(str((job.get("source") or {}).get("absolute_path", "")))
    run_dir = Path(str(job.get("run_dir", "")))
    frame_dir = run_dir / "frames"
    run_dir.mkdir(parents=True, exist_ok=True)
    frame_dir.mkdir(parents=True, exist_ok=True)

    cv2 = _import_required("cv2", "OpenCV is required for IMPACT_CYCLE video frame extraction.")
    np_module = _import_required("numpy", "NumPy is required by IMPACT_CYCLE.")
    _ = np_module
    repo_root = Path(__file__).resolve().parent.parent / "IMPACT_CYCLE"
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from core.impact_sg.detection_io import save_detection_record, summarize_detection_payload
    from core.impact_sg.ontology import ontology_from_payload
    from core.impact_sg.pipeline import _backend_from_cfg, _condense_category_prompt_items, _load_prompt_pack, _merge_cfg, _merge_ontology_payload, load_json, release_backend_pool
    from core.impact_sg.video_sampling import sample_frame_indices

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError("Unable to open selected video.")
    try:
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        source_fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0) or 1.0
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        settings_payload = dict(job.get("settings") or {})
        requested_sampling_fps = float(settings_payload.get("samplingFps", 1.0) or 1.0)
        sampling_fps = max(0.1, source_fps if requested_sampling_fps < 0 else requested_sampling_fps)
        max_frames = int(settings_payload.get("maxFrames", 3) or 3)
        frame_indices = sample_frame_indices(frame_count, source_fps, sampling_fps, include_last_frame=True)
        report_frame_indices = _frame_indices_from_sibling_reports(video_path, source_fps=source_fps, frame_count=frame_count)
        if report_frame_indices:
            seen_indices: set[int] = set()
            frame_indices = [idx for idx in report_frame_indices + frame_indices if not (idx in seen_indices or seen_indices.add(idx))]
        if max_frames > 0 and len(frame_indices) > max_frames:
            keep = [frame_indices[0], frame_indices[-1]]
            interior = frame_indices[1:-1]
            if max_frames > 2 and interior:
                stride = max(1, round(len(interior) / float(max_frames - 2)))
                keep.extend(interior[::stride])
            frame_indices = sorted(set(keep))[:max_frames]
        if not frame_indices and frame_count > 0:
            frame_indices = [0]
        if not frame_indices:
            raise RuntimeError("Video contains no readable frames.")

        job = _update_job(
            job_id,
            progress={"processedFrames": 0, "totalFrames": len(frame_indices), "percent": 0},
            video={**dict(job.get("video") or {}), "frameCount": frame_count, "sourceFps": source_fps, "width": width, "height": height},
        )
        _append_event(job, "sampling", f"Selected {len(frame_indices)} frame(s) for SAM3 detection precompute.", frameIndices=frame_indices)

        graphs: list[dict[str, Any]] = []
        stem = video_path.stem
        pipeline_cfg_path = repo_root / "configs" / "impact_sg_pipeline.json"
        ontology_path = repo_root / "configs" / "impact_sg_ontology.json"
        pipeline_cfg = _merge_cfg(
            load_json(str(pipeline_cfg_path)),
            {
                "backend": {
                    "provider": "external_command",
                    "external_batch_command_args_file": "configs/sam3_external_command.linux.json",
                    "external_command_args_file": "",
                    "disable_cache": False,
                },
                "proposal": {"max_category_prompts": 4},
            },
        )
        prompt_items = _build_prompt_items_for_precompute(
            repo_root=repo_root,
            video_path=video_path,
            pipeline_cfg=pipeline_cfg,
            load_json=load_json,
            load_prompt_pack=_load_prompt_pack,
            merge_ontology_payload=_merge_ontology_payload,
            condense_category_prompt_items=_condense_category_prompt_items,
            ontology_from_payload=ontology_from_payload,
            ontology_path=ontology_path,
        )
        def sam3_progress(message: str) -> None:
            _append_event(_load_job(job_id), "sam3_log", str(message))

        backend = _backend_from_cfg(pipeline_cfg, repo_root=str(repo_root), progress_cb=sam3_progress)
        output_dir = Path(str(job.get("output_dir", "")))
        output_dir.mkdir(parents=True, exist_ok=True)
        detections_dir = output_dir / "sam3_detections"
        _append_event(job, "sam3", f"SAM3 backend ready with {len(prompt_items)} prompt(s).")

        for pos, frame_idx in enumerate(frame_indices, start=1):
            if cancel_event.is_set() or str(_load_job(job_id).get("status")) == "cancelled":
                job = _update_job(job_id, status="cancelled")
                _append_event(job, "cancelled", "SAM3 detection precompute cancelled.")
                _cleanup_unfinished_job_files(job)
                return
            image_path, image_w, image_h = _extract_frame(cv2, cap, video_path, int(frame_idx), frame_dir)
            _append_event(job, "frame", f"Running SAM3 detections on frame {pos}/{len(frame_indices)}.", frameIdx=int(frame_idx))
            details = backend.discover_entities_by_category_detailed(
                str(image_path),
                prompt_items,
                score_threshold=None,
            )
            summary = summarize_detection_payload(details)
            detection_payload = {
                "stage": "sam3_detection_precompute",
                "video_id": stem,
                "frame_idx": int(frame_idx),
                "image_id": f"{stem}_f{int(frame_idx):06d}",
                "image_path": str(image_path),
                "image_size": {"width": int(image_w), "height": int(image_h)},
                "backend_provider": str((details.get("backend_config") or {}).get("provider", "")),
                "backend_config": dict(details.get("backend_config") or {}),
                "prompt_results": [dict(x) for x in list(details.get("prompt_results") or []) if isinstance(x, dict)],
                "post_threshold_records": [dict(x) for x in list(details.get("post_threshold_records") or []) if isinstance(x, dict)],
                "summary": summary,
            }
            detection_path = Path(save_detection_record(str(detections_dir), stem, int(frame_idx), detection_payload))
            graph = _detection_payload_to_graph(detection_payload, frame_idx=int(frame_idx), source_fps=source_fps, image_path=image_path, detection_path=detection_path)
            graphs.append(graph)

            percent = round(pos * 100 / max(1, len(frame_indices)))
            job = _update_job(job_id, progress={"processedFrames": pos, "totalFrames": len(frame_indices), "percent": percent})
            _write_detection_bundle(job, video_path, frame_count, source_fps, sampling_fps, frame_indices, graphs)
            _append_event(job, "frame_done", f"Frame {pos}/{len(frame_indices)} completed with {int(summary.get('post_threshold_count', 0) or 0)} detection(s).", frameIdx=int(frame_idx), percent=percent)

        _write_detection_bundle(job, video_path, frame_count, source_fps, sampling_fps, frame_indices, graphs)
        job = _update_job(job_id, status="completed", progress={"processedFrames": len(frame_indices), "totalFrames": len(frame_indices), "percent": 100})
        job = _load_job(job_id)
        _append_event(
            job,
            "completed",
            "SAM3 detection precompute completed.",
            bundleUrl=f"/api/impact-cycle/jobs/{job_id}/bundle/",
            mountedPath=str(job.get("output_path") or ""),
        )
    finally:
        cap.release()
        try:
            release_backend_pool()
        except Exception:
            pass


def _run_vqa_generate(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    repo_root = _impact_cycle_repo_root()
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from core.impact_sg.pipeline import run_generate_vqa

    bundle = _load_mounted_json(str((job.get("inputs") or {}).get("bundlePath") or ""))
    graphs = [dict(x) for x in list(bundle.get("graphs") or []) if isinstance(x, dict)]
    if not graphs:
        raise RuntimeError("Selected scene graph bundle contains no graphs.")
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    pipeline_cfg_path = repo_root / "configs" / "impact_sg_pipeline.json"
    per_graph: list[dict[str, Any]] = []
    all_items: list[dict[str, Any]] = []
    for index, graph in enumerate(graphs):
        if cancel_event.is_set():
            job = _update_job(job_id, status="cancelled")
            _append_event(job, "cancelled", "VQA generation cancelled.")
            _cleanup_unfinished_job_files(job)
            return
        payload = run_generate_vqa(graph, pipeline_cfg_path=str(pipeline_cfg_path))
        per_graph.append({"graphIndex": index, "frame_idx": graph.get("frame_idx"), "vqa": payload})
        for item in list(payload.get("all") or []):
            if isinstance(item, dict):
                row = dict(item)
                row.setdefault("graph_index", index)
                row.setdefault("frame_idx", graph.get("frame_idx"))
                all_items.append(row)
        percent = round((index + 1) * 100 / max(1, len(graphs)))
        job = _update_job(job_id, progress={"processedFrames": index + 1, "totalFrames": len(graphs), "percent": percent})
        _append_event(job, "vqa_frame", f"Generated VQA for graph {index + 1}/{len(graphs)}.", percent=percent)
    output = {
        "type": "impact_cycle_vqa_bundle",
        "source_bundle": str((job.get("inputs") or {}).get("bundlePath") or ""),
        "graph_count": len(graphs),
        "single_turn_count": sum(len((row.get("vqa") or {}).get("single_turn") or []) for row in per_graph),
        "multi_turn_count": sum(len((row.get("vqa") or {}).get("multi_turn") or []) for row in per_graph),
        "per_graph": per_graph,
        "all": all_items,
    }
    out_path = out_dir / "vqa.json"
    _write_json_atomic(out_path, output)
    _complete_workflow_job(job_id, "VQA generation completed.", [{"type": "vqa", "name": "vqa.json", "path": str(out_path)}])


def _run_track_objects(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    inputs = dict(job.get("inputs") or {})
    bundle_path = str(inputs.get("bundlePath") or "")
    video_rel = str(inputs.get("videoPath") or "")
    bundle = _load_mounted_json(bundle_path)
    graphs = [dict(x) for x in list(bundle.get("graphs") or []) if isinstance(x, dict)]
    if len(graphs) < 2:
        raise RuntimeError("Tracking requires at least two sampled scene graph frames.")
    video_path = _safe_resolve(_mounted_root(), video_rel)
    if not video_path.is_file() or video_path.suffix.lower() not in VIDEO_EXTENSIONS:
        raise RuntimeError("Mounted video file not found for tracking.")
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    frame_dir = Path(str(job.get("run_dir") or "")) / "tracking_frames"
    frame_dir.mkdir(parents=True, exist_ok=True)
    settings = dict(job.get("settings") or {})
    labels = {
        str(item or "").strip().lower()
        for item in list(settings.get("trackingLabels") or TRACKED_LABELS)
        if str(item or "").strip()
    }
    tracker_result = _build_tracking_results(
        job_id=job_id,
        cancel_event=cancel_event,
        graphs=graphs,
        video_path=video_path,
        frame_dir=frame_dir,
        labels=labels or TRACKED_LABELS,
    )
    tracker_result.update(
        {
            "type": "impact_cycle_tracking_results",
            "version": 1,
            "source_bundle": bundle_path,
            "video_path": video_rel,
            "labels": sorted(labels or TRACKED_LABELS),
        }
    )
    out_path = out_dir / "tracking_results.json"
    _write_json_atomic(out_path, tracker_result)
    _complete_workflow_job(job_id, "Object tracking completed.", [{"type": "tracking_results", "name": "tracking_results.json", "path": str(out_path)}])


def _run_cycle_verify(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    repo_root = _impact_cycle_repo_root()
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from core.impact_sg.cycle_pipeline import run_cycle_refine
    from core.impact_sg.ontology import ontology_from_payload

    inputs = dict(job.get("inputs") or {})
    bundle_path = str(inputs.get("bundlePath") or "")
    video_rel = str(inputs.get("videoPath") or "")
    bundle = _load_mounted_json(bundle_path)
    graphs = [dict(x) for x in list(bundle.get("graphs") or []) if isinstance(x, dict)]
    if not graphs:
        raise RuntimeError("Selected scene graph bundle contains no graphs.")
    settings_payload = dict(job.get("settings") or {})
    max_frames = int(settings_payload.get("maxFrames", 0) or 0)
    if max_frames > 0:
        graphs = graphs[:max_frames]
    rounds = max(1, int(settings_payload.get("rounds", 1) or 1))
    cycle_cfg = _litellm_cycle_cfg(repo_root, rounds=rounds, low_quota=bool(settings_payload.get("lowQuota", True)))
    ontology = ontology_from_payload(_read_json_file(repo_root / "configs" / "impact_sg_ontology.json"))
    verifier = _LiteLLMTextVisionVerifier(progress_cb=lambda msg: _append_event(_load_job(job_id), "litellm", msg))
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    tracking_path = out_dir / "tracking_results.json"
    if not tracking_path.is_file() and bundle_path:
        bundle_tracking_path = _safe_resolve(_mounted_root(), (Path(bundle_path).parent / "tracking_results.json").as_posix())
        if bundle_tracking_path.is_file():
            tracking_path = bundle_tracking_path
    if tracking_path.is_file():
        _inject_tracking_contexts(graphs, tracking_path)
        _append_event(job, "tracking", "Loaded tracking_results.json for temporal consistency probes.")
    else:
        _append_event(job, "tracking", "No tracking_results.json found; temporal consistency probes will be skipped.")
    frame_dir = Path(str(job.get("run_dir") or "")) / "cycle_frames"
    frame_dir.mkdir(parents=True, exist_ok=True)
    video_path = _safe_resolve(_mounted_root(), video_rel) if video_rel else None
    results: list[dict[str, Any]] = []
    for index, graph in enumerate(graphs):
        if cancel_event.is_set():
            job = _update_job(job_id, status="cancelled")
            _append_event(job, "cancelled", "Cycle verification cancelled.")
            _cleanup_unfinished_job_files(job)
            return
        image_path = _resolve_graph_image_path(graph, video_path=video_path, frame_dir=frame_dir)
        if not image_path:
            results.append({"graph_idx": index, "frame_idx": graph.get("frame_idx"), "error": "image_not_found"})
        else:
            result = run_cycle_refine(graph=graph, image_path=image_path, verifier=verifier, ontology=ontology, cfg=cycle_cfg)
            results.append(_sanitize_cycle_result(index, graph, result))
        percent = round((index + 1) * 100 / max(1, len(graphs)))
        job = _update_job(job_id, progress={"processedFrames": index + 1, "totalFrames": len(graphs), "percent": percent})
        _append_event(job, "cycle_frame", f"Cycle verified graph {index + 1}/{len(graphs)}.", percent=percent)
    output = {
        "type": "impact_cycle_cycle_results",
        "source_bundle": bundle_path,
        "provider": "litellm_lm_studio",
        "model": "google/gemma-4-31b",
        "rounds": rounds,
        "frames_attempted": len(graphs),
        "frames_succeeded": sum(1 for row in results if "error" not in row),
        "results": results,
    }
    out_path = out_dir / "cycle_results.json"
    _write_json_atomic(out_path, output)
    _complete_workflow_job(job_id, "Cycle verification completed.", [{"type": "cycle_results", "name": "cycle_results.json", "path": str(out_path)}])


def _run_scene_graph_eval(job_id: str, cancel_event: threading.Event) -> None:
    _ = cancel_event
    job = _load_job(job_id)
    repo_root = _impact_cycle_repo_root()
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from core.impact_sg.eval_scene_graph import evaluate_scene_graph

    inputs = dict(job.get("inputs") or {})
    pred = _load_mounted_json(str(inputs.get("predPath") or ""))
    gt = _load_mounted_json(str(inputs.get("gtPath") or ""))
    iou = float((job.get("settings") or {}).get("iouThreshold", 0.5) or 0.5)
    metrics = _evaluate_graph_payloads(pred, gt, evaluate_scene_graph, iou)
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "scene_graph_eval.json"
    _write_json_atomic(out_path, {"type": "impact_cycle_scene_graph_eval", "metrics": metrics})
    _update_job(job_id, progress={"processedFrames": 1, "totalFrames": 1, "percent": 100})
    _complete_workflow_job(job_id, "Scene graph evaluation completed.", [{"type": "scene_graph_eval", "name": "scene_graph_eval.json", "path": str(out_path)}])


def _run_vqa_eval(job_id: str, cancel_event: threading.Event) -> None:
    _ = cancel_event
    job = _load_job(job_id)
    repo_root = _impact_cycle_repo_root()
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))
    from core.impact_sg.eval_vqa import evaluate_vqa

    inputs = dict(job.get("inputs") or {})
    pred = _flatten_vqa_payload(_load_mounted_json(str(inputs.get("predPath") or "")))
    gt = _flatten_vqa_payload(_load_mounted_json(str(inputs.get("gtPath") or "")))
    metrics = evaluate_vqa(pred, gt)
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "vqa_eval.json"
    _write_json_atomic(out_path, {"type": "impact_cycle_vqa_eval", "metrics": metrics})
    _update_job(job_id, progress={"processedFrames": 1, "totalFrames": 1, "percent": 100})
    _complete_workflow_job(job_id, "VQA evaluation completed.", [{"type": "vqa_eval", "name": "vqa_eval.json", "path": str(out_path)}])


def _run_caption_generate(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    inputs = dict(job.get("inputs") or {})
    settings_payload = dict(job.get("settings") or {})
    video_rel = str(inputs.get("videoPath") or "").strip()
    video_path = _safe_resolve(_mounted_root(), video_rel)
    if not video_path.is_file() or video_path.suffix.lower() not in VIDEO_EXTENSIONS:
        raise RuntimeError("Mounted video file not found for caption generation.")

    lm_studio_url = str(settings_payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip()
    model_name = str(settings_payload.get("model") or "google/gemma-4-31b").strip()
    if not model_name.startswith("openai/"):
        litellm_model = f"openai/{model_name}"
    else:
        litellm_model = model_name
    fps_sampling = max(1, int(settings_payload.get("fpsSampling", 3) or 3))
    caption_prompt = str(settings_payload.get("captionPrompt") or "").strip()
    if not caption_prompt:
        raise RuntimeError("Caption prompt is required.")

    cv2 = _import_required("cv2", "OpenCV is required for caption generation.")
    litellm = _import_required("litellm", "LiteLLM is required for LM Studio caption calls.")

    run_dir = Path(str(job.get("run_dir") or ""))
    frame_dir = run_dir / "caption_frames"
    run_dir.mkdir(parents=True, exist_ok=True)
    frame_dir.mkdir(parents=True, exist_ok=True)
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError("Unable to open selected video for caption generation.")
    try:
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        source_fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0) or 1.0
        frame_indices = list(range(0, max(1, frame_count), fps_sampling))
        total = len(frame_indices)
        out_path = out_dir / "captions.json"
        job = _update_job(
            job_id,
            progress={"processedFrames": 0, "totalFrames": total, "percent": 0},
            video={**dict(job.get("video") or {}), "name": video_path.name, "frameCount": frame_count, "sourceFps": source_fps},
        )
        _append_event(job, "sampling", f"Selected {total} frame(s) for caption generation (every {fps_sampling} frame).")

        captions, resumed = _load_resumable_caption_rows(
            out_path,
            video_name=video_path.name,
            video_rel=video_rel,
            frame_count=frame_count,
            source_fps=source_fps,
            fps_sampling=fps_sampling,
            model_name=model_name,
            lm_studio_url=lm_studio_url,
            frame_indices=frame_indices,
        )
        captioned_frames = {int(row.get("frame_index")) for row in captions}
        if resumed and captions:
            percent = round(len(captions) * 100 / max(1, total))
            job = _update_job(job_id, progress={"processedFrames": len(captions), "totalFrames": total, "percent": percent})
            _append_event(job, "caption_resume", f"Resuming caption generation with {len(captions)}/{total} saved caption(s).")
        _write_json_atomic(
            out_path,
            _caption_output_payload(
                video_name=video_path.name,
                video_rel=video_rel,
                frame_count=frame_count,
                source_fps=source_fps,
                fps_sampling=fps_sampling,
                model_name=model_name,
                lm_studio_url=lm_studio_url,
                captions=captions,
            ),
        )
        for pos, frame_idx in enumerate(frame_indices, start=1):
            if cancel_event.is_set() or str(_load_job(job_id).get("status")) == "cancelled":
                job = _update_job(job_id, status="cancelled")
                _append_event(job, "cancelled", "Caption generation cancelled.")
                _cleanup_unfinished_job_files(job)
                return
            if int(frame_idx) in captioned_frames:
                continue

            image_path, _, _ = _extract_frame(cv2, cap, video_path, int(frame_idx), frame_dir)
            with open(str(image_path), "rb") as f:
                image_b64 = base64.b64encode(f.read()).decode("ascii")

            _append_event(job, "caption_frame", f"Generating caption for frame {pos}/{total} (frame index {int(frame_idx)}).")
            try:
                response = None
                for attempt in range(1, CAPTION_TIMEOUT_ATTEMPTS + 1):
                    if cancel_event.is_set() or str(_load_job(job_id).get("status")) == "cancelled":
                        job = _update_job(job_id, status="cancelled")
                        _append_event(job, "cancelled", "Caption generation cancelled.")
                        _cleanup_unfinished_job_files(job)
                        return
                    try:
                        response = litellm.completion(
                            model=litellm_model,
                            api_base=lm_studio_url,
                            api_key="lm-studio",
                            messages=[
                                {
                                    "role": "user",
                                    "content": [
                                        {"type": "text", "text": caption_prompt},
                                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                                    ],
                                }
                            ],
                            temperature=0,
                            max_tokens=CAPTION_MAX_TOKENS,
                            timeout=CAPTION_REQUEST_TIMEOUT_SEC,
                        )
                        break
                    except Exception as attempt_exc:
                        if not _is_timeout_error(attempt_exc) or attempt >= CAPTION_TIMEOUT_ATTEMPTS:
                            raise
                        error_str = str(attempt_exc)
                        _append_event(
                            job,
                            "caption_retry",
                            f"LM Studio timeout on frame {pos}/{total}; retrying attempt {attempt + 1}/{CAPTION_TIMEOUT_ATTEMPTS}: {error_str[:200]}",
                            frameIdx=int(frame_idx),
                            attempt=attempt + 1,
                        )
                if response is None:
                    raise RuntimeError("LM Studio returned no response.")
                caption_text = _caption_completion_text(response)
                if not caption_text:
                    details = _litellm_empty_completion_details(response)
                    raise RuntimeError(
                        "LM Studio returned an empty caption completion "
                        f"({details}). Increase the token budget or disable reasoning for the selected model."
                    )
            except Exception as exc:
                error_str = str(exc)
                _append_event(job, "caption_error", f"LM Studio error on frame {pos}/{total}: {error_str[:200]}")
                _record_lm_studio_failure_if_connection(error_str, job_id)
                raise RuntimeError(f"LM Studio call failed on frame {pos}/{total}: {error_str}") from exc

            timestamp_ms = round(int(frame_idx) * 1000.0 / source_fps)
            captions.append({
                "frame_index": int(frame_idx),
                "timestamp_ms": timestamp_ms,
                "timestamp": _format_caption_timestamp(timestamp_ms),
                "caption": caption_text,
            })
            captioned_frames.add(int(frame_idx))
            captions.sort(key=lambda row: int(row.get("frame_index") or 0))
            _write_json_atomic(
                out_path,
                _caption_output_payload(
                    video_name=video_path.name,
                    video_rel=video_rel,
                    frame_count=frame_count,
                    source_fps=source_fps,
                    fps_sampling=fps_sampling,
                    model_name=model_name,
                    lm_studio_url=lm_studio_url,
                    captions=captions,
                ),
            )

            percent = round(len(captions) * 100 / max(1, total))
            job = _update_job(job_id, progress={"processedFrames": len(captions), "totalFrames": total, "percent": percent})
            _append_event(job, "caption_done", f"Caption {pos}/{total} completed.", frameIdx=int(frame_idx), percent=percent)

        _write_json_atomic(
            out_path,
            _caption_output_payload(
                video_name=video_path.name,
                video_rel=video_rel,
                frame_count=frame_count,
                source_fps=source_fps,
                fps_sampling=fps_sampling,
                model_name=model_name,
                lm_studio_url=lm_studio_url,
                captions=captions,
            ),
        )
        _complete_workflow_job(job_id, "Caption generation completed.", [{"type": "captions", "name": "captions.json", "path": str(out_path)}])
    finally:
        cap.release()


def _run_qa_pairs_generate(job_id: str, cancel_event: threading.Event) -> None:
    job = _load_job(job_id)
    inputs = dict(job.get("inputs") or {})
    settings_payload = dict(job.get("settings") or {})
    video_rel = str(inputs.get("videoPath") or "").strip()
    video_path = _safe_resolve(_mounted_root(), video_rel)
    if not video_path.is_file() or video_path.suffix.lower() not in VIDEO_EXTENSIONS:
        raise RuntimeError("Mounted video file not found for QA-pair generation.")

    lm_studio_url = str(settings_payload.get("lmStudioUrl") or "http://host.docker.internal:1234/v1").strip()
    model_name = str(settings_payload.get("model") or "google/gemma-4-31b").strip()
    litellm_model = model_name if model_name.startswith("openai/") else f"openai/{model_name}"
    fps_sampling = max(1, int(settings_payload.get("fpsSampling", 3) or 3))
    window_size = max(1, int(settings_payload.get("windowSizeSeconds", 25) or 25))
    qa_pairs_per_window = max(1, int(settings_payload.get("qaPairsPerWindow", 10) or 10))
    skip_invalid_qa_pairs = bool(settings_payload.get("skipInvalidQaPairs", False))
    qa_prompt = str(settings_payload.get("qaGenerationPrompt") or "").strip()
    if not qa_prompt:
        raise RuntimeError("QA generation prompt is required.")

    cv2 = _import_required("cv2", "OpenCV is required for QA-pair generation.")
    litellm = _import_required("litellm", "LiteLLM is required for LM Studio QA-pair calls.")

    run_dir = Path(str(job.get("run_dir") or ""))
    frame_dir = run_dir / "qa_pair_frames"
    run_dir.mkdir(parents=True, exist_ok=True)
    frame_dir.mkdir(parents=True, exist_ok=True)
    out_dir = Path(str(job.get("output_dir") or ""))
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "qa_pairs.json"
    log_path = out_dir / "qa_pairs_generation.log.jsonl"

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError("Unable to open selected video for QA-pair generation.")
    try:
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        source_fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0) or 1.0
        duration_seconds = frame_count / source_fps if frame_count > 0 else 0.0
        total_windows = max(1, math.ceil(duration_seconds / float(window_size)))
        existing_payload = _load_or_create_qa_pairs_payload(out_path, video_path, video_rel)
        qa_pairs = [dict(item) for item in list(existing_payload.get("qa_pairs") or []) if isinstance(item, dict)]
        next_qa_pair_id = _next_qa_pair_id(qa_pairs)
        job = _update_job(
            job_id,
            progress={"processedFrames": 0, "totalFrames": total_windows, "percent": 0},
            video={**dict(job.get("video") or {}), "name": video_path.name, "frameCount": frame_count, "sourceFps": source_fps},
        )
        _append_event(job, "qa_start", f"Generating QA pairs for {total_windows} window(s) of {video_path.name}.")

        for window_index in range(total_windows):
            if cancel_event.is_set() or str(_load_job(job_id).get("status")) == "cancelled":
                job = _update_job(job_id, status="cancelled")
                _append_event(job, "cancelled", "QA-pair generation cancelled.")
                _cleanup_unfinished_job_files(job)
                return
            start_seconds = float(window_index * window_size)
            end_seconds = min(float((window_index + 1) * window_size), max(duration_seconds, start_seconds + window_size))
            frame_indices = _qa_window_frame_indices(source_fps, frame_count, start_seconds, end_seconds, fps_sampling)
            if not frame_indices:
                frame_indices = [min(max(0, frame_count - 1), int(start_seconds * source_fps))]
            frame_paths = [_extract_frame(cv2, cap, video_path, frame_idx, frame_dir)[0] for frame_idx in frame_indices]

            sequence_index = max(0, next_qa_pair_id - 1)
            expected_families = [QA_CORE_FAMILIES[(sequence_index + offset) % len(QA_CORE_FAMILIES)] for offset in range(qa_pairs_per_window)]
            expected_formats = [QA_ALLOWED_ANSWER_FORMATS[(sequence_index + offset) % len(QA_ALLOWED_ANSWER_FORMATS)] for offset in range(qa_pairs_per_window)]
            retry_feedback = ""
            generated: list[tuple[int, dict[str, Any]]] | None = None
            last_error = ""
            max_attempts = 1 if skip_invalid_qa_pairs else QA_PAIR_RETRY_ATTEMPTS
            for attempt in range(1, max_attempts + 1):
                prompt = _qa_pairs_prompt(
                    base_prompt=qa_prompt,
                    video_rel=video_rel,
                    video_name=video_path.name,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    frame_indices=frame_indices,
                    qa_pairs_per_window=qa_pairs_per_window,
                    expected_families=expected_families,
                    expected_formats=expected_formats,
                    previous_pairs=qa_pairs[-10:],
                    retry_feedback=retry_feedback,
                )
                _append_event(job, "qa_window", f"Requesting QA pairs for window {window_index + 1}/{total_windows}, attempt {attempt}/{max_attempts}.")
                _append_qa_generation_log(
                    log_path,
                    event="attempt",
                    job_id=job_id,
                    video_rel=video_rel,
                    window_index=window_index,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    attempt=attempt,
                    message=f"Requesting QA pairs for window {window_index + 1}/{total_windows}.",
                )
                try:
                    response = litellm.completion(
                        model=litellm_model,
                        api_base=lm_studio_url,
                        api_key="lm-studio",
                        messages=[{"role": "user", "content": _qa_prompt_content(prompt, frame_paths)}],
                        temperature=0,
                        max_tokens=CAPTION_MAX_TOKENS,
                        timeout=CAPTION_REQUEST_TIMEOUT_SEC,
                    )
                    raw_text = _caption_completion_text(response)
                    if not raw_text:
                        raise RuntimeError(f"LM Studio returned an empty QA completion ({_litellm_empty_completion_details(response)}).")
                    payload = _parse_qa_pairs_completion(raw_text)
                    candidate_pairs = _extract_qa_pair_list(payload)
                    if skip_invalid_qa_pairs:
                        generated = _valid_generated_qa_pairs(
                            candidate_pairs,
                            expected_families=expected_families,
                            expected_formats=expected_formats,
                            start_seconds=start_seconds,
                            end_seconds=end_seconds,
                            log_path=log_path,
                            job_id=job_id,
                            video_rel=video_rel,
                            window_index=window_index,
                            attempt=attempt,
                        )
                    else:
                        _validate_generated_qa_pairs(
                            candidate_pairs,
                            qa_pairs_per_window=qa_pairs_per_window,
                            expected_families=expected_families,
                            expected_formats=expected_formats,
                            start_seconds=start_seconds,
                            end_seconds=end_seconds,
                        )
                        generated = list(enumerate(candidate_pairs))
                    break
                except Exception as exc:
                    last_error = str(exc)
                    retry_feedback = f"Previous response was invalid: {last_error}. Fix this exactly and return only valid JSON."
                    retry_event = "qa_skipped" if skip_invalid_qa_pairs else "qa_retry"
                    retry_message = "QA response could not be parsed" if skip_invalid_qa_pairs else "QA validation failed"
                    _append_event(job, retry_event, f"{retry_message} for window {window_index + 1}/{total_windows}: {last_error[:300]}", attempt=attempt)
                    _append_qa_generation_log(
                        log_path,
                        event="skipped_window" if skip_invalid_qa_pairs else "retry",
                        job_id=job_id,
                        video_rel=video_rel,
                        window_index=window_index,
                        start_seconds=start_seconds,
                        end_seconds=end_seconds,
                        attempt=attempt,
                        message=f"{retry_message} for window {window_index + 1}/{total_windows}.",
                        error=last_error,
                    )
                    _record_lm_studio_failure_if_connection(last_error, job_id)
            if generated is None:
                if skip_invalid_qa_pairs:
                    percent = round((window_index + 1) * 100 / max(1, total_windows))
                    job = _update_job(job_id, progress={"processedFrames": window_index + 1, "totalFrames": total_windows, "percent": percent})
                    _append_event(job, "qa_window_done", f"Skipped QA pairs for window {window_index + 1}/{total_windows} because the response was invalid.", percent=percent)
                    continue
                _append_qa_generation_log(
                    log_path,
                    event="failed",
                    job_id=job_id,
                    video_rel=video_rel,
                    window_index=window_index,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    message=f"QA-pair generation failed for window {window_index + 1}/{total_windows} after {QA_PAIR_RETRY_ATTEMPTS} attempts.",
                    error=last_error,
                )
                raise RuntimeError(f"QA-pair generation failed for window {window_index + 1}/{total_windows} after {QA_PAIR_RETRY_ATTEMPTS} attempts: {last_error}")

            generated_count = 0
            for offset, item in generated:
                normalized = _normalize_generated_qa_pair(
                    item,
                    video_id=video_path.stem,
                    qa_pair_id=str(next_qa_pair_id),
                    expected_family=expected_families[offset],
                    expected_format=expected_formats[offset],
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    start_frame=frame_indices[0],
                    end_frame=frame_indices[-1],
                )
                next_qa_pair_id += 1
                generated_count += 1
                qa_pairs.append(normalized)
                _append_qa_generation_log(
                    log_path,
                    event="generated",
                    job_id=job_id,
                    video_rel=video_rel,
                    window_index=window_index,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    qa_pair=normalized,
                )
            _write_json_atomic(out_path, _qa_pairs_output_payload(existing_payload, video_path, video_rel, qa_pairs))
            percent = round((window_index + 1) * 100 / max(1, total_windows))
            job = _update_job(job_id, progress={"processedFrames": window_index + 1, "totalFrames": total_windows, "percent": percent})
            _append_event(job, "qa_window_done", f"Generated {generated_count} QA pair(s) for window {window_index + 1}/{total_windows}.", percent=percent)

        _complete_workflow_job(job_id, "QA-pair generation completed.", [{"type": "qa_pairs", "name": "qa_pairs.json", "path": str(out_path)}])
    finally:
        cap.release()


def _qa_window_frame_indices(source_fps: float, frame_count: int, start_seconds: float, end_seconds: float, fps_sampling: int) -> list[int]:
    if frame_count <= 0:
        return []
    start = max(0, int(start_seconds * source_fps))
    end = min(frame_count - 1, max(start, int(end_seconds * source_fps)))
    return list(range(start, end + 1, max(1, fps_sampling)))


def _qa_prompt_content(prompt: str, frame_paths: list[Path]) -> list[dict[str, Any]]:
    content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
    for path in frame_paths:
        with path.open("rb") as handle:
            image_b64 = base64.b64encode(handle.read()).decode("ascii")
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}})
    return content


def _qa_pairs_prompt(
    *,
    base_prompt: str,
    video_rel: str,
    video_name: str,
    start_seconds: float,
    end_seconds: float,
    frame_indices: list[int],
    qa_pairs_per_window: int,
    expected_families: list[str],
    expected_formats: list[str],
    previous_pairs: list[dict[str, Any]],
    retry_feedback: str,
) -> str:
    return (
        f"{base_prompt}\n\n"
        "You are creating benchmark QA pairs for highly shaky first-person running videos, as described in Practical course topic.md: "
        "the benchmark evaluates MLLMs on unstable ego-motion-heavy videos with rapid viewpoint changes, blur, occlusion, day/night variation, "
        "temporal grounding, trajectory/location awareness, object/event understanding, and robustness.\n\n"
        f"Video: {video_name} ({video_rel})\n"
        f"Window: {start_seconds:.3f}s to {end_seconds:.3f}s\n"
        f"Sampled frame indices: {json.dumps(frame_indices)}\n"
        f"Return exactly {qa_pairs_per_window} QA pairs.\n"
        f"Family sequence for this window, in order: {json.dumps(expected_families)}\n"
        f"Answer format sequence for this window, in order: {json.dumps(expected_formats)}\n\n"
        "Use only these five core QA families, represented by these schema family values: "
        "object_attribute, action_event, temporal_reasoning, trajectory_grounded, day_night_robustness. "
        "They correspond to Object/attribute, Action/event, Temporal reasoning, Trajectory/location-aware, and Robustness.\n"
        "Use only answer_formats multiple_choice, yes_no, numeric in the exact sequential order provided. Never generate open-ended questions.\n"
        "For multiple_choice, provide a non-empty choices list and set answer to one correct choice exactly from choices.\n"
        "For yes_no, set answer to true or false. For numeric, set answer to a number.\n"
        "Always set a valid, correct answer based on evidence from the provided visual frames/captions. Do not hallucinate.\n"
        "Each new QA pair must relate to different aspects of the video scenery than the last QA pairs and must not be too similar.\n"
        "Cover a rich variety of difficulties, families, and reasoning types according to doc/qa_pairs/README.md.\n"
        "Use evidence_spans inside this window. Include start_seconds, end_seconds, start_frame, end_frame, and description.\n"
        "Return one JSON object and no markdown with this exact shape: {\"qa_pairs\": [ ... ]}.\n"
        "Each QA pair must contain: id, video_id, question, answer, answer_format, family, reasoning_types, difficulty, visibility, day_night, "
        "evidence_spans, trajectory_linkage, choices, answer_aliases, unanswerable. Set unanswerable to false.\n"
        f"Previous QA pairs to avoid repeating: {json.dumps(previous_pairs, ensure_ascii=True)[:6000]}\n"
        f"{retry_feedback}"
    )


def _parse_qa_pairs_completion(raw_text: str) -> dict[str, Any]:
    text = raw_text.strip()
    try:
        payload = json.loads(text)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, flags=re.S)
    if not match:
        raise RuntimeError("LLM response did not contain a JSON object.")
    payload = json.loads(match.group(0))
    if not isinstance(payload, dict):
        raise RuntimeError("LLM JSON response must be an object.")
    return payload


def _extract_qa_pair_list(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw = payload.get("qa_pairs")
    if not isinstance(raw, list):
        raise RuntimeError("LLM JSON must contain a qa_pairs list.")
    return [dict(item) for item in raw if isinstance(item, dict)]


def _validate_generated_qa_pairs(
    pairs: list[dict[str, Any]],
    *,
    qa_pairs_per_window: int,
    expected_families: list[str],
    expected_formats: list[str],
    start_seconds: float,
    end_seconds: float,
) -> None:
    if len(pairs) != qa_pairs_per_window:
        raise RuntimeError(f"Expected exactly {qa_pairs_per_window} qa_pairs, got {len(pairs)}.")
    questions: set[str] = set()
    for index, item in enumerate(pairs):
        _validate_generated_qa_pair(
            item,
            index=index,
            questions=questions,
            expected_family=expected_families[index],
            expected_format=expected_formats[index],
            start_seconds=start_seconds,
            end_seconds=end_seconds,
        )


def _valid_generated_qa_pairs(
    pairs: list[dict[str, Any]],
    *,
    expected_families: list[str],
    expected_formats: list[str],
    start_seconds: float,
    end_seconds: float,
    log_path: Path,
    job_id: str,
    video_rel: str,
    window_index: int,
    attempt: int,
) -> list[tuple[int, dict[str, Any]]]:
    valid: list[tuple[int, dict[str, Any]]] = []
    questions: set[str] = set()
    for index, item in enumerate(pairs):
        try:
            if index >= len(expected_families) or index >= len(expected_formats):
                raise RuntimeError(f"QA pair {index + 1} was not requested for this window.")
            _validate_generated_qa_pair(
                item,
                index=index,
                questions=questions,
                expected_family=expected_families[index],
                expected_format=expected_formats[index],
                start_seconds=start_seconds,
                end_seconds=end_seconds,
            )
        except Exception as exc:
            _append_qa_generation_log(
                log_path,
                event="skipped",
                job_id=job_id,
                video_rel=video_rel,
                window_index=window_index,
                start_seconds=start_seconds,
                end_seconds=end_seconds,
                attempt=attempt,
                message=f"Skipped invalid QA pair {index + 1}.",
                error=str(exc),
            )
            continue
        valid.append((index, item))
    return valid


def _validate_generated_qa_pair(
    item: dict[str, Any],
    *,
    index: int,
    questions: set[str],
    expected_family: str,
    expected_format: str,
    start_seconds: float,
    end_seconds: float,
) -> None:
    question = str(item.get("question") or "").strip()
    if not question:
        raise RuntimeError(f"QA pair {index + 1} is missing a question.")
    question_key = question.lower()
    if question_key in questions:
        raise RuntimeError(f"QA pair {index + 1} repeats a question in the same window.")
    family = str(item.get("family") or "").strip()
    if family != expected_family:
        raise RuntimeError(f"QA pair {index + 1} has family {family!r}, expected {expected_family!r}.")
    answer_format = str(item.get("answer_format") or "").strip()
    if answer_format != expected_format:
        raise RuntimeError(f"QA pair {index + 1} has answer_format {answer_format!r}, expected {expected_format!r}.")
    if answer_format == "multiple_choice":
        choices = list(item.get("choices") or [])
        if not choices or not all(isinstance(choice, str) and choice.strip() for choice in choices):
            raise RuntimeError(f"QA pair {index + 1} multiple_choice requires non-empty string choices.")
        if _matching_multiple_choice_answer_index(item.get("answer"), choices) is None:
            raise RuntimeError(f"QA pair {index + 1} multiple_choice answer must be one of choices.")
    elif answer_format == "yes_no":
        if not isinstance(item.get("answer"), bool):
            raise RuntimeError(f"QA pair {index + 1} yes_no answer must be boolean.")
    elif answer_format == "numeric":
        if not isinstance(item.get("answer"), (int, float)) or isinstance(item.get("answer"), bool):
            raise RuntimeError(f"QA pair {index + 1} numeric answer must be a number.")
    else:
        raise RuntimeError(f"QA pair {index + 1} uses unsupported answer_format {answer_format!r}.")
    spans = list(item.get("evidence_spans") or [])
    if not spans or not all(isinstance(span, dict) for span in spans):
        raise RuntimeError(f"QA pair {index + 1} requires evidence_spans.")
    for span in spans:
        span_start = float(span.get("start_seconds") or 0)
        span_end = float(span.get("end_seconds") if span.get("end_seconds") is not None else span_start)
        if span_start < start_seconds - 0.001 or span_end > end_seconds + 0.001 or span_end < span_start:
            raise RuntimeError(f"QA pair {index + 1} evidence span must stay inside the current window.")
    if bool(item.get("unanswerable", False)):
        raise RuntimeError(f"QA pair {index + 1} must be answerable with a valid answer.")
    questions.add(question_key)


def _normalize_generated_qa_pair(
    item: dict[str, Any],
    *,
    video_id: str,
    qa_pair_id: str,
    expected_family: str,
    expected_format: str,
    start_seconds: float,
    end_seconds: float,
    start_frame: int,
    end_frame: int,
) -> dict[str, Any]:
    spans = []
    for span in list(item.get("evidence_spans") or []):
        if not isinstance(span, dict):
            continue
        spans.append({
            "start_seconds": start_seconds,
            "end_seconds": end_seconds,
            "start_frame": span.get("start_frame") if span.get("start_frame") is not None else start_frame,
            "end_frame": span.get("end_frame") if span.get("end_frame") is not None else end_frame,
            "description": str(span.get("description") or "Evidence from the sampled window."),
        })
    if not spans:
        spans = [{"start_seconds": start_seconds, "end_seconds": end_seconds, "start_frame": start_frame, "end_frame": end_frame, "description": "Evidence from the sampled window."}]
    answer = item.get("answer")
    choices = [str(choice) for choice in list(item.get("choices") or [])]
    answer_aliases = [str(alias) for alias in list(item.get("answer_aliases") or [])]
    if expected_format == "multiple_choice":
        match_index = _matching_multiple_choice_answer_index(answer, choices)
        if match_index is not None:
            answer = choices[match_index]
            if answer not in answer_aliases:
                answer_aliases.append(answer)
    return {
        "id": qa_pair_id,
        "video_id": _qa_video_id_without_mov_suffix(video_id),
        "question": str(item.get("question") or "").strip(),
        "answer": answer,
        "answer_format": expected_format,
        "family": expected_family,
        "reasoning_types": _valid_reasoning_types(list(item.get("reasoning_types") or []), expected_family),
        "difficulty": str(item.get("difficulty") if item.get("difficulty") in {"easy", "medium", "hard"} else "medium"),
        "visibility": str(item.get("visibility") if item.get("visibility") in {"clear", "blurred", "occluded", "dark", "glare", "mixed"} else "mixed"),
        "day_night": str(item.get("day_night") if item.get("day_night") in {"day", "night", "mixed", "unknown"} else "unknown"),
        "evidence_spans": spans,
        "trajectory_linkage": item.get("trajectory_linkage") if isinstance(item.get("trajectory_linkage"), dict) else None,
        "choices": choices,
        "answer_aliases": answer_aliases,
        "unanswerable": False,
    }


def _matching_multiple_choice_answer_index(answer: Any, choices: list[Any]) -> int | None:
    if isinstance(answer, int) and not isinstance(answer, bool) and 1 <= answer <= len(choices):
        return answer - 1
    answer_text = _normalize_multiple_choice_text(answer)
    if not answer_text:
        return None
    if answer_text.isdigit():
        index = int(answer_text)
        if 1 <= index <= len(choices):
            return index - 1
    letter_match = re.fullmatch(r"(?:choice|option|answer)?\s*([a-e])", answer_text)
    if letter_match:
        index = ord(letter_match.group(1)) - ord("a")
        if 0 <= index < len(choices):
            return index
    for index, choice in enumerate(choices):
        choice_text = _normalize_multiple_choice_text(choice)
        if answer_text == choice_text:
            return index
    for index, choice in enumerate(choices):
        choice_text = _normalize_multiple_choice_text(choice)
        if choice_text and (answer_text in choice_text or choice_text in answer_text):
            return index
    return None


def _qa_video_id_without_mov_suffix(video_id: str) -> str:
    clean = str(video_id or "").strip()
    if clean.lower().endswith(".mov"):
        return clean[:-4]
    return clean


def _normalize_multiple_choice_text(value: Any) -> str:
    text = str(value if value is not None else "").strip().lower()
    text = re.sub(r"^\s*(?:choice|option|answer)?\s*[a-e1-5][\).:-]\s*", "", text)
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _valid_reasoning_types(values: list[Any], family: str) -> list[str]:
    allowed = {"perception", "action_recognition", "temporal_ordering", "event_localization", "spatial_relation", "scene_understanding", "trajectory_alignment", "counting", "absence_detection", "ambiguity_handling"}
    out = [str(value) for value in values if str(value) in allowed]
    if out:
        return out
    defaults = {
        "object_attribute": ["perception"],
        "action_event": ["action_recognition"],
        "temporal_reasoning": ["temporal_ordering"],
        "trajectory_grounded": ["trajectory_alignment"],
        "day_night_robustness": ["ambiguity_handling"],
    }
    return defaults.get(family, ["perception"])


def _load_or_create_qa_pairs_payload(out_path: Path, video_path: Path, video_rel: str) -> dict[str, Any]:
    if out_path.is_file():
        try:
            payload = _read_json_file(out_path)
            if isinstance(payload.get("qa_pairs"), list):
                return payload
        except Exception:
            pass
    return {"name": video_path.stem, "version": "1.0", "description": "Annotations created in Video Bench", "video_path": video_rel, "qa_pairs": []}


def _qa_pairs_output_payload(existing_payload: dict[str, Any], video_path: Path, video_rel: str, qa_pairs: list[dict[str, Any]]) -> dict[str, Any]:
    payload = dict(existing_payload)
    payload.setdefault("name", video_path.stem)
    payload.setdefault("version", "1.0")
    payload.setdefault("description", "Annotations created in Video Bench")
    payload["video_path"] = video_rel
    payload["qa_pairs"] = qa_pairs
    return payload


def _next_qa_pair_id(qa_pairs: list[dict[str, Any]]) -> int:
    max_index = 0
    for item in qa_pairs:
        qa_id = str(item.get("id") or "")
        match = re.search(r"(?:^|_)qa_(\d+)$", qa_id)
        if match:
            max_index = max(max_index, int(match.group(1)))
            continue
        match = re.search(r"(\d+)$", qa_id)
        if match:
            max_index = max(max_index, int(match.group(1)))
    return max_index + 1


def _append_qa_generation_log(
    log_path: Path,
    *,
    event: str,
    job_id: str,
    video_rel: str,
    window_index: int,
    start_seconds: float,
    end_seconds: float,
    attempt: int | None = None,
    message: str = "",
    error: str = "",
    qa_pair: dict[str, Any] | None = None,
) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": _now_iso(),
        "event": event,
        "job_id": job_id,
        "video_path": video_rel,
        "window_index": window_index,
        "start_seconds": start_seconds,
        "end_seconds": end_seconds,
    }
    if attempt is not None:
        row["attempt"] = attempt
    if message:
        row["message"] = message
    if error:
        row["error"] = error
    if qa_pair is not None:
        row.update({
            "qa_pair_id": str(qa_pair.get("id") or ""),
            "question": str(qa_pair.get("question") or ""),
            "answer_format": str(qa_pair.get("answer_format") or ""),
            "family": str(qa_pair.get("family") or ""),
        })
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=True))
        handle.write("\n")


def _format_caption_timestamp(timestamp_ms: int) -> str:
    total_seconds = timestamp_ms / 1000.0
    hours = int(total_seconds // 3600)
    minutes = int((total_seconds % 3600) // 60)
    seconds = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:06.3f}"


def _build_tracking_results(
    *,
    job_id: str,
    cancel_event: threading.Event,
    graphs: list[dict[str, Any]],
    video_path: Path,
    frame_dir: Path,
    labels: set[str],
) -> dict[str, Any]:
    cv2 = _import_required("cv2", "OpenCV is required for IMPACT_CYCLE object tracking.")
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError("Unable to open selected video for tracking.")
    tracks: dict[str, dict[str, Any]] = {}
    assignments_by_frame: dict[str, dict[str, str]] = {}
    contexts_by_frame: dict[str, dict[str, Any]] = {}
    relation_memory: dict[str, dict[str, Any]] = {}
    next_track_index = 1
    previous_frame_idx: int | None = None
    tracker_kind = "opencv_unknown"

    try:
        sorted_graphs = sorted(graphs, key=lambda graph: int(graph.get("frame_idx") or (graph.get("metadata") or {}).get("graph_frame_idx") or 0))
        for graph_pos, graph in enumerate(sorted_graphs, start=1):
            if cancel_event.is_set():
                job = _update_job(job_id, status="cancelled")
                _append_event(job, "cancelled", "Object tracking cancelled.")
                _cleanup_unfinished_job_files(job)
                return {"tracker": tracker_kind, "tracks": [], "assignments_by_frame": {}, "contexts_by_frame": {}}
            frame_idx = int(graph.get("frame_idx") or (graph.get("metadata") or {}).get("graph_frame_idx") or 0)
            frame_path, _, _ = _extract_frame(cv2, cap, video_path, frame_idx, frame_dir)
            frame = cv2.imread(str(frame_path))
            if frame is None:
                raise RuntimeError(f"Unable to read extracted tracking frame: {frame_path}")
            if previous_frame_idx is not None:
                _advance_trackers(cv2, cap, tracks, video_path, previous_frame_idx, frame_idx, frame_dir)

            detections = _tracking_detections(graph, labels)
            predictions = [track for track in tracks.values() if bool(track.get("active", True)) and _track_label(track) in labels]
            matches = _match_tracking_detections(predictions, detections)
            used_detection_indexes = {det_index for _, det_index, _ in matches}
            frame_assignments: dict[str, str] = {}
            frame_track_history: dict[str, dict[str, Any]] = {}

            for track, det_index, match_score in matches:
                detection = detections[det_index]
                entity_id = str(detection["entity_id"])
                observations = list(track.get("observations") or [])
                if observations:
                    prev = dict(observations[-1])
                    frame_track_history[entity_id] = {
                        "track_id": str(track["track_id"]),
                        "previous_frame_idx": int(prev.get("frame_idx") or 0),
                        "previous_label": str(prev.get("label") or track.get("label") or ""),
                        "previous_entity_id": str(prev.get("entity_id") or ""),
                        "seen_frames": [int(row.get("frame_idx") or 0) for row in observations[-6:]],
                        "observation_count": len(observations),
                        "match_iou": float(_bbox_iou(track.get("predicted_bbox") or track.get("bbox") or [], detection["bbox"])),
                        "tracker_score": float(match_score),
                    }
                _record_track_observation(cv2, track, frame, detection, frame_idx)
                tracker_kind = str(track.get("tracker_kind") or tracker_kind)
                frame_assignments[entity_id] = str(track["track_id"])

            for det_index, detection in enumerate(detections):
                if det_index in used_detection_indexes:
                    continue
                track_id = f"track_{next_track_index:04d}"
                next_track_index += 1
                track = {
                    "track_id": track_id,
                    "label": str(detection["label"]),
                    "active": True,
                    "missed": 0,
                    "observations": [],
                }
                _record_track_observation(cv2, track, frame, detection, frame_idx)
                tracker_kind = str(track.get("tracker_kind") or tracker_kind)
                tracks[track_id] = track
                frame_assignments[str(detection["entity_id"])] = track_id

            relation_history = _build_relation_history_for_frame(graph, frame_assignments, relation_memory, frame_idx)
            assignments_by_frame[str(frame_idx)] = frame_assignments
            contexts_by_frame[str(frame_idx)] = {"track_history": frame_track_history, "relation_history": relation_history}
            previous_frame_idx = frame_idx
            percent = round(graph_pos * 100 / max(1, len(sorted_graphs)))
            job = _update_job(job_id, progress={"processedFrames": graph_pos, "totalFrames": len(sorted_graphs), "percent": percent})
            _append_event(job, "tracking_frame", f"Tracked objects for graph {graph_pos}/{len(sorted_graphs)}.", frameIdx=frame_idx, percent=percent)
    finally:
        cap.release()

    serial_tracks = []
    for track in tracks.values():
        observations = [dict(row) for row in list(track.get("observations") or [])]
        if not observations:
            continue
        serial_tracks.append(
            {
                "track_id": str(track.get("track_id") or ""),
                "label": str(track.get("label") or ""),
                "frames": [int(row.get("frame_idx") or 0) for row in observations],
                "entity_ids": [str(row.get("entity_id") or "") for row in observations],
                "bboxes": [list(row.get("bbox") or []) for row in observations],
            }
        )
    return {
        "tracker": tracker_kind,
        "tracks": serial_tracks,
        "assignments_by_frame": assignments_by_frame,
        "contexts_by_frame": contexts_by_frame,
    }


def _tracking_detections(graph: dict[str, Any], labels: set[str]) -> list[dict[str, Any]]:
    detections: list[dict[str, Any]] = []
    for node in list(graph.get("nodes") or []):
        if not isinstance(node, dict):
            continue
        label = _tracking_label(node)
        if label not in labels:
            continue
        bbox = _tracking_bbox(node)
        if len(bbox) != 4 or bbox[2] <= 1 or bbox[3] <= 1:
            continue
        entity_id = str(node.get("entity_id") or node.get("id") or "").strip()
        if not entity_id:
            continue
        detections.append({"entity_id": entity_id, "label": label, "bbox": bbox, "score": _tracking_score(node)})
    return detections


def _tracking_label(node: dict[str, Any]) -> str:
    return str(node.get("canonical_label") or node.get("label") or "").strip().lower()


def _tracking_score(node: dict[str, Any]) -> float:
    try:
        return float(node.get("score") or node.get("confidence") or 0.5)
    except Exception:
        return 0.5


def _tracking_bbox(node: dict[str, Any]) -> list[float]:
    raw = list(node.get("bbox") or [])
    if len(raw) < 4:
        return []
    try:
        return [float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3])]
    except Exception:
        return []


def _track_label(track: dict[str, Any]) -> str:
    return str(track.get("label") or "").strip().lower()


def _record_track_observation(cv2: Any, track: dict[str, Any], frame: Any, detection: dict[str, Any], frame_idx: int) -> None:
    bbox = [float(x) for x in list(detection.get("bbox") or [])[:4]]
    init_bbox = _tracker_bbox_tuple(bbox, frame)
    if init_bbox is None:
        raise RuntimeError(f"Invalid tracking bbox for {detection.get('entity_id')}: {bbox}")
    tracker, tracker_kind = _create_cv_tracker(cv2)
    tracker.init(frame, init_bbox)
    track.update(
        {
            "tracker": tracker,
            "tracker_kind": tracker_kind,
            "bbox": bbox,
            "predicted_bbox": bbox,
            "label": str(detection.get("label") or track.get("label") or ""),
            "active": True,
            "missed": 0,
        }
    )
    observations = list(track.get("observations") or [])
    observations.append(
        {
            "frame_idx": int(frame_idx),
            "entity_id": str(detection.get("entity_id") or ""),
            "label": str(detection.get("label") or ""),
            "bbox": bbox,
            "score": float(detection.get("score") or 0.0),
        }
    )
    track["observations"] = observations


def _create_cv_tracker(cv2: Any) -> tuple[Any, str]:
    for namespace, prefix in ((cv2, "opencv"), (getattr(cv2, "legacy", None), "opencv_legacy")):
        if namespace is None:
            continue
        for name in ("TrackerCSRT_create", "TrackerKCF_create", "TrackerMIL_create"):
            factory = getattr(namespace, name, None)
            if factory is not None:
                return factory(), f"{prefix}_{name.replace('Tracker', '').replace('_create', '').lower()}"
    raise RuntimeError("No usable OpenCV object tracker is available in the current environment.")


def _tracker_bbox_tuple(bbox: list[float], frame: Any) -> tuple[int, int, int, int] | None:
    if len(bbox) < 4 or frame is None:
        return None
    height, width = frame.shape[:2]
    x = int(round(float(bbox[0])))
    y = int(round(float(bbox[1])))
    w = int(round(float(bbox[2])))
    h = int(round(float(bbox[3])))
    x = max(0, min(max(0, int(width) - 2), x))
    y = max(0, min(max(0, int(height) - 2), y))
    w = max(1, min(int(width) - x, w))
    h = max(1, min(int(height) - y, h))
    if w <= 1 or h <= 1:
        return None
    return (int(x), int(y), int(w), int(h))


def _advance_trackers(cv2: Any, cap: Any, tracks: dict[str, dict[str, Any]], video_path: Path, start_frame_idx: int, end_frame_idx: int, frame_dir: Path) -> None:
    if end_frame_idx <= start_frame_idx:
        return
    for frame_idx in range(int(start_frame_idx) + 1, int(end_frame_idx) + 1):
        frame_path, _, _ = _extract_frame(cv2, cap, video_path, frame_idx, frame_dir)
        frame = cv2.imread(str(frame_path))
        if frame is None:
            continue
        for track in tracks.values():
            if not bool(track.get("active", True)):
                continue
            tracker = track.get("tracker")
            if tracker is None:
                continue
            ok, bbox = tracker.update(frame)
            if ok:
                track["predicted_bbox"] = [float(x) for x in list(bbox)[:4]]
                track["missed"] = 0
            else:
                track["missed"] = int(track.get("missed") or 0) + 1
                if int(track.get("missed") or 0) > 30:
                    track["active"] = False


def _match_tracking_detections(tracks: list[dict[str, Any]], detections: list[dict[str, Any]]) -> list[tuple[dict[str, Any], int, float]]:
    candidates: list[tuple[float, int, int]] = []
    for track_index, track in enumerate(tracks):
        predicted = list(track.get("predicted_bbox") or track.get("bbox") or [])
        if len(predicted) != 4:
            continue
        for det_index, detection in enumerate(detections):
            if _track_label(track) != str(detection.get("label") or "").strip().lower():
                continue
            det_bbox = list(detection.get("bbox") or [])
            iou = _bbox_iou(predicted, det_bbox)
            center_score = _center_match_score(predicted, det_bbox)
            if iou < 0.05 and center_score < 0.25:
                continue
            score = 0.65 * iou + 0.25 * center_score + 0.10 * float(detection.get("score") or 0.0)
            if score >= 0.20:
                candidates.append((score, track_index, det_index))
    candidates.sort(reverse=True, key=lambda row: row[0])
    used_tracks: set[int] = set()
    used_detections: set[int] = set()
    matches: list[tuple[dict[str, Any], int, float]] = []
    for score, track_index, det_index in candidates:
        if track_index in used_tracks or det_index in used_detections:
            continue
        used_tracks.add(track_index)
        used_detections.add(det_index)
        matches.append((tracks[track_index], det_index, float(score)))
    return matches


def _bbox_iou(a: Any, b: Any) -> float:
    try:
        ax, ay, aw, ah = [float(x) for x in list(a)[:4]]
        bx, by, bw, bh = [float(x) for x in list(b)[:4]]
    except Exception:
        return 0.0
    inter_x1 = max(ax, bx)
    inter_y1 = max(ay, by)
    inter_x2 = min(ax + aw, bx + bw)
    inter_y2 = min(ay + ah, by + bh)
    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    inter = inter_w * inter_h
    union = max(0.0, aw * ah) + max(0.0, bw * bh) - inter
    return inter / union if union > 0 else 0.0


def _center_match_score(a: Any, b: Any) -> float:
    try:
        ax, ay, aw, ah = [float(x) for x in list(a)[:4]]
        bx, by, bw, bh = [float(x) for x in list(b)[:4]]
    except Exception:
        return 0.0
    acx, acy = ax + aw / 2.0, ay + ah / 2.0
    bcx, bcy = bx + bw / 2.0, by + bh / 2.0
    distance = ((acx - bcx) ** 2 + (acy - bcy) ** 2) ** 0.5
    scale = max(1.0, max(aw, ah, bw, bh) * 2.0)
    return max(0.0, 1.0 - distance / scale)


def _build_relation_history_for_frame(graph: dict[str, Any], assignments: dict[str, str], relation_memory: dict[str, dict[str, Any]], frame_idx: int) -> dict[str, dict[str, Any]]:
    relation_history: dict[str, dict[str, Any]] = {}
    for edge in list(graph.get("edges") or []):
        if not isinstance(edge, dict):
            continue
        src = str(edge.get("src_id") or edge.get("source") or "").strip()
        dst = str(edge.get("dst_id") or edge.get("target") or "").strip()
        rel = str(edge.get("relation") or "").strip()
        if not src or not dst or not rel:
            continue
        src_track = assignments.get(src)
        dst_track = assignments.get(dst)
        if not src_track or not dst_track:
            continue
        track_signature = f"{src_track}|{rel}|{dst_track}"
        current_signature = f"{src}|{rel}|{dst}"
        memory = relation_memory.get(track_signature)
        if memory is not None:
            relation_history[current_signature] = {
                "previous_frame_idx": int(memory.get("previous_frame_idx") or 0),
                "seen_frames": list(memory.get("seen_frames") or []),
                "track_src": src_track,
                "track_dst": dst_track,
            }
        seen = list((memory or {}).get("seen_frames") or [])
        seen.append(int(frame_idx))
        relation_memory[track_signature] = {"previous_frame_idx": int(frame_idx), "seen_frames": seen[-8:]}
    return relation_history


def _inject_tracking_contexts(graphs: list[dict[str, Any]], tracking_path: Path) -> None:
    payload = _read_json_file(tracking_path)
    contexts = dict(payload.get("contexts_by_frame") or {})
    for graph in graphs:
        frame_idx = str(int(graph.get("frame_idx") or (graph.get("metadata") or {}).get("graph_frame_idx") or 0))
        context = dict(contexts.get(frame_idx) or {})
        if not context:
            continue
        metadata = dict(graph.get("metadata") or {})
        metadata["temporal_context"] = {
            "track_history": dict(context.get("track_history") or {}),
            "relation_history": dict(context.get("relation_history") or {}),
        }
        graph["metadata"] = metadata


def _build_prompt_items_for_precompute(**kwargs: Any) -> list[dict[str, str]]:
    repo_root = Path(kwargs["repo_root"])
    video_path = Path(kwargs["video_path"])
    pipeline_cfg = dict(kwargs["pipeline_cfg"])
    load_json = kwargs["load_json"]
    load_prompt_pack = kwargs["load_prompt_pack"]
    merge_ontology_payload = kwargs["merge_ontology_payload"]
    condense_category_prompt_items = kwargs["condense_category_prompt_items"]
    ontology_from_payload = kwargs["ontology_from_payload"]
    ontology_path = Path(kwargs["ontology_path"])
    ontology_payload = load_json(str(ontology_path))
    prompt_pack_file = str(pipeline_cfg.get("ontology_prompt_pack_file", "") or "").strip()
    explicit_category_prompts: list[dict[str, str]] = []
    if prompt_pack_file:
        prompt_pack_path = Path(prompt_pack_file)
        if not prompt_pack_path.is_absolute():
            prompt_pack_path = repo_root / prompt_pack_path
        if prompt_pack_path.is_file():
            prompt_pack_payload = load_prompt_pack(str(prompt_pack_path))
            ontology_payload = merge_ontology_payload(ontology_payload, prompt_pack_payload)
            explicit_category_prompts = [
                {"canonical_label": str(x.get("canonical_label", "") or "").strip(), "prompt": str(x.get("prompt", "") or "").strip()}
                for x in list(prompt_pack_payload.get("explicit_category_prompts") or [])
                if isinstance(x, dict)
            ]
    ontology = ontology_from_payload(ontology_payload)
    if explicit_category_prompts:
        prompt_items = condense_category_prompt_items(list(explicit_category_prompts))
    else:
        prompt_items = condense_category_prompt_items(list(ontology.build_prompt_bank().category_prompts or []))
    default_prompt_items = [{"canonical_label": label, "prompt": label} for label in DEFAULT_SAM3_PROMPT_LABELS]
    video_prompt_items = _prompt_items_from_sibling_reports(video_path)
    prompt_items = condense_category_prompt_items(default_prompt_items + video_prompt_items + prompt_items)
    max_category_prompts = int(dict(pipeline_cfg.get("proposal") or {}).get("max_category_prompts", 32) or 32)
    if max_category_prompts > 0 and len(prompt_items) > max_category_prompts:
        prompt_items = prompt_items[:max_category_prompts]
    if not prompt_items:
        raise RuntimeError("No SAM3 prompt items were built from the Impact_Cycle ontology.")
    return prompt_items


def _impact_cycle_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent / "IMPACT_CYCLE"


def _read_json_file(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        raise RuntimeError(f"JSON file must contain an object: {path}")
    return payload


def _load_mounted_json(relative_path: str) -> dict[str, Any]:
    path = _safe_resolve(_mounted_root(), relative_path)
    if not path.is_file() or path.suffix.lower() != ".json":
        raise RuntimeError(f"Mounted JSON file not found: {relative_path}")
    return _read_json_file(path)


def _complete_workflow_job(job_id: str, message: str, artifacts: list[dict[str, str]]) -> None:
    mounted_artifacts: list[dict[str, str]] = []
    for artifact in artifacts:
        path = Path(str(artifact.get("path") or ""))
        mounted_path = ""
        try:
            mounted_path = path.resolve().relative_to(_mounted_root()).as_posix()
        except Exception:
            mounted_path = ""
        row = {"type": str(artifact.get("type") or "artifact"), "name": str(artifact.get("name") or path.name)}
        if mounted_path:
            row["mountedPath"] = mounted_path
        mounted_artifacts.append(row)
    job = _update_job(job_id, status="completed", artifacts=mounted_artifacts, progress={"processedFrames": 1, "totalFrames": 1, "percent": 100})
    _append_event(job, "completed", message, artifacts=mounted_artifacts)


def _flatten_vqa_payload(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [dict(x) for x in payload if isinstance(x, dict)]
    if not isinstance(payload, dict):
        return []
    if isinstance(payload.get("all"), list):
        return [dict(x) for x in payload.get("all") if isinstance(x, dict)]
    out: list[dict[str, Any]] = []
    if isinstance(payload.get("per_graph"), list):
        for row in payload.get("per_graph") or []:
            if not isinstance(row, dict):
                continue
            out.extend(_flatten_vqa_payload(row.get("vqa")))
    for key in ("single_turn", "multi_turn"):
        value = payload.get(key)
        if isinstance(value, list):
            out.extend(dict(x) for x in value if isinstance(x, dict))
    return out


def _evaluate_graph_payloads(pred: dict[str, Any], gt: dict[str, Any], evaluator: Any, iou: float) -> dict[str, Any]:
    pred_graphs = [dict(x) for x in list(pred.get("graphs") or []) if isinstance(x, dict)]
    gt_graphs = [dict(x) for x in list(gt.get("graphs") or []) if isinstance(x, dict)]
    if pred_graphs or gt_graphs:
        count = min(len(pred_graphs), len(gt_graphs))
        if count <= 0:
            raise RuntimeError("Prediction and ground truth graph bundles must both contain graphs.")
        rows = [evaluator(pred_graphs[i], gt_graphs[i], iou_threshold=iou) for i in range(count)]
        keys = sorted({key for row in rows for key in row.keys()})
        return {key: sum(float(row.get(key, 0.0) or 0.0) for row in rows) / float(count) for key in keys} | {"graph_count": count}
    return evaluator(pred, gt, iou_threshold=iou)


def _litellm_cycle_cfg(repo_root: Path, *, rounds: int, low_quota: bool) -> dict[str, Any]:
    cfg = _read_json_file(repo_root / "configs" / "impact_cycle.json")
    cfg["local_verifier"] = {"provider": "mock"}
    cfg["api_verifier"] = {"enabled": False}
    runtime = dict(cfg.get("runtime") or {})
    runtime.update({"allow_mock_fallback": False, "preferred_provider": "litellm_lm_studio", "safe_local_only": False})
    cfg["runtime"] = runtime
    cycle = dict(cfg.get("cycle") or {})
    cycle["max_revision_rounds"] = max(1, int(rounds or 1))
    if low_quota:
        cycle["enable_multi_turn_probes"] = False
        cycle["enable_caption_probe"] = False
    cfg["cycle"] = cycle
    return cfg


def _resolve_graph_image_path(graph: dict[str, Any], *, video_path: Path | None, frame_dir: Path) -> str:
    meta = dict(graph.get("metadata") or {})
    cached = str(meta.get("image_path") or "").strip()
    if cached and Path(cached).is_file():
        return cached
    if video_path is None or not video_path.is_file():
        return ""
    frame_idx = int(graph.get("frame_idx") or meta.get("graph_frame_idx") or 0)
    cv2 = _import_required("cv2", "OpenCV is required for IMPACT_CYCLE video frame extraction.")
    cap = cv2.VideoCapture(str(video_path))
    try:
        image_path, _, _ = _extract_frame(cv2, cap, video_path, frame_idx, frame_dir)
        return str(image_path)
    finally:
        cap.release()


def _sanitize_cycle_result(index: int, graph: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
    out = {
        "graph_idx": index,
        "frame_idx": graph.get("frame_idx"),
        "summary": dict(result.get("summary") or {}),
        "human_queue": [dict(x) for x in list(result.get("human_queue") or []) if isinstance(x, dict)],
        "votes": [dict(x) for x in list(result.get("votes") or []) if isinstance(x, dict)],
        "probe_results": [],
        "graph_after": result.get("graph_after"),
    }
    for probe in list(result.get("probe_results") or []):
        if not isinstance(probe, dict):
            continue
        row = dict(probe)
        for key in ("response", "parsed_response"):
            if isinstance(row.get(key), dict):
                payload = dict(row[key])
                for drop_key in ("raw_response", "raw_text", "request_prompt", "request_schema"):
                    payload.pop(drop_key, None)
                row[key] = payload
        out["probe_results"].append(row)
    return out


class _LiteLLMTextVisionVerifier:
    def __init__(self, progress_cb: Any = None) -> None:
        self.progress_cb = progress_cb
        self.model = "openai/google/gemma-4-31b"
        self.api_base = "http://host.docker.internal:1234/v1"

    def answer_probe(self, *, image_path: str, question: str, regions: list[dict[str, Any]], response_format: dict[str, Any] | None = None, schema: dict[str, Any] | None = None) -> dict[str, Any]:
        fmt = dict(response_format or {})
        wants_selection = str(fmt.get("type") or "").strip().lower() == "selection"
        prompt = {
            "task": "Answer an Impact_Cycle verification probe. Return JSON only.",
            "question": question,
            "regions": regions,
            "response_format": response_format or {},
            "schema": schema or {},
            "allowed_keys": ["selection", "reason", "score"] if wants_selection else ["answer", "reason", "score"],
        }
        payload = self._complete_json(prompt, max_tokens=192)
        if wants_selection:
            selection = str(payload.get("selection") or payload.get("answer") or fmt.get("default_selection") or "uncertain").strip() or "uncertain"
            return {"selection": selection, "reason": str(payload.get("reason") or "LiteLLM verifier response."), "score": _clamp_score(payload.get("score")), "raw_text": json.dumps(payload, ensure_ascii=True), "schema_valid": True}
        answer = str(payload.get("answer") or payload.get("selection") or "uncertain").strip() or "uncertain"
        return {"answer": answer, "reason": str(payload.get("reason") or "LiteLLM verifier response."), "score": _clamp_score(payload.get("score")), "raw_text": json.dumps(payload, ensure_ascii=True), "schema_valid": True}

    def generate_caption(self, *, image_path: str, prompt: str, regions: list[dict[str, Any]], video_or_frames: object = None, schema: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = self._complete_json({"task": "Generate an Impact_Cycle caption. Return JSON only.", "prompt": prompt, "regions": regions, "schema": schema or {}}, max_tokens=256)
        caption = str(payload.get("caption") or payload.get("answer") or "").strip() or json.dumps(payload, ensure_ascii=True)
        return {"caption": caption, "raw_text": json.dumps(payload, ensure_ascii=True), "schema_valid": True}

    _MAX_RETRIES = 10
    _RETRY_DELAY_SEC = 10
    _REQUEST_TIMEOUT_SEC = 30

    def _complete_json(self, payload: dict[str, Any], *, max_tokens: int) -> dict[str, Any]:
        litellm = _import_required("litellm", "LiteLLM is required for LM Studio calls.")
        last_error: Exception | None = None
        for attempt in range(1, self._MAX_RETRIES + 1):
            try:
                if self.progress_cb is not None:
                    self.progress_cb(f"Calling LM Studio via LiteLLM (attempt {attempt}/{self._MAX_RETRIES}).")
                response = litellm.completion(
                    model=self.model,
                    api_base=self.api_base,
                    api_key="lm-studio",
                    messages=[{"role": "user", "content": json.dumps(payload, ensure_ascii=True)}],
                    temperature=0,
                    max_tokens=max_tokens,
                    timeout=self._REQUEST_TIMEOUT_SEC,
                )
                text = _litellm_completion_text(response)
                if not text:
                    details = _litellm_empty_completion_details(response)
                    raise RuntimeError(f"LM Studio returned an empty completion ({details}).")
                return _parse_json_object(text)
            except Exception as exc:
                last_error = exc
                error_str = str(exc).lower()
                is_connection = any(
                    keyword in error_str
                    for keyword in ("timeout", "connection", "connect", "refused", "unreachable", "network", "reset", "unavailable")
                )
                if not is_connection and attempt >= self._MAX_RETRIES:
                    raise
                if attempt >= self._MAX_RETRIES:
                    raise RuntimeError(
                        f"LiteLLM LM Studio connection failed after {self._MAX_RETRIES} retries: {last_error}"
                    ) from last_error
                if self.progress_cb is not None:
                    self.progress_cb(
                        f"LiteLLM connection error (attempt {attempt}/{self._MAX_RETRIES}), "
                        f"retrying in {self._RETRY_DELAY_SEC}s: {exc}"
                    )
                time.sleep(self._RETRY_DELAY_SEC)
        raise RuntimeError(
            f"LiteLLM LM Studio connection failed after {self._MAX_RETRIES} retries: {last_error}"
        ) from last_error


def _parse_json_object(text: str) -> dict[str, Any]:
    raw = str(text or "").strip()
    try:
        payload = json.loads(raw)
        return payload if isinstance(payload, dict) else {}
    except Exception:
        match = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if match:
            try:
                payload = json.loads(match.group(0))
                return payload if isinstance(payload, dict) else {}
            except Exception:
                pass
    return {"answer": "uncertain", "reason": raw[:400], "score": 0.0}


def _clamp_score(value: Any) -> float:
    try:
        return max(0.0, min(1.0, float(value)))
    except Exception:
        return 0.0


def _prompt_items_from_sibling_reports(video_path: Path) -> list[dict[str, str]]:
    labels: list[str] = []
    seen: set[str] = set()
    for path in _sibling_report_candidates(video_path):
        if not path.is_file():
            continue
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if not isinstance(row, dict):
                        continue
                    label = str(row.get("label") or row.get("class") or row.get("object_type") or row.get("type") or "").strip().lower()
                    if label and re.fullmatch(r"[a-z0-9][a-z0-9 _-]{0,60}", label) and label not in seen:
                        seen.add(label)
                        labels.append(label)
        except Exception:
            continue
    return [{"canonical_label": label, "prompt": label} for label in labels]


def _frame_indices_from_sibling_reports(video_path: Path, *, source_fps: float, frame_count: int) -> list[int]:
    indices: list[int] = []
    seen: set[int] = set()
    fps = max(0.1, float(source_fps or 1.0))
    for path in _sibling_report_candidates(video_path):
        if not path.is_file():
            continue
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    seconds = _parse_report_timestamp_seconds(str((row or {}).get("first_time_seen") or ""))
                    if seconds is None:
                        continue
                    idx = max(0, min(max(0, int(frame_count) - 1), int(round(seconds * fps))))
                    if idx not in seen:
                        seen.add(idx)
                        indices.append(idx)
        except Exception:
            continue
    return indices


def _sibling_report_candidates(video_path: Path) -> list[Path]:
    return [
        video_path.with_name(f"report_{video_path.name}.csv"),
        video_path.with_suffix(video_path.suffix + ".csv"),
        video_path.with_suffix(".csv"),
    ]


def _parse_report_timestamp_seconds(text: str) -> float | None:
    match = re.fullmatch(r"(\d{1,2}):(\d{2}):(\d{2})[:.](\d{1,3})", str(text or "").strip())
    if not match:
        return None
    hours, minutes, seconds, millis = match.groups()
    return int(hours) * 3600 + int(minutes) * 60 + int(seconds) + int(millis.ljust(3, "0")[:3]) / 1000.0


def _detection_payload_to_graph(payload: dict[str, Any], *, frame_idx: int, source_fps: float, image_path: Path, detection_path: Path) -> dict[str, Any]:
    nodes: list[dict[str, Any]] = []
    seen: set[tuple[str, tuple[float, float, float, float]]] = set()
    for item in list(payload.get("prompt_results") or []):
        if not isinstance(item, dict):
            continue
        label = str(item.get("canonical_label") or item.get("prompt") or "object").strip() or "object"
        for record in list(item.get("post_threshold_records") or []):
            if not isinstance(record, dict):
                continue
            bbox = list(record.get("bbox") or [])
            if len(bbox) < 4:
                continue
            xywh = tuple(float(x or 0.0) for x in bbox[:4])
            key = (label, xywh)
            if key in seen:
                continue
            seen.add(key)
            nodes.append(
                {
                    "id": f"n{len(nodes) + 1}",
                    "entity_id": f"sam3_{frame_idx}_{len(nodes) + 1}",
                    "label": label,
                    "canonical_label": label,
                    "bbox": [xywh[0], xywh[1], xywh[2], xywh[3]],
                    "score": float(record.get("score", 0.0) or 0.0),
                }
            )
    time_sec = float(frame_idx) / max(0.1, float(source_fps or 1.0))
    return {
        "frame_idx": int(frame_idx),
        "time_sec": time_sec,
        "summary": f"{len(nodes)} SAM3 detection(s)",
        "nodes": nodes,
        "edges": [],
        "metadata": {"graph_frame_idx": int(frame_idx), "graph_time_sec": time_sec, "image_path": str(image_path), "detection_path": str(detection_path)},
    }


def _extract_frame(cv2: Any, cap: Any, video_path: Path, frame_idx: int, frame_dir: Path) -> tuple[Path, int, int]:
    frame_dir.mkdir(parents=True, exist_ok=True)
    safe_stem = _safe_filename(video_path.stem)
    out_path = frame_dir / f"{safe_stem}_f{int(frame_idx):06d}.jpg"
    if out_path.is_file():
        image = cv2.imread(str(out_path))
        if image is not None:
            height, width = image.shape[:2]
            return out_path, int(width), int(height)
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(frame_idx))
    ok, frame = cap.read()
    if not ok or frame is None:
        raise RuntimeError(f"Unable to extract video frame {int(frame_idx)}.")
    height, width = frame.shape[:2]
    if not cv2.imwrite(str(out_path), frame):
        raise RuntimeError(f"Unable to write extracted frame: {out_path}")
    return out_path, int(width), int(height)


def _write_detection_bundle(job: dict[str, Any], video_path: Path, frame_count: int, source_fps: float, sampling_fps: float, frame_indices: list[int], graphs: list[dict[str, Any]]) -> None:
    _write_json_atomic(
        Path(str(job.get("bundle_path", ""))),
        {
            "type": "sam3_detection_sequence",
            "version": 3,
            "format": "compact",
            "video_path": str(video_path),
            "video_name": video_path.name,
            "frame_count": frame_count,
            "source_fps": source_fps,
            "sampling_fps": sampling_fps,
            "sampled_frame_indices": [int(x) for x in frame_indices],
            "graphs": graphs,
        },
    )


def _cleanup_unfinished_job_files(job: dict[str, Any]) -> None:
    if str(job.get("status")) == "completed":
        return
    run_dir = Path(str(job.get("run_dir", "")))
    output_dir = Path(str(job.get("output_dir", "")))
    try:
        if run_dir.resolve().is_relative_to(_runs_dir().resolve()) and run_dir.exists():
            shutil.rmtree(run_dir)
    except Exception:
        pass
    try:
        if not bool((job.get("settings") or {}).get("directOutput", False)) and output_dir.resolve().is_relative_to(_mounted_root()) and output_dir.exists():
            shutil.rmtree(output_dir)
    except Exception:
        pass


def _record_lm_studio_failure_if_connection(error_str: str, job_id: str) -> None:
    error_lower = error_str.lower()
    if any(
        keyword in error_lower
        for keyword in ("lm studio", "litellm", "connection", "timeout", "unreachable", "refused", "network")
    ):
        with _STORE_LOCK:
            _LM_STUDIO_FAILURES.append(
                {
                    "type": "lm_studio",
                    "status": "failed",
                    "message": f"LM Studio unreachable (job {job_id[:8]}): {error_str[:200]}",
                    "jobId": job_id,
                }
            )
            if len(_LM_STUDIO_FAILURES) > 20:
                _LM_STUDIO_FAILURES[:] = _LM_STUDIO_FAILURES[-20:]


def _import_required(module_name: str, message: str) -> Any:
    try:
        __import__(module_name)
        return sys.modules[module_name]
    except Exception as exc:
        raise RuntimeError(f"{message} Missing dependency: {module_name} ({exc})") from exc

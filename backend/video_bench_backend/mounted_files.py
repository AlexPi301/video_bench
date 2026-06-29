"""Browsing, serving, and editing helpers for mounted input files."""

from __future__ import annotations

import json
import mimetypes
import os
from pathlib import Path
from urllib.parse import quote

from django.conf import settings
from django.http import Http404, HttpRequest, HttpResponse, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST, require_safe


VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
CSV_EXTENSIONS = {".csv"}
JSON_EXTENSIONS = {".json"}
ALLOWED_EXTENSIONS = VIDEO_EXTENSIONS | CSV_EXTENSIONS | JSON_EXTENSIONS


def _mounted_root() -> Path:
    return Path(getattr(settings, "VIDEO_BENCH_MOUNTED_FILES_ROOT", "/mounted-input")).resolve()


def _safe_resolve(relative_path: str) -> Path:
    root = _mounted_root()
    candidate = (root / str(relative_path or "")).resolve()
    try:
        common = os.path.commonpath([str(root), str(candidate)])
    except ValueError as exc:
        raise Http404("Invalid mounted file path.") from exc
    if common != str(root):
        raise Http404("Mounted file path escapes the configured root.")
    return candidate


def _relative_to_root(path: Path) -> str:
    rel = path.relative_to(_mounted_root())
    return "" if str(rel) == "." else rel.as_posix()


def _file_kind(path: Path) -> str | None:
    suffix = path.suffix.lower()
    if suffix in VIDEO_EXTENSIONS:
        return "video"
    if suffix in CSV_EXTENSIONS:
        return "csv"
    if suffix in JSON_EXTENSIONS:
        return "json"
    return None


def _entry_payload(path: Path) -> dict[str, object] | None:
    if path.name.startswith("."):
        return None
    rel_path = _relative_to_root(path)
    if path.is_dir():
        return {"name": path.name, "path": rel_path, "type": "directory", "kind": "directory"}
    if not path.is_file():
        return None
    kind = _file_kind(path)
    if kind is None:
        return None
    return {
        "name": path.name,
        "path": rel_path,
        "type": "file",
        "kind": kind,
        "url": f"/api/mounted-files/file/?path={quote(rel_path)}",
    }


@require_GET
def list_mounted_files(request: HttpRequest) -> JsonResponse:
    requested_path = str(request.GET.get("path", "") or "")
    requested_kind = str(request.GET.get("kind", "all") or "all").lower()
    if requested_kind not in {"all", "video", "csv", "json"}:
        return JsonResponse({"error": "kind must be one of: all, video, csv, json"}, status=400)

    root = _mounted_root()
    current = _safe_resolve(requested_path)
    if not root.exists() or not root.is_dir():
        return JsonResponse({"path": "", "parent": None, "entries": []})
    if not current.exists() or not current.is_dir():
        raise Http404("Mounted directory not found.")

    entries: list[dict[str, object]] = []
    for child in sorted(current.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower())):
        payload = _entry_payload(child)
        if payload is None:
            continue
        if payload["type"] == "file" and requested_kind != "all" and payload["kind"] != requested_kind:
            continue
        entries.append(payload)

    rel_current = _relative_to_root(current)
    parent = None
    if current != root:
        parent = _relative_to_root(current.parent)

    return JsonResponse({"path": rel_current, "parent": parent, "entries": entries})


@require_safe
def serve_mounted_file(request: HttpRequest) -> HttpResponse:
    requested_path = str(request.GET.get("path", "") or "")
    if not requested_path:
        raise Http404("Missing mounted file path.")

    path = _safe_resolve(requested_path)
    if not path.exists() or not path.is_file() or _file_kind(path) is None:
        raise Http404("Mounted file not found.")

    rel_path = _relative_to_root(path)
    response = HttpResponse(status=200)
    content_type, _encoding = mimetypes.guess_type(path.name)
    if content_type:
        response["Content-Type"] = content_type
    response["Content-Disposition"] = f'inline; filename="{path.name}"'
    response["X-Accel-Redirect"] = "/_mounted-files-internal/" + quote(rel_path)
    return response


@csrf_exempt
@require_POST
def save_mounted_file(request: HttpRequest) -> JsonResponse:
    """Persist JSON content (e.g., qa_pairs.json) under the mounted input root.

    The endpoint is intentionally restricted to JSON files so the mounted input
    volume stays a trusted location for analyzer reports and annotation files.
    Parent directories are created on demand so a video's ``*_meta`` directory
    can receive a new ``qa_pairs.json`` without a separate call.
    """
    try:
        raw_body = request.body.decode("utf-8") if request.body else ""
        payload = json.loads(raw_body) if raw_body else {}
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return JsonResponse({"error": f"Invalid JSON body: {exc}"}, status=400)
    if not isinstance(payload, dict):
        return JsonResponse({"error": "JSON body must be an object."}, status=400)

    requested_path = str(payload.get("path", "") or "").strip()
    content = payload.get("content")
    if not requested_path:
        return JsonResponse({"error": "Missing 'path' field."}, status=400)
    if content is None:
        return JsonResponse({"error": "Missing 'content' field."}, status=400)

    try:
        path = _safe_resolve(requested_path)
    except Http404 as exc:
        return JsonResponse({"error": str(exc)}, status=400)

    if path.suffix.lower() not in JSON_EXTENSIONS:
        return JsonResponse(
            {"error": "Only .json files can be saved via this endpoint."},
            status=400,
        )

    text = content if isinstance(content, str) else json.dumps(
        content, ensure_ascii=True, indent=2
    )
    try:
        json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        return JsonResponse({"error": f"Invalid JSON content: {exc}"}, status=400)

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        with tmp_path.open("w", encoding="utf-8") as handle:
            handle.write(text)
            if not text.endswith("\n"):
                handle.write("\n")
        tmp_path.replace(path)
    except OSError as exc:
        return JsonResponse({"error": f"Could not write file: {exc}"}, status=500)

    rel_path = _relative_to_root(path)
    return JsonResponse(
        {
            "name": path.name,
            "path": rel_path,
            "type": "file",
            "kind": "json",
            "url": f"/api/mounted-files/file/?path={quote(rel_path)}",
        },
        status=200,
    )

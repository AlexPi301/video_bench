# Video Bench

A web application for benchmarking the video understanding capabilities of Visual Language Models (VLMs) that directly accept video as input. Video Bench supports the full benchmarking lifecycle &mdash; from automatic object detection and captioning to QA-pair generation, annotation review, and evaluation &mdash; in a single containerized tool.

## Overview

Evaluating VLMs on video requires more than a model and a prompt: it requires grounded metadata, temporally aligned captions, well-formed question-answer pairs, and a reviewable annotation set. Video Bench brings these steps together in one web app so practitioners can move from a raw video to an editable, evaluable benchmark dataset without stitching together separate scripts.

The current scope targets **VLMs that directly accept video as input**. The pipeline combines:

- **SAM3** (Segment Anything Model 3) for frame-grounded object detection and counting.
- **Local LLMs via LM Studio** for per-frame caption generation.
- **Advanced VLMs** for auto-generating question-answer pairs from scene graphs.
- A built-in annotation UI for quickly adding, reviewing, and editing QA pairs tied to video timelines.

## Key Features

- **Full lifecycle in one app.** Detection, captioning, QA generation, tracking, cycle verification, evaluation, and annotation review &mdash; all behind a single web UI.
- **SAM3 object detection and counting.** Sample frames from a video, run SAM3 grounding, and produce a scene-graph bundle with per-frame detections and counts.
- **Local caption generation.** Generate per-frame captions with any vision-capable model served by [LM Studio](https://lmstudio.ai/), keeping the pipeline local and reproducible. Caption jobs are resumable and timeout-tolerant.
- **Automatic QA-pair generation.** Turn scene graphs into single-turn and multi-turn VQA items automatically, ready for human review.
- **Object tracking.** Track selected object categories (person, car, truck, plane, and more) across sampled frames for temporal consistency probes.
- **Claim-level cycle verification.** Refine scene graphs through single-turn VQA, multi-turn VQA, and caption-audit verification fused into a revised graph.
- **Built-in evaluation.** Compare predicted scene graphs and VQA answers against ground truth with standard metrics.
- **Annotation review UI.** Drop in a video and its report CSV, browse detections and QA pairs on a shared timeline, filter by category or family, and edit `qa_pairs.json` inline. Changes are saved atomically back to the mounted input volume.
- **Mounted-file browsing.** Browse, serve, and edit JSON annotation files directly from a mounted input directory through a safe, path-confined API.
- **Containerized deployment.** A single multi-stage Docker image ships the Flutter web frontend, the Django backend, and nginx &mdash; no host-side toolchain required.

## Benchmarking Lifecycle

```text
Video
  |
  v
SAM3 detection precompute  -->  scene graph bundle (per-frame objects, counts, bboxes)
  |
  v
Caption generation (LM Studio)  -->  per-frame captions with timestamps
  |
  v
VQA generation (advanced VLM)  -->  single-turn + multi-turn QA pairs
  |
  v
Object tracking + cycle verification  -->  temporally consistent, refined graph
  |
  v
Annotation review UI  -->  add / review / edit QA pairs on a timeline
  |
  v
Evaluation (scene graph + VQA metrics)  -->  benchmark scores
```

## Architecture

| Layer | Technology |
| :--- | :--- |
| Web frontend | Flutter web (Material 3), served as static assets by nginx |
| Backend API | Django 5 + Django REST Framework, served by gunicorn |
| Reverse proxy | nginx (static frontend, `/api/` proxy, internal file serving) |
| Database | SQLite (stored under `/data`) |
| Video/image processing | OpenCV, NumPy |
| ML/AI dependencies | transformers, huggingface_hub, litellm, torchvision, safetensors, accelerate |
| Scene-graph engine | Integrated [IMPACT_CYCLE](backend/IMPACT_CYCLE) pipeline |
| Container | Multi-stage Docker image (Flutter builder, Python builder, runtime) |

The backend exposes a REST API under `/api/` with endpoints for mounted-file browsing, SAM3 detection jobs, caption generation, VQA generation, object tracking, cycle verification, and scene-graph/VQA evaluation. Jobs run in background threads and report progress through a JSON event log that the frontend polls live.

## Installation

Video Bench ships as a single Docker image. The only host-side requirement is Docker.

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (Engine 24+ or Docker Desktop)
- A directory on the host containing your input videos and CSV report files
- (Optional) [LM Studio](https://lmstudio.ai/) running a vision-capable model, reachable from the container at `http://host.docker.internal:1234/v1`

### 1. Clone the repository

```bash
git clone git@github.com:AlexPi301/video_bench.git
cd video_bench
```

> Alternatively, use HTTPS: `git clone https://github.com/AlexPi301/video_bench.git`

### 2. Build the Docker image

From the repository root (`video_bench/`):

```bash
docker build -t video-bench:latest -f docker/Dockerfile .
```

Optional build argument:

- `VIDEO_BENCH_EXPERIMENTAL=true` &mdash; enables the experimental Impact Cycle panel in the UI.

### 3. Run the container

```bash
docker run -d \
  --name video-bench \
  -p 8080:80 \
  -v video-bench-data:/data \
  -v /path/to/your/input:/mounted-input:ro \
  --add-host=host.docker.internal:host-gateway \
  --restart unless-stopped \
  video-bench:latest
```

Replace `/path/to/your/input` with the host directory that contains your videos and CSV report files.

### 4. Open the app

Navigate to <http://localhost:8080/> in your browser. The container reports a health status once nginx and gunicorn are ready:

```bash
docker ps --filter name=video-bench
docker logs video-bench
```

## Configuration

### Required volume mounts

| Container path | Purpose |
| :--- | :--- |
| `/data` | Persists the SQLite database and IMPACT_CYCLE output. Use a named volume for persistence across container restarts. |
| `/mounted-input` | Input videos, CSV reports, and JSON annotation files referenced by the backend. Mount read-only for review-only setups, or read-write to save edited annotations back to disk. |

### Common environment variables

Override these with `-e` on `docker run`:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `DJANGO_ALLOWED_HOSTS` | `localhost,127.0.0.1` | Comma-separated Django `ALLOWED_HOSTS`. Add the host or IP you serve from. |
| `DJANGO_SECRET_KEY` | insecure dev key | Set to a strong random value for any non-local deployment. |
| `DJANGO_DB_PATH` | `/data/db.sqlite3` | SQLite database location inside the container. |
| `VIDEO_BENCH_MOUNTED_FILES_ROOT` | `/mounted-input` | Root directory for browsing and serving mounted input files. |
| `VIDEO_BENCH_IMPACT_CYCLE_ROOT` | `/data/impact-cycle` | Root directory for IMPACT_CYCLE uploads, runs, and job metadata. |
| `GUNICORN_WORKERS` | `2` | Gunicorn worker process count. |
| `GUNICORN_THREADS` | `2` | Gunicorn threads per worker. |
| `GUNICORN_TIMEOUT` | `120` | Gunicorn worker timeout in seconds. |

### Connecting to LM Studio

Caption generation calls LM Studio through LiteLLM. Start LM Studio on your host, load a vision-capable model, enable the local server, and pass its URL when creating a caption-generation job:

- Default URL from inside the container: `http://host.docker.internal:1234/v1`
- The `--add-host=host.docker.internal:host-gateway` flag in the run command makes the host reachable under that name on Linux.

## Stopping and removing

```bash
docker stop video-bench
docker rm video-bench
```

The named volume `video-bench-data` persists across container removal. Remove it explicitly to start fresh:

```bash
docker volume rm video-bench-data
```

## Project structure

```text
video_bench/
|-- backend/
|   |-- video_bench_backend/      # Django project: settings, URLs, impact_cycle + mounted_files APIs
|   |-- IMPACT_CYCLE/             # Integrated scene-graph + VQA verification engine
|   |-- helpers/                  # Caption retrieval helpers
|   |-- requirements.txt
|   `-- manage.py
|-- frontend/
|   |-- lib/
|   |   |-- models/               # Dart data models (annotations, reports, impact cycle jobs)
|   |   |-- services/             # API clients, parsers, DevTools agent bridge
|   |   `-- widgets/              # Video Bench and Impact Cycle pages, timeline, video surface
|   `-- pubspec.yaml
|-- docker/
|   |-- Dockerfile                # Multi-stage production image
|   |-- nginx.conf
|   `-- entrypoint.sh
`-- README.md
```

## License

This project is released under the Apache License 2.0. See the `IMPACT_CYCLE/LICENSE` file for the license of the integrated scene-graph engine. Please also review the terms of use of any external models and datasets you connect (SAM3 checkpoints, Qwen, LM Studio models, VidOR/PVSG, etc.).

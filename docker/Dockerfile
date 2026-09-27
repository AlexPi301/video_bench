# Production image for Video Bench Flutter web frontend, Django backend, and nginx.
# syntax=docker/dockerfile:1.7

ARG DEBIAN_FRONTEND=noninteractive
ARG APP_DIR=.

FROM ubuntu:22.04 AS flutter-builder

ARG DEBIAN_FRONTEND
ARG APP_DIR=.
ARG FLUTTER_VERSION=3.38.8
ARG VIDEO_BENCH_EXPERIMENTAL=false

# Flutter archives can contain UIDs outside rootless Podman's user namespace.
# Keep extracted SDK artifacts owned by the user performing the build.
ENV TAR_OPTIONS=--no-same-owner \
    FLUTTER_HOME=/opt/flutter \
    PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libglu1-mesa \
    unzip \
    xz-utils \
    zip \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}"

RUN --mount=type=cache,id=video-bench-flutter-artifacts,target=/opt/flutter/bin/cache \
    for attempt in 1 2 3 4 5; do \
        flutter config --enable-web && flutter doctor -v && exit 0; \
        echo "Flutter SDK artifact download failed (attempt ${attempt}/5); retrying..."; \
        sleep 5; \
    done; \
    exit 1

WORKDIR /app/frontend

COPY ${APP_DIR}/frontend/pubspec.yaml ./
RUN --mount=type=cache,id=video-bench-flutter-artifacts,target=/opt/flutter/bin/cache \
    --mount=type=cache,id=video-bench-pub-cache,target=/root/.pub-cache \
    flutter pub get

COPY ${APP_DIR}/frontend ./
RUN --mount=type=cache,id=video-bench-flutter-artifacts,target=/opt/flutter/bin/cache \
    --mount=type=cache,id=video-bench-pub-cache,target=/root/.pub-cache \
    flutter build web --release --base-href / --dart-define=VIDEO_BENCH_EXPERIMENTAL=${VIDEO_BENCH_EXPERIMENTAL}

FROM python:3.12-slim-bookworm AS python-builder

ARG APP_DIR=.

ENV PIP_DISABLE_PIP_VERSION_CHECK=1

COPY ${APP_DIR}/backend/requirements.txt /tmp/requirements.txt
#RUN python -m pip wheel --wheel-dir=/wheels -r /tmp/requirements.txt

FROM python:3.12-slim-bookworm AS runtime

ARG APP_DIR=.

ARG VIDEO_BENCH_EXPERIMENTAL=false

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DJANGO_SETTINGS_MODULE=video_bench_backend.settings \
    DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1 \
    DJANGO_DB_PATH=/data/db.sqlite3 \
    VIDEO_BENCH_MOUNTED_FILES_ROOT=/mounted-input \
    VIDEO_BENCH_IMPACT_CYCLE_ROOT=/data/impact-cycle \
    GUNICORN_BIND=127.0.0.1:8000 \
    GUNICORN_WORKERS=2 \
    GUNICORN_THREADS=2 \
    GUNICORN_TIMEOUT=120 \
    VIDEO_BENCH_EXPERIMENTAL=${VIDEO_BENCH_EXPERIMENTAL}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    nginx \
    wget \
    && rm -f /etc/nginx/sites-enabled/default \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /usr/sbin/nologin --uid 10001 app

WORKDIR /app/backend

#COPY --from=python-builder /wheels /wheels
COPY ${APP_DIR}/backend/requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,id=video-bench-pip-cache,target=/root/.cache/pip,sharing=locked \
    --mount=type=cache,id=video-bench-python-wheels,target=/wheels,sharing=locked \
    torch_url=$(python -c 'import json, urllib.request; data = json.load(urllib.request.urlopen("https://pypi.org/pypi/torch/2.5.1/json", timeout=30)); print(next(item["url"] for item in data["urls"] if item["filename"] == "torch-2.5.1-cp312-cp312-manylinux2014_aarch64.whl"))') \
    && downloaded=0; for attempt in 1 2 3 4 5 6 7 8 9 10; do \
        if wget --continue --timeout=30 --tries=1 --output-document=/wheels/torch-2.5.1-cp312-cp312-manylinux2014_aarch64.whl "$torch_url"; then downloaded=1; break; fi; \
        echo "Torch wheel download failed (attempt ${attempt}/10); retrying..."; \
        sleep 5; \
    done; test "$downloaded" -eq 1 \
    && for attempt in 1 2 3 4 5; do \
        python -m pip install /wheels/torch-2.5.1-cp312-cp312-manylinux2014_aarch64.whl \
        && grep -v '^torch==' /tmp/requirements.txt > /tmp/requirements-without-torch.txt \
        && python -m pip install --timeout=120 --retries=5 -r /tmp/requirements-without-torch.txt && exit 0; \
        echo "Python dependency download failed (attempt ${attempt}/5); retrying..."; \
        sleep 5; \
    done; \
    exit 1
# \   && rm -rf /wheels /tmp/requirements.txt

COPY ${APP_DIR}/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY ${APP_DIR}/docker/docker-entrypoint.d/40-video-bench-debug-config.sh /docker-entrypoint.d/40-video-bench-debug-config.sh
COPY ${APP_DIR}/docker/entrypoint.sh /entrypoint.sh
COPY --chown=app:app ${APP_DIR}/backend/manage.py /app/backend/manage.py
COPY --chown=app:app ${APP_DIR}/backend/video_bench_backend /app/backend/video_bench_backend
COPY --from=flutter-builder /app/frontend/build/web /usr/share/nginx/html
RUN mkdir -p /data /data/impact-cycle \
    && chown -R app:app /data /app/backend \
    && chmod +x /docker-entrypoint.d/40-video-bench-debug-config.sh /entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/api/health/ >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]

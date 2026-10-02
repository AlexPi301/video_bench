# Production image, but includes impact_cycle dependencies so impact_cycle backend can run properly.
# syntax=docker/dockerfile:1.7

ARG DEBIAN_FRONTEND=noninteractive
ARG APP_DIR=.

FROM ubuntu:22.04 AS flutter-builder

ARG DEBIAN_FRONTEND
ARG APP_DIR=.
ARG FLUTTER_VERSION=3.38.8
ARG VIDEO_BENCH_EXPERIMENTAL=false

ENV FLUTTER_HOME=/opt/flutter \
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

RUN flutter config --enable-web \
    && flutter doctor -v

WORKDIR /app/frontend

COPY ${APP_DIR}/frontend/pubspec.yaml ./
RUN flutter pub get

COPY ${APP_DIR}/frontend ./
RUN flutter build web --release --base-href / --dart-define=VIDEO_BENCH_EXPERIMENTAL=${VIDEO_BENCH_EXPERIMENTAL}

FROM python:3.12-slim-bookworm AS python-builder

ARG APP_DIR=.

ENV PIP_DISABLE_PIP_VERSION_CHECK=1

COPY ${APP_DIR}/backend/requirements.txt /tmp/requirements.txt
RUN python -m pip wheel --wheel-dir=/wheels -r /tmp/requirements.txt

FROM python:3.12-slim-bookworm AS runtime

ARG APP_DIR=.

ARG VIDEO_BENCH_EXPERIMENTAL=false

LABEL org.opencontainers.image.licenses="MIT"

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

COPY --from=python-builder /wheels /wheels
COPY ${APP_DIR}/backend/requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir --no-index --find-links=/wheels -r /tmp/requirements.txt \
    && rm -rf /wheels /tmp/requirements.txt

COPY ${APP_DIR}/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY ${APP_DIR}/LICENSE /usr/share/doc/video-bench/LICENSE
COPY ${APP_DIR}/docker/docker-entrypoint.d/40-video-bench-debug-config.sh /docker-entrypoint.d/40-video-bench-debug-config.sh
COPY ${APP_DIR}/docker/entrypoint.sh /entrypoint.sh
COPY --chown=app:app ${APP_DIR}/backend/manage.py /app/backend/manage.py
COPY --chown=app:app ${APP_DIR}/backend/video_bench_backend /app/backend/video_bench_backend
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/configs /app/backend/IMPACT_CYCLE/configs
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/core /app/backend/IMPACT_CYCLE/core
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/tools /app/backend/IMPACT_CYCLE/tools
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/utils /app/backend/IMPACT_CYCLE/utils
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/tmp/sg_prompts_dump.txt /app/backend/IMPACT_CYCLE/tmp/sg_prompts_dump.txt
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/feature_defaults.json /app/backend/IMPACT_CYCLE/feature_defaults.json
COPY --chown=app:app ${APP_DIR}/backend/IMPACT_CYCLE/runner_envs.json /app/backend/IMPACT_CYCLE/runner_envs.json
COPY --from=flutter-builder /app/frontend/build/web /usr/share/nginx/html
RUN mkdir -p /data /data/impact-cycle \
    && chown -R app:app /data /app/backend \
    && chmod +x /docker-entrypoint.d/40-video-bench-debug-config.sh /entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]

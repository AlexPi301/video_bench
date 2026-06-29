"""Minimal Django settings for the Video Bench backend."""

from __future__ import annotations

import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get(
    "DJANGO_SECRET_KEY",
    "django-insecure-video-bench-local-development-key",
)

DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"

allowed_hosts = os.environ.get("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1")
ALLOWED_HOSTS = [host.strip() for host in allowed_hosts.split(",") if host.strip()]

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "video_bench_backend.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    }
]

WSGI_APPLICATION = "video_bench_backend.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": os.environ.get("DJANGO_DB_PATH", str(BASE_DIR / "db.sqlite3")),
    }
}

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

VIDEO_BENCH_MOUNTED_FILES_ROOT = os.environ.get("VIDEO_BENCH_MOUNTED_FILES_ROOT", "/mounted-input")
VIDEO_BENCH_IMPACT_CYCLE_ROOT = os.environ.get("VIDEO_BENCH_IMPACT_CYCLE_ROOT", "/data/impact-cycle")
DATA_UPLOAD_MAX_MEMORY_SIZE = int(os.environ.get("DJANGO_DATA_UPLOAD_MAX_MEMORY_SIZE", str(512 * 1024 * 1024)))
FILE_UPLOAD_MAX_MEMORY_SIZE = int(os.environ.get("DJANGO_FILE_UPLOAD_MAX_MEMORY_SIZE", str(32 * 1024 * 1024)))

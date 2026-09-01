"""WSGI config for the Video Bench backend."""

import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "video_bench_backend.settings")

from .benchmarks import pause_running_benchmark_runs_on_startup

application = get_wsgi_application()

pause_running_benchmark_runs_on_startup()

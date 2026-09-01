"""ASGI config for the Video Bench backend."""

import os

from django.core.asgi import get_asgi_application


os.environ.setdefault("DJANGO_SETTINGS_MODULE", "video_bench_backend.settings")

from .benchmarks import pause_running_benchmark_runs_on_startup

application = get_asgi_application()

pause_running_benchmark_runs_on_startup()

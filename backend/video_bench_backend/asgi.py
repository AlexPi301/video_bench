"""ASGI config for the Video Bench backend."""

import os

from django.core.asgi import get_asgi_application


os.environ.setdefault("DJANGO_SETTINGS_MODULE", "video_bench_backend.settings")

application = get_asgi_application()

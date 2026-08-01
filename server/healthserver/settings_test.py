"""Test settings: SQLite, so the suite runs without a database server.

The ingest path uses ON CONFLICT DO UPDATE, which SQLite supports, so the
behaviour under test is the same. Anything Postgres-specific is exercised by
running the suite against the real container instead:

    docker compose exec web python manage.py test tests
"""

import os

os.environ.setdefault("DJANGO_SECRET_KEY", "test-only-not-a-secret")
os.environ.setdefault("POSTGRES_PASSWORD", "test-only")

from .settings import *  # noqa: F403,E402

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}

STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}

ALLOWED_HOSTS = ["*"]
LOGGING["root"]["level"] = "CRITICAL"  # noqa: F405

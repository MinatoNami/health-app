FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# libpq is needed even with psycopg[binary] for the occasional pg_* client tool,
# and curl is what the container healthcheck uses.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# ManifestStaticFilesStorage hashes files at collect time, so this has to run
# during the build. The key is throwaway: nothing it protects is written here.
RUN DJANGO_SECRET_KEY=build-only-not-a-secret \
    POSTGRES_PASSWORD=build-only \
    python manage.py collectstatic --noinput

RUN useradd --create-home --uid 10001 app && chown -R app:app /app
USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/healthz || exit 1

# Two workers is plenty for one phone, and each holds a database connection.
# The 180s timeout is sized for a first-sync batch of 5,000 records; the
# default 30s would kill a legitimate backfill upload mid-write.
CMD ["gunicorn", "healthserver.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2", \
     "--timeout", "180", \
     "--graceful-timeout", "30", \
     "--max-requests", "500", \
     "--max-requests-jitter", "50", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]

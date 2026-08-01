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

# Four workers, not two: a CSV export holds one worker for the whole download
# (measured 47s for 1.29M rows), so with two, a single export plus one slow
# upload leaves nothing for the phone.
#
# The 900s timeout is sized for the export, not the upload. gunicorn kills a
# worker that exceeds it even while it is actively streaming, and the failure
# mode is nasty: the client has already received a 200 and a partial body, so a
# truncated CSV looks exactly like a complete one. At ~47s per 334MB today,
# this leaves room for the archive to grow roughly 15x.
CMD ["gunicorn", "healthserver.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--timeout", "900", \
     "--graceful-timeout", "30", \
     "--max-requests", "500", \
     "--max-requests-jitter", "50", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]

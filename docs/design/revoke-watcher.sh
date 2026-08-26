S="$1"
rm -f "$S/revoke.marker"
for i in $(seq 1 900); do
  if [ -f "$S/revoke.marker" ]; then
    cd /Users/lionelchong/git-repos/health-app/server
    DEMO_DB_PATH="$S/demo.sqlite3" PYTHONPATH="$S:$PWD" DJANGO_SETTINGS_MODULE=demo_settings \
      .venv/bin/python -c "
import django, os
django.setup()
from django.utils import timezone
from ingest.models import ApiToken
n = ApiToken.objects.filter(revoked_at__isnull=True).update(revoked_at=timezone.now())
print('revoked', n)
" >> "$S/revoke.log" 2>&1
    rm -f "$S/revoke.marker"
    exit 0
  fi
  sleep 1
done

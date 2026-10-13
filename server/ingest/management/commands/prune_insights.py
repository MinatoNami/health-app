"""Enforce question-and-answer retention on a schedule.

`InsightTurn.prune()` used to run only when someone asked a new question. That
made retention depend on use: stop asking for two months and every turn older
than `INSIGHT_RETENTION_DAYS` stayed in the database, and in every nightly
backup taken meanwhile — while docs/PRIVACY.md promised "then deleted". Run
daily from the cron `deploy.sh` installs, so the promise holds whether or not
anyone is chatting.
"""

from django.core.management.base import BaseCommand

from ingest.models import InsightTurn


class Command(BaseCommand):
    help = "Delete questions and answers older than INSIGHT_RETENTION_DAYS."

    def handle(self, *args, **options):
        deleted = InsightTurn.prune()
        self.stdout.write(
            f"Deleted {deleted} expired turn(s) "
            f"(retention {InsightTurn.retention_days()} days)."
        )

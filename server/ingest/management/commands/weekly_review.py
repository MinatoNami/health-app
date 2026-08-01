"""Generate the weekly review on a schedule.

§10 phase 4 asks for proactive insights rather than only answers on demand. The
constraint that shapes this: the model runs on a laptop, and a laptop is asleep
at 08:00 on a Monday more often than not. So a scheduled run that cannot reach
the model does not fail — it records nothing, logs why, and the next run picks it
up. A cron job that emails a stack trace every week is one people disable.
"""

import logging

from django.core.management.base import BaseCommand

from ingest.llm import client, service
from ingest.models import InsightTurn

log = logging.getLogger(__name__)


class Command(BaseCommand):
    help = "Generate and store the weekly health review."

    def add_arguments(self, parser):
        parser.add_argument("--tz", default=None)
        parser.add_argument(
            "--skip-if-unreachable",
            action="store_true",
            help="Exit 0 without generating when the model server is asleep. For cron.",
        )

    def handle(self, *args, **options):
        if options["skip_if_unreachable"]:
            status = client.status()
            if not status.get("reachable"):
                # Deliberately not an error: the model lives on a laptop, and
                # "the laptop is shut" is the normal case, not a fault.
                self.stdout.write(
                    f"Model server unreachable ({status.get('detail')}); skipping this week."
                )
                return

        result = service.weekly_review(tz_name=options["tz"])

        if result.get("answer"):
            self.stdout.write(self.style.SUCCESS(result["answer"]["summary"]))
            self.stdout.write(
                f"\nStored as insight #{InsightTurn.objects.first().pk}. "
                "Open the dashboard's Insights tab to read it in full."
            )
        else:
            self.stdout.write(self.style.WARNING(result.get("error") or "No answer produced."))

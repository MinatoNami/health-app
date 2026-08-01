"""Nightly check for signals that have stopped arriving.

Run from cron by `deploy.sh`. Exits 0 even when metrics are stale — a stale
metric is a finding, not a failure of the check, and a non-zero exit would fill
the cron log with mail about a working script.
"""

import json

from django.core.management.base import BaseCommand

from ingest import freshness


class Command(BaseCommand):
    help = "Report health metrics that have stopped syncing."

    def add_arguments(self, parser):
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Report without sending anything or recording state.",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help="Send even if this metric was reported recently. For testing the webhook.",
        )
        parser.add_argument("--json", action="store_true", help="Machine-readable output.")
        parser.add_argument("--tz", default=None, help="Timezone for day boundaries.")

    def handle(self, *args, **options):
        result = freshness.run(
            tz_name=options["tz"],
            force=options["force"],
            dry_run=options["dry_run"],
        )

        if options["json"]:
            self.stdout.write(json.dumps(result, indent=2))
            return

        if not result["stale"]:
            self.stdout.write(self.style.SUCCESS("Every tracked metric is up to date."))
        else:
            self.stdout.write(self.style.WARNING(f"{len(result['stale'])} metric(s) not syncing:"))
            for line in result["stale"]:
                self.stdout.write(f"  {line}")

        for line in result["recovered"]:
            self.stdout.write(self.style.SUCCESS(f"  recovered: {line}"))

        if not result["webhook_configured"]:
            self.stdout.write(
                "\nNo ALERT_WEBHOOK_URL is set, so nothing was pushed anywhere. "
                "Set one with ./deploy.sh alerts <url> — otherwise this only "
                "reports when someone runs it, which is the problem it exists to solve."
            )
        elif result["reported"] and not result["notified"] and not result["dry_run"]:
            self.stdout.write(self.style.ERROR("Webhook delivery failed; see the log."))

"""Permanent deletion of everything derived from HealthKit.

§8 of docs/healthkit_llm_integration_instructions.md asks for a real deletion
path, and "real" is the operative word: a delete that leaves the data recoverable
from somewhere the user was not told about is not a delete.

Deliberately a management command rather than an API endpoint. This is
irreversible and there is no undo, so it should require shell access to the
server rather than a session cookie and a mis-click. It also prints exactly what
it will destroy, and what it will *not* — the backups, which are the thing
people forget.
"""

from django.core.management.base import BaseCommand
from django.db import transaction

from ingest.models import (
    AlertState,
    Batch,
    ChatProject,
    ChatSession,
    Device,
    Goal,
    InsightTurn,
    Record,
)


class Command(BaseCommand):
    help = "Permanently delete all health records, batches, goals and stored questions."

    def add_arguments(self, parser):
        parser.add_argument(
            "--confirm",
            action="store_true",
            help="Required. Without it this only reports what would be deleted.",
        )
        parser.add_argument(
            "--keep-devices",
            action="store_true",
            help="Keep device registrations, so a re-sync does not appear as a new phone.",
        )

    def handle(self, *args, **options):
        counts = {
            "records": Record.objects.count(),
            "batches": Batch.objects.count(),
            "goals": Goal.objects.count(),
            "stored questions": InsightTurn.objects.count(),
            "chats": ChatSession.objects.count(),
            "chat projects": ChatProject.objects.count(),
            "alerts": AlertState.objects.count(),
            "devices": Device.objects.count(),
        }

        self.stdout.write("This will permanently delete:")
        for name, count in counts.items():
            if name == "devices" and options["keep_devices"]:
                self.stdout.write(f"  {count:>10,}  {name}  (kept)")
                continue
            self.stdout.write(f"  {count:>10,}  {name}")

        if not options["confirm"]:
            self.stdout.write(
                self.style.WARNING("\nNothing deleted. Re-run with --confirm to proceed.")
            )
            return

        with transaction.atomic():
            # Records first: they reference batches and devices, and deleting
            # the parents first would cascade through millions of rows one
            # object at a time.
            Record.objects.all().delete()
            Batch.objects.all().delete()
            Goal.objects.all().delete()
            InsightTurn.objects.all().delete()
            # After the turns, so the cascade has nothing left to walk.
            ChatSession.objects.all().delete()
            ChatProject.objects.all().delete()
            AlertState.objects.all().delete()
            if not options["keep_devices"]:
                Device.objects.all().delete()

        self.stdout.write(self.style.SUCCESS("\nDeleted."))
        # The omission people discover later, at the worst possible moment.
        self.stdout.write(
            "\nNot touched: nightly backups in /var/backups/health, any copies pulled\n"
            "to your laptop by ./deploy.sh backup-pull, and the data still in Apple\n"
            "Health on the phone. A restore or a re-sync brings all of it back.\n"
            "\nTo finish the job:\n"
            "  ssh <host> 'sudo rm -f /var/backups/health/health-*.sql.gz*'\n"
            "  rm -rf ~/health-backups\n"
            "  and reset the sync cursors in the app (Settings → Diagnostics), or it\n"
            "  will simply upload everything again on the next run."
        )

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
from ingest.models import ChatProject, ChatSession, InsightTurn

log = logging.getLogger(__name__)

PROJECT_NAME = "Weekly reviews"


def _session(tz_name: str | None) -> ChatSession:
    """A chat for this week's review, filed with the others.

    One session per run rather than one long-running chat: each review is about
    a different week and reads as its own thing, and appending them all to a
    single conversation would mean the model replaying last month's review as
    context for this one.

    They go in a project so a year of them is one collapsible row in the sidebar
    instead of fifty-two loose entries burying every real conversation. The
    project deliberately carries no standing instructions — a review is
    generated from the snapshot, and giving it its own prompt context would make
    it quietly different from the same review asked for by hand.
    """
    project, _ = ChatProject.objects.get_or_create(
        name=PROJECT_NAME,
        defaults={"instructions": ""},
    )
    week = service.health_analysis.last_complete_day(tz_name)
    return ChatSession.objects.create(
        project=project,
        title=f"Weekly review — week ending {week:%-d %B %Y}",
        # Named on purpose, so the first-question autotitle does not overwrite
        # it with the empty question a review is asked with.
        title_locked=True,
    )


class Command(BaseCommand):
    help = "Generate and store the weekly health review."

    def add_arguments(self, parser):
        parser.add_argument("--tz", default=None)
        parser.add_argument(
            "--skip-if-unreachable",
            action="store_true",
            help="Exit 0 without generating when the model server is asleep. For cron.",
        )
        parser.add_argument(
            "--no-session",
            action="store_true",
            help="Store the turn without opening a chat for it, as this command "
            "did before the dashboard had a sidebar.",
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

        session = None if options["no_session"] else _session(options["tz"])
        result = service.weekly_review(tz_name=options["tz"], session=session)

        # A review that produced nothing must not leave a chat behind. Unlike a
        # question somebody typed — where a failure is worth seeing, because
        # they are standing there waiting for it — this runs unattended every
        # Monday, and the laptop being shut is the normal case rather than a
        # fault. A year of chats containing only "the model was unreachable" is
        # the sidebar equivalent of the weekly stack-trace email this command
        # was written to avoid.
        #
        # The turn itself survives, unfiled: the attempt is still worth a record
        # in the export, it just is not a conversation.
        if session is not None and not result.get("answer"):
            session.turns.update(session=None)
            session.delete()
            session = None

        if result.get("answer"):
            self.stdout.write(self.style.SUCCESS(result["answer"]["summary"]))
            where = (
                f"in “{session.title}”" if session else f"as insight #{InsightTurn.objects.first().pk}"
            )
            self.stdout.write(
                f"\nStored {where}. Open the dashboard's Insights tab to read it in full."
            )
        else:
            self.stdout.write(self.style.WARNING(result.get("error") or "No answer produced."))

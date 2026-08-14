"""Run the golden set against the live model and report what broke.

The loop this closes: a prompt edit lands, this runs, and the failures name
themselves. Without it, "did that help?" is answered by asking two or three
questions by hand and forming an impression — which is how the August export
ended up with a prompt that answered "how about my sleep on 14th August?" with
the previous week's average for a fortnight without anyone noticing.

Nothing is written. Every case runs with `persist=False`, so a run does not
appear in anybody's chat history, does not age out under retention, and does not
land in `/v1/chat/feedback` beside answers a person actually asked for.

    python manage.py eval_answers                     # every case, judged
    python manage.py eval_answers --no-judge          # arithmetic only, no model grading
    python manage.py eval_answers --tag sleep         # one slice
    python manage.py eval_answers --case eaten-today  # one case
    python manage.py eval_answers --out before.json   # keep it, to diff after an edit
    python manage.py eval_answers --compare before.json
"""

import json
import time

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from ingest.llm import golden, judge, prompts, service
from ingest.models import ChatSession


class Command(BaseCommand):
    help = "Run the golden question set and report relevance failures."

    def add_arguments(self, parser):
        parser.add_argument("--tag", help="Only cases carrying this tag.")
        parser.add_argument("--case", help="Only this case id.")
        parser.add_argument("--tz", default=None, help="Timezone to resolve dates against.")
        parser.add_argument(
            "--no-judge",
            action="store_true",
            help="Skip model grading. Runs the arithmetic checks alone — fast, and "
            "useful when the judge is the thing that is unavailable.",
        )
        parser.add_argument(
            "--judge-model",
            default=None,
            help="Grade with a different model than the one that answered. Worth "
            "doing: a model grading its own work grades generously.",
        )
        parser.add_argument("--out", help="Write the full run to this path as JSON.")
        parser.add_argument(
            "--compare",
            help="An earlier --out file. Reports which cases changed verdict since.",
        )

    def handle(self, *args, **options):
        cases = golden.CASES
        if options["tag"]:
            cases = golden.by_tag(options["tag"])
        if options["case"]:
            case = golden.by_id(options["case"])
            if case is None:
                raise CommandError(f"no case with id {options['case']!r}")
            cases = [case]
        if not cases:
            raise CommandError("no cases matched")

        self.stdout.write(
            f"Running {len(cases)} case(s) against prompt version {prompts.VERSION}.\n"
        )

        started = time.monotonic()
        rows = []
        for index, case in enumerate(cases, start=1):
            self.stdout.write(f"[{index}/{len(cases)}] {case['id']} … ", ending="")
            self.stdout.flush()
            rows.append(self._run_case(case, options))
            self.stdout.write(self._verdict_label(rows[-1]))

        elapsed = time.monotonic() - started
        self._report(rows, elapsed)

        run = {
            "prompt_version": prompts.VERSION,
            "cases": rows,
            "elapsed_seconds": round(elapsed, 1),
        }
        if options["out"]:
            with open(options["out"], "w") as handle:
                json.dump(run, handle, indent=2, default=str)
            self.stdout.write(f"\nWrote {options['out']}")
        if options["compare"]:
            self._compare(options["compare"], run)

    # ------------------------------------------------------------------ running

    @staticmethod
    def _ask(case: dict, tz_name: str | None) -> dict:
        """Ask the case's question, with its earlier turns if it has any.

        A case with no `prior` never touches the database. One with `prior` has
        to: a session replays its earlier turns by reading them back, so they
        have to exist while the follow-up is asked. They are written inside a
        transaction that is always rolled back, so the conversation exists for
        the length of the case and leaves nothing behind — no session in anybody's
        sidebar, and no evaluation runs mixed into `/v1/chat/feedback` beside
        answers a person actually asked for.
        """
        prior = case.get("prior") or []
        if not prior:
            return service.answer(case["question"], persist=False, tz_name=tz_name)

        with transaction.atomic():
            try:
                session = ChatSession.objects.create(title=f"eval:{case['id']}")
                for question in prior:
                    service.answer(
                        question, persist=True, tz_name=tz_name, session=session
                    )
                return service.answer(
                    case["question"], persist=True, tz_name=tz_name, session=session
                )
            finally:
                transaction.set_rollback(True)

    def _run_case(self, case: dict, options: dict) -> dict:
        started = time.monotonic()
        try:
            payload = self._ask(case, options["tz"])
        except Exception as exc:  # noqa: BLE001 — one bad case must not end the run
            return {
                "id": case["id"],
                "tags": case["tags"],
                "question": case["question"],
                "crashed": f"{type(exc).__name__}: {exc}",
                "failures": [f"raised {type(exc).__name__}: {exc}"],
                "grade": None,
                "seconds": round(time.monotonic() - started, 1),
            }

        failures = golden.check(case, payload)
        grade = None
        if not options["no_judge"]:
            grade = judge.grade(
                payload, rubric=case.get("rubric", ""), model=options["judge_model"]
            )

        answer = payload.get("answer") or {}
        return {
            "id": case["id"],
            "tags": case["tags"],
            "question": case["question"],
            "asked_for": answer.get("asked_for"),
            "period_examined": answer.get("period_examined"),
            "summary": answer.get("summary"),
            "observations": len(answer.get("observations") or []),
            "actions": len(answer.get("actions") or []),
            "tools": [call.get("tool") for call in (payload.get("tool_calls") or [])],
            "generated": bool(payload.get("generated")),
            "error": payload.get("error"),
            "failures": failures,
            "grade": grade,
            "seconds": round(time.monotonic() - started, 1),
        }

    # ---------------------------------------------------------------- reporting

    @staticmethod
    def _passed(row: dict) -> bool:
        """A case passes when the arithmetic holds and the judge did not object.

        An ungraded row — the judge was off or unreachable — passes on the
        arithmetic alone rather than being counted as a failure. A missing judge
        is a gap in the evidence, not evidence of a problem.
        """
        if row["failures"]:
            return False
        grade = row.get("grade")
        if not grade or grade.get("relevant") is None:
            return True
        return bool(grade["relevant"] and grade["scope_ok"] and grade["grounded"])

    def _verdict_label(self, row: dict) -> str:
        if self._passed(row):
            grade = row.get("grade") or {}
            score = f" {grade['score']}/3" if grade.get("score") is not None else ""
            return self.style.SUCCESS(f"pass{score} ({row['seconds']}s)")
        return self.style.ERROR(f"FAIL ({row['seconds']}s)")

    def _report(self, rows: list[dict], elapsed: float):
        failed = [row for row in rows if not self._passed(row)]
        self.stdout.write("")
        self.stdout.write("=" * 78)
        self.stdout.write(
            f"{len(rows) - len(failed)}/{len(rows)} passed in {elapsed:.0f}s"
        )

        graded = [r["grade"]["score"] for r in rows if (r.get("grade") or {}).get("score") is not None]
        if graded:
            self.stdout.write(f"mean relevance score: {sum(graded) / len(graded):.2f}/3")

        if not failed:
            self.stdout.write(self.style.SUCCESS("Nothing to fix."))
            return

        self.stdout.write("")
        for row in failed:
            self.stdout.write(self.style.ERROR(f"FAIL  {row['id']}"))
            self.stdout.write(f"  asked      : {row['question']!r}")
            if row.get("asked_for"):
                self.stdout.write(f"  asked_for  : {row['asked_for']}")
            if row.get("period_examined"):
                self.stdout.write(f"  period     : {row['period_examined']}")
            self.stdout.write(f"  tools      : {row.get('tools')}")
            for failure in row["failures"]:
                self.stdout.write(self.style.WARNING(f"  check      : {failure}"))
            grade = row.get("grade") or {}
            if grade.get("reason"):
                flags = [
                    name
                    for name in ("relevant", "scope_ok", "grounded")
                    if grade.get(name) is False
                ]
                self.stdout.write(
                    self.style.WARNING(f"  judge      : failed {', '.join(flags) or 'nothing'}")
                )
                self.stdout.write(f"               {grade['reason']}")
            if row.get("summary"):
                self.stdout.write(f"  said       : {row['summary'][:300]}")
            self.stdout.write("")

    def _compare(self, path: str, run: dict):
        try:
            with open(path) as handle:
                before = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise CommandError(f"could not read {path}: {exc}") from exc

        was = {row["id"]: self._passed(row) for row in before.get("cases", [])}
        now = {row["id"]: self._passed(row) for row in run["cases"]}

        fixed = sorted(i for i in now if now[i] and was.get(i) is False)
        broken = sorted(i for i in now if not now[i] and was.get(i) is True)

        self.stdout.write("")
        self.stdout.write(
            f"Against {path} (prompt version {before.get('prompt_version')} "
            f"→ {run['prompt_version']}):"
        )
        for case_id in fixed:
            self.stdout.write(self.style.SUCCESS(f"  fixed   {case_id}"))
        for case_id in broken:
            self.stdout.write(self.style.ERROR(f"  BROKE   {case_id}"))
        if not fixed and not broken:
            self.stdout.write("  no case changed verdict")

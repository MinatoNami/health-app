"""Tests for the golden set's own checker.

The evaluation harness is the thing that tells you whether a prompt edit helped,
which makes a bug in it worse than a bug in the prompt: a checker that passes
everything reports success forever and the failures it was built to catch go back
to shipping unseen. So the arithmetic half is tested here against hand-written
answers, with no model involved anywhere.

The judge is not tested. It reads prose and returns an opinion, and pinning an
opinion in an assertion would be testing the local model rather than this code.
"""

from django.test import TestCase

from ingest.llm import golden

PASSING = {
    "asked_for": "sleep on the night of 2026-08-12",
    "summary": "You slept 0.23 hours on the night of 12 August.",
    "period_examined": "2026-08-12",
    "observations": [
        {
            "statement": "The night of 12 August was unusually short.",
            "evidence": "0.23 hours, bedtime 23:40, wake time 23:54, night_of 2026-08-12.",
            "confidence": "high",
        }
    ],
    "actions": [],
    "limitations": ["Only 4 of 7 nights were recorded."],
    "confidence": "low",
    "professional_review_recommended": False,
}


def payload(answer=PASSING, **fields):
    base = {
        "question": "Tell me about my sleep last night",
        "answer": answer,
        "generated": True,
        "source": "model",
        "model": {"name": "test-model"},
        "tool_calls": [],
        "error": None,
    }
    base.update(fields)
    return base


class GoldenCheckTests(TestCase):
    def test_a_good_answer_has_no_arithmetic_failures(self):
        case = {"id": "x", "tags": [], "expect": {}}
        self.assertEqual(golden.check(case, payload()), [])

    def test_evidence_that_restates_the_statement_is_caught(self):
        """The regression seen on turns 28 and 33 of the August export."""
        answer = {
            **PASSING,
            "observations": [
                {
                    "statement": "Sleep averaged 3.56 hours over the past week.",
                    "evidence": "Sleep averaged 3.56 hours over the past week.",
                    "confidence": "low",
                }
            ],
        }
        failures = golden.check({"id": "x", "tags": [], "expect": {}}, payload(answer))
        self.assertTrue(any("restates itself" in f for f in failures), failures)

    def test_evidence_that_merely_opens_with_the_statement_is_caught(self):
        answer = {
            **PASSING,
            "observations": [
                {
                    "statement": "Your sleep schedule was highly variable, with a typical "
                    "bedtime of 02:19 and wake time of 11:58.",
                    "evidence": "Your sleep schedule was highly variable, with a typical "
                    "bedtime of 02:19 and wake time of 11:58, and a 150-minute spread.",
                    "confidence": "low",
                }
            ],
        }
        failures = golden.check({"id": "x", "tags": [], "expect": {}}, payload(answer))
        self.assertTrue(any("restates itself" in f for f in failures), failures)

    def test_markdown_in_the_summary_is_caught(self):
        answer = {**PASSING, "summary": "**Sleep:** you slept 0.23 hours."}
        failures = golden.check({"id": "x", "tags": [], "expect": {}}, payload(answer))
        self.assertTrue(any("markdown" in f for f in failures), failures)

    def test_a_greeting_answered_with_a_report_fails(self):
        case = {"id": "greeting", "tags": [], "expect": {"max_observations": 0, "max_actions": 0}}
        failures = golden.check(case, payload())
        self.assertTrue(any("observations" in f for f in failures), failures)

    def test_a_greeting_answered_with_one_sentence_passes(self):
        answer = {
            **PASSING,
            "summary": "I'm well, thanks. What would you like to know?",
            "observations": [],
            "actions": [],
        }
        case = {"id": "greeting", "tags": [], "expect": {"max_observations": 0, "max_actions": 0}}
        self.assertEqual(golden.check(case, payload(answer)), [])

    def test_the_model_being_consulted_about_a_symptom_fails(self):
        case = {
            "id": "chest-pain",
            "tags": [],
            "expect": {"source": "safety_rules", "model_is_none": True, "generated": False},
        }
        failures = golden.check(case, payload())
        self.assertTrue(any("safety rules" in f for f in failures), failures)
        self.assertTrue(any("source" in f for f in failures), failures)

    def test_the_safety_short_circuit_passes_its_case(self):
        answer = {
            **PASSING,
            "summary": "Contact urgent care now.",
            "observations": [],
            "actions": [],
        }
        case = {
            "id": "chest-pain",
            "tags": [],
            "expect": {
                "source": "safety_rules",
                "model_is_none": True,
                "generated": False,
                "mentions_any": ["urgent", "emergency"],
            },
        }
        result = payload(answer, source="safety_rules", model=None, generated=False)
        self.assertEqual(golden.check(case, result), [])

    def test_mentions_any_needs_only_one_of_the_words(self):
        case = {"id": "x", "tags": [], "expect": {"mentions_any": ["nothing", "0.23 hours"]}}
        self.assertEqual(golden.check(case, payload()), [])

    def test_mentions_any_fails_when_none_appear(self):
        case = {"id": "x", "tags": [], "expect": {"mentions_any": ["blood pressure"]}}
        self.assertTrue(golden.check(case, payload()))

    def test_forbidden_words_are_caught_anywhere_in_the_answer(self):
        """Not just the summary — a calorie target buried in a suggestion still shipped."""
        answer = {
            **PASSING,
            "actions": [
                {"action": "Aim for 2,000 kcal a day.", "reason": "x", "timeframe": "a week"}
            ],
        }
        case = {"id": "x", "tags": [], "expect": {"forbids_any": ["aim for"]}}
        failures = golden.check(case, payload(answer))
        self.assertTrue(any("aim for" in f for f in failures), failures)

    def test_repeating_an_earlier_answer_is_caught(self):
        """The live regression: after several turns on one subject, every message
        came back with the previous answer word for word."""
        case = {"id": "greeting-mid-chat", "tags": [], "expect": {}}
        failures = golden.check(case, payload(), (PASSING["summary"],))
        self.assertTrue(any("word for word" in f for f in failures), failures)

    def test_a_differently_worded_answer_is_not_a_repeat(self):
        case = {"id": "x", "tags": [], "expect": {}}
        self.assertEqual(golden.check(case, payload(), ("Something else entirely.",)), [])

    def test_the_repeat_check_ignores_case_and_spacing(self):
        case = {"id": "x", "tags": [], "expect": {}}
        earlier = f"  {PASSING['summary'].upper()}  "
        self.assertTrue(golden.check(case, payload(), (earlier,)))

    def test_a_missing_answer_is_reported_as_a_failure(self):
        case = {"id": "x", "tags": [], "expect": {}}
        failures = golden.check(case, payload(None, error="model unreachable"))
        self.assertTrue(any("model unreachable" in f for f in failures), failures)

    def test_a_missing_answer_is_fine_where_none_was_expected(self):
        case = {"id": "x", "tags": [], "expect": {"generated": False}}
        result = payload(None, error="blocked", generated=False)
        self.assertEqual(golden.check(case, result), [])


class GoldenSetTests(TestCase):
    def test_every_case_is_well_formed(self):
        for case in golden.CASES:
            self.assertTrue(case["id"], case)
            self.assertIn("question", case)
            self.assertTrue(case["tags"], f"{case['id']} carries no tags")
            self.assertTrue(case.get("rubric"), f"{case['id']} has no rubric for the judge")
            self.assertIsInstance(case.get("expect", {}), dict)

    def test_case_ids_are_unique(self):
        ids = [case["id"] for case in golden.CASES]
        self.assertEqual(len(ids), len(set(ids)))

    def test_the_set_covers_the_failures_the_august_export_showed(self):
        """Each of these was a real, observed failure. Losing its case loses the guard."""
        for case_id in (
            "greeting",
            "empty-question",
            "challenge-previous",
            "sleep-last-night",
            "sleep-named-date",
            "eaten-today",
        ):
            self.assertIsNotNone(golden.by_id(case_id), f"{case_id} went missing")

    def test_lookup_by_tag(self):
        self.assertTrue(golden.by_tag("sleep"))
        self.assertEqual(golden.by_tag("no-such-tag"), [])

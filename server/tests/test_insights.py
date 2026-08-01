"""Tests for the safety layer and the controlled LLM path.

The model is faked throughout. What is being tested is not whether a language
model writes well — it is that the rules around it hold whatever it writes: the
model is never consulted about an emergency, a prohibited claim never reaches
the screen, and an unreachable model server degrades to the measured numbers
rather than to an error page.
"""

import json
from datetime import date, datetime, time, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.contrib.auth.models import User
from django.core.cache import cache
from django.test import TestCase

from ingest import health_analysis, safety
from ingest.llm import client as llm_client
from ingest.llm import service as llm_service
from ingest.llm import tools as llm_tools
from ingest.models import ApiToken, Batch, Device, InsightTurn, Record

SGT = ZoneInfo("Asia/Singapore")

GOOD_INSIGHT = {
    "summary": "Your step count was 12% above your recent baseline this week.",
    "period_examined": "last 7 days against the 28 before",
    "observations": [
        {
            "statement": "Steps were higher than baseline.",
            "evidence": "11,200 per day over 7 days against 10,000 over the prior 28 days.",
            "confidence": "high",
        }
    ],
    "actions": [
        {
            "action": "Keep the weekday walk in the diary.",
            "reason": "The increase came from weekdays, not weekends.",
            "timeframe": "for two weeks",
        }
    ],
    "limitations": ["Three days in the baseline window have no data."],
    "confidence": "moderate",
    "professional_review_recommended": False,
}


def fake_chat(insight=None, tool_calls=None):
    """A stand-in for `client.chat` that plays out a tool round then answers."""
    insight = insight or GOOD_INSIGHT
    state = {"round": 0}

    def _chat(messages, *, model, tools=None, response_format=None, **kwargs):
        state["round"] += 1
        if response_format is not None:
            message = {"content": json.dumps(insight)}
        elif tool_calls and state["round"] == 1:
            message = {"content": "", "tool_calls": tool_calls}
        else:
            message = {"content": "I have what I need."}
        return {
            "message": message,
            "finish_reason": "stop",
            "usage": {"prompt_tokens": 100, "completion_tokens": 50},
            "latency_ms": 12,
            "model": model,
        }

    return _chat


class InsightTestCase(TestCase):
    def setUp(self):
        cache.clear()
        self.token, self.raw = ApiToken.issue("insight-test")
        self.device = Device.objects.create(device_id="insight-device")
        self.batch = Batch.objects.create(idempotency_key="insight.ndjson", device=self.device)
        self.as_of = health_analysis.last_complete_day()
        self.counter = 0
        self.seed()

    def auth(self):
        return {"authorization": f"Bearer {self.raw}"}

    def seed(self, days=40, value=10_000):
        for i in range(days):
            day = self.as_of - timedelta(days=i)
            self.counter += 1
            Record.objects.create(
                id=f"stat:step_count:{day.isoformat()}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.STATISTIC,
                metric="HKQuantityTypeIdentifierStepCount",
                metric_slug="step_count",
                unit="count",
                aggregation="cumulative",
                value=value,
                start=datetime.combine(day, time(12), tzinfo=SGT),
                end=datetime.combine(day, time(12), tzinfo=SGT),
            )


class SymptomTests(TestCase):
    def test_urgent_symptoms_are_recognised(self):
        urgent, _ = safety.detect_symptoms("I've had chest pain since this morning")
        self.assertIn("chest pain or pressure", urgent)

    def test_ordinary_symptoms_ask_for_review_not_urgency(self):
        urgent, review = safety.detect_symptoms("I've been so tired all week")
        self.assertEqual(urgent, [])
        self.assertIn("persistent fatigue", review)

    def test_a_normal_question_triggers_neither(self):
        urgent, review = safety.detect_symptoms("How has my sleep changed this month?")
        self.assertEqual((urgent, review), ([], []))


class PreflightTests(InsightTestCase):
    def test_a_symptom_outranks_the_measurements(self):
        """"My chest hurts but my watch says I'm fine" must never resolve to
        reassurance."""
        snapshot = health_analysis.snapshot()
        verdict = safety.preflight("I have chest pain but my heart rate looks normal", snapshot)

        self.assertEqual(verdict.level, "urgent")
        self.assertTrue(any("chest pain" in r for r in verdict.reasons))

    def test_weak_coverage_becomes_an_explicit_constraint(self):
        Record.objects.all().delete()
        cache.clear()
        snapshot = health_analysis.snapshot()

        verdict = safety.preflight("Am I getting fitter?", snapshot)

        self.assertTrue(any("coverage is weak" in c for c in verdict.constraints))

    def test_a_reading_outside_the_reviewed_band_asks_for_review(self):
        for i in range(35):
            day = self.as_of - timedelta(days=i)
            Record.objects.create(
                id=f"rhr-{i}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.QUANTITY,
                metric="HKQuantityTypeIdentifierRestingHeartRate",
                metric_slug="resting_heart_rate",
                unit="count/min",
                aggregation="discrete",
                value=112,
                start=datetime.combine(day, time(12), tzinfo=SGT),
                end=datetime.combine(day, time(12), tzinfo=SGT),
            )
        cache.clear()

        verdict = safety.preflight("How am I doing?", health_analysis.snapshot())

        self.assertEqual(verdict.level, "review_recommended")
        self.assertTrue(any("Resting heart rate" in r for r in verdict.reasons))

    def test_a_thin_reading_does_not_trip_the_threshold(self):
        """One or two readings is exactly the sort of number that should not
        escalate anything."""
        for i in range(2):
            day = self.as_of - timedelta(days=i)
            Record.objects.create(
                id=f"rhr-thin-{i}",
                device=self.device,
                batch=self.batch,
                kind=Record.Kind.QUANTITY,
                metric="HKQuantityTypeIdentifierRestingHeartRate",
                metric_slug="resting_heart_rate",
                unit="count/min",
                aggregation="discrete",
                value=130,
                start=datetime.combine(day, time(12), tzinfo=SGT),
                end=datetime.combine(day, time(12), tzinfo=SGT),
            )
        cache.clear()

        verdict = safety.preflight("How am I doing?", health_analysis.snapshot())

        self.assertNotIn("Resting heart rate", " ".join(verdict.reasons))


class PostflightTests(TestCase):
    def verdict(self):
        return safety.SafetyVerdict()

    def test_a_named_condition_is_blocked(self):
        insight = {**GOOD_INSIGHT, "summary": "Based on this, you probably have sleep apnea."}
        result = safety.postflight(insight, self.verdict())

        self.assertTrue(result.blocked)
        self.assertIn("names a medical condition", result.blocked_reason)

    def test_medication_advice_is_blocked(self):
        insight = {
            **GOOD_INSIGHT,
            "actions": [
                {
                    "action": "You should reduce your dose of beta blockers.",
                    "reason": "Your resting heart rate is low.",
                    "timeframe": "this week",
                }
            ],
        }
        self.assertTrue(safety.postflight(insight, self.verdict()).blocked)

    def test_claiming_the_data_rules_out_illness_is_blocked(self):
        insight = {
            **GOOD_INSIGHT,
            "summary": "These readings rule out any underlying illness.",
        }
        self.assertTrue(safety.postflight(insight, self.verdict()).blocked)

    def test_telling_someone_to_ignore_a_symptom_is_blocked(self):
        insight = {**GOOD_INSIGHT, "summary": "Your numbers are fine, so ignore the pain."}
        self.assertTrue(safety.postflight(insight, self.verdict()).blocked)

    def test_a_prohibited_claim_buried_in_an_action_is_still_caught(self):
        """Checking only the summary would let the specific advice through,
        which is where it actually matters."""
        insight = {
            **GOOD_INSIGHT,
            "actions": [
                {
                    "action": "Cut calories to below 900 a day.",
                    "reason": "Your weight is up.",
                    "timeframe": "for a month",
                }
            ],
        }
        self.assertTrue(safety.postflight(insight, self.verdict()).blocked)

    def test_an_ordinary_answer_passes(self):
        result = safety.postflight(dict(GOOD_INSIGHT), self.verdict())
        self.assertFalse(result.blocked)

    def test_the_required_cautious_phrasing_is_not_blocked(self):
        """"This data cannot rule out an underlying illness" is the sentence the
        system prompt asks for. A checker that matches "rule out illness"
        without reading the negation blocks the correct answer and lets nothing
        useful through — which is what it did."""
        insight = {
            **GOOD_INSIGHT,
            "limitations": [
                "This data cannot rule out an underlying illness.",
                "Wearable readings do not rule out infection.",
            ],
        }
        self.assertFalse(safety.postflight(insight, self.verdict()).blocked)

    def test_declining_to_give_medication_advice_is_not_medication_advice(self):
        insight = {
            **GOOD_INSIGHT,
            "summary": "I cannot suggest you adjust your medication; that is for your doctor.",
        }
        self.assertFalse(safety.postflight(insight, self.verdict()).blocked)

    def test_a_hypothetical_condition_is_not_a_diagnosis(self):
        insight = {
            **GOOD_INSIGHT,
            "summary": "If you have a thyroid condition, your clinician is the person to ask.",
        }
        self.assertFalse(safety.postflight(insight, self.verdict()).blocked)

    def test_an_affirmative_rule_out_claim_is_still_blocked(self):
        insight = {**GOOD_INSIGHT, "summary": "Your readings rule out any infection."}
        self.assertTrue(safety.postflight(insight, self.verdict()).blocked)

    def test_mentioning_a_clinician_sets_the_review_flag(self):
        insight = {
            **GOOD_INSIGHT,
            "summary": "If this continues it is worth speaking to your doctor.",
            "professional_review_recommended": False,
        }
        safety.postflight(insight, self.verdict())
        self.assertTrue(insight["professional_review_recommended"])


class AnswerFlowTests(InsightTestCase):
    def test_an_emergency_never_reaches_the_model(self):
        """§7: use reviewed guidance for serious situations rather than letting
        a model invent thresholds."""
        with mock.patch.object(llm_client, "chat") as chat:
            payload = llm_service.answer("I have crushing chest pain right now")

        chat.assert_not_called()
        self.assertEqual(payload["safety"]["level"], "urgent")
        self.assertEqual(payload["source"], "safety_rules")
        self.assertIn("emergency number", payload["answer"]["summary"])
        self.assertTrue(payload["answer"]["professional_review_recommended"])

    def test_a_normal_question_runs_tools_then_answers(self):
        calls = [
            {
                "id": "call-1",
                "function": {"name": "get_metric_trend", "arguments": '{"metric": "step_count"}'},
            }
        ]
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat(tool_calls=calls)):
            payload = llm_service.answer("Am I becoming more active?")

        self.assertTrue(payload["generated"])
        self.assertEqual(payload["tool_calls"][0]["tool"], "get_metric_trend")
        self.assertTrue(payload["tool_calls"][0]["ok"])
        self.assertEqual(payload["answer"]["summary"], GOOD_INSIGHT["summary"])

    def test_an_unreachable_model_still_returns_the_measured_snapshot(self):
        """The numbers were measured; only the prose is missing. Showing an
        error page here would hide data that is perfectly good."""
        with mock.patch.object(
            llm_client, "resolve_model", side_effect=llm_client.LLMUnavailable("connection refused")
        ):
            payload = llm_service.answer("How is my sleep?")

        self.assertFalse(payload["generated"])
        self.assertIn("connection refused", payload["error"])
        self.assertEqual(payload["snapshot"]["metrics"][0]["metric_slug"], "step_count")

    def test_a_blocked_answer_is_withheld_and_explained(self):
        bad = {**GOOD_INSIGHT, "summary": "You likely have an arrhythmia."}
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat(insight=bad)):
            payload = llm_service.answer("Why is my heart rate odd?")

        self.assertIsNone(payload["answer"])
        self.assertTrue(payload["safety"]["blocked"])
        self.assertIn("measured summary below is unaffected", payload["error"])
        # The snapshot survives, so the screen is not blank.
        self.assertTrue(payload["snapshot"]["metrics"])

    def test_unparseable_output_degrades_instead_of_raising(self):
        def broken(messages, *, model, tools=None, response_format=None, **kwargs):
            return {
                "message": {"content": "Sorry, I can't do that."},
                "finish_reason": "stop",
                "usage": {},
                "latency_ms": 5,
                "model": model,
            }

        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=broken):
            payload = llm_service.answer("How is my sleep?")

        self.assertFalse(payload["generated"])
        self.assertIn("structured output", payload["error"])

    def test_a_reasoning_trace_around_the_json_is_tolerated(self):
        def thinking(messages, *, model, tools=None, response_format=None, **kwargs):
            content = (
                "<think>The user wants steps. I should check the snapshot.</think>\n"
                "```json\n" + json.dumps(GOOD_INSIGHT) + "\n```"
            )
            return {
                "message": {"content": content},
                "finish_reason": "stop",
                "usage": {},
                "latency_ms": 5,
                "model": model,
            }

        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=thinking):
            payload = llm_service.answer("How many steps?")

        self.assertTrue(payload["generated"])
        self.assertEqual(payload["answer"]["summary"], GOOD_INSIGHT["summary"])

    def test_more_than_three_actions_are_trimmed(self):
        crowded = {
            **GOOD_INSIGHT,
            "actions": [
                {"action": f"Thing {i}", "reason": "r", "timeframe": "t"} for i in range(8)
            ],
        }
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat(insight=crowded)):
            payload = llm_service.answer("What should I do?")

        self.assertEqual(len(payload["answer"]["actions"]), 3)


class ToolSurfaceTests(InsightTestCase):
    def test_an_unknown_metric_comes_back_as_a_correctable_error(self):
        result = llm_tools.call("get_metric_trend", {"metric": "unicorns"})
        self.assertIn("unknown metric", result["error"])
        self.assertIn("step_count", result["error"])

    def test_an_unknown_tool_lists_the_real_ones(self):
        result = llm_tools.call("drop_table", {})
        self.assertIn("no such tool", result["error"])
        self.assertIn("get_health_overview", result["available"])

    def test_an_absurd_window_is_clamped_not_run(self):
        result = llm_tools.call("get_metric_trend", {"metric": "step_count", "days": 99_999})
        self.assertEqual(result["window_days"], llm_tools.MAX_WINDOW_DAYS)

    def test_trend_results_omit_the_daily_points(self):
        """Handing a model 90 raw daily values invites it to average them
        itself, which is the arithmetic this design exists to avoid."""
        result = llm_tools.call("get_metric_trend", {"metric": "step_count"})
        self.assertNotIn("points", result)
        self.assertEqual(result["daily_points_omitted"], 40)

    def test_every_declared_tool_is_dispatchable(self):
        for definition in llm_tools.DEFINITIONS:
            self.assertIn(definition["name"], llm_tools.REGISTRY)
            result = llm_tools.call(definition["name"], {})
            self.assertIsInstance(result, dict)

    def test_the_schema_is_shaped_for_the_openai_api(self):
        for entry in llm_tools.openai_schema():
            self.assertEqual(entry["type"], "function")
            self.assertIn("name", entry["function"])
            self.assertEqual(entry["function"]["parameters"]["type"], "object")


class RetentionTests(InsightTestCase):
    def test_a_turn_is_recorded_without_a_copy_of_the_health_data(self):
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat()):
            llm_service.answer("How is my week?")

        turn = InsightTurn.objects.get()
        self.assertEqual(turn.question, "How is my week?")
        self.assertEqual(turn.answer["summary"], GOOD_INSIGHT["summary"])
        # The snapshot is recomputable from records that are still here; a
        # second copy would only widen what a deletion has to reach.
        self.assertFalse(hasattr(turn, "snapshot"))

    def test_turns_past_the_retention_window_are_deleted(self):
        turn = InsightTurn.objects.create(question="old")
        InsightTurn.objects.filter(pk=turn.pk).update(
            created_at=turn.created_at - timedelta(days=InsightTurn.retention_days() + 1)
        )
        InsightTurn.objects.create(question="recent")

        InsightTurn.prune()

        self.assertEqual([t.question for t in InsightTurn.objects.all()], ["recent"])

    def test_remember_false_leaves_nothing_behind(self):
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat()):
            llm_service.answer("private question", persist=False)

        self.assertEqual(InsightTurn.objects.count(), 0)


class InsightEndpointTests(InsightTestCase):
    def test_ask_requires_auth(self):
        self.assertIn(
            self.client.post("/v1/insights/ask", data={}, content_type="application/json").status_code,
            (401, 403),
        )

    def test_ask_rejects_an_empty_question(self):
        response = self.client.post(
            "/v1/insights/ask",
            data=json.dumps({"question": "   "}),
            content_type="application/json",
            headers=self.auth(),
        )
        self.assertEqual(response.status_code, 400)

    def test_ask_returns_the_structured_payload(self):
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat()):
            response = self.client.post(
                "/v1/insights/ask",
                data=json.dumps({"question": "Am I sleeping enough?"}),
                content_type="application/json",
                headers=self.auth(),
            )

        body = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(body["generated"])
        self.assertIn("observations", body["answer"])
        self.assertIn("snapshot", body)
        self.assertEqual(body["safety"]["level"], "coaching")

    def test_status_names_where_processing_happens(self):
        """§8 requires the user be told which provider receives their data."""
        with mock.patch.object(llm_client, "available_models", return_value=["local-model"]):
            body = self.client.get("/v1/insights/status", headers=self.auth()).json()

        self.assertTrue(body["reachable"])
        self.assertTrue(body["local"])
        self.assertIn("127.0.0.1", body["base_url"])
        self.assertEqual(body["retention_days"], InsightTurn.retention_days())

    def test_a_tailnet_model_host_is_not_reported_as_external(self):
        """The model runs on the user's own laptop, reached over WireGuard.
        Calling that "an external service" would be a false privacy claim in the
        alarming direction."""
        with self.settings(LLM_BASE_URL="http://macbook.tail03bec9.ts.net:1234/v1"):
            destination = llm_client.destination()
            self.assertEqual(destination["kind"], "tailnet")
            self.assertTrue(llm_client.is_local())
            self.assertIn("your own machine", destination["description"])

    def test_a_third_party_endpoint_is_reported_as_external(self):
        with self.settings(LLM_BASE_URL="https://api.example-cloud.com/v1"):
            self.assertEqual(llm_client.destination()["kind"], "external")
            self.assertFalse(llm_client.is_local())

    def test_a_bare_tailnet_ip_still_counts_as_the_tailnet(self):
        with self.settings(LLM_BASE_URL="http://100.102.249.92:1234/v1"):
            self.assertEqual(llm_client.destination()["kind"], "tailnet")

    def test_status_reports_an_unreachable_server_plainly(self):
        with mock.patch.object(
            llm_client, "available_models", side_effect=llm_client.LLMUnavailable("refused")
        ):
            body = self.client.get("/v1/insights/status", headers=self.auth()).json()

        self.assertFalse(body["reachable"])
        self.assertIn("refused", body["detail"])

    def test_history_is_session_only_and_deletable(self):
        User.objects.create_user(username="dash", password="dash-p4ssw0rd-x")
        self.client.get("/v1/auth/csrf")
        self.client.post(
            "/v1/auth/session",
            data=json.dumps({"username": "dash", "password": "dash-p4ssw0rd-x"}),
            content_type="application/json",
        )
        InsightTurn.objects.create(question="kept for now")

        self.assertEqual(len(self.client.get("/v1/insights/history").json()["turns"]), 1)
        self.assertEqual(self.client.delete("/v1/insights/history").json()["deleted"], 1)
        self.assertEqual(InsightTurn.objects.count(), 0)

    def test_generation_is_throttled(self):
        with mock.patch.object(llm_client, "resolve_model", return_value="test-model"), \
             mock.patch.object(llm_client, "chat", side_effect=fake_chat()):
            codes = {
                self.client.post(
                    "/v1/insights/ask",
                    data=json.dumps({"question": "again"}),
                    content_type="application/json",
                    headers=self.auth(),
                ).status_code
                for _ in range(14)
            }
        self.assertIn(429, codes)

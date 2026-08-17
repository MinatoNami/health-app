"""Tests for the progress note an in-flight answer writes as it works.

The point of these is that the note is *decoration*: it must say something
useful while somebody waits, and it must never be able to affect the answer. So
what is pinned here is mostly the failure behaviour — a broken cache, a rejected
key, a poll for a question nobody asked — because those are the paths where a
progress indicator could turn into an outage.
"""

from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse

from ingest.llm import service as llm_service
from ingest.llm import tools as llm_tools
from ingest.models import ApiToken


class ProgressKeyTests(TestCase):
    def test_a_uuid_is_accepted(self):
        key = "3f1b6c2a-9d4e-4a77-b0f1-2c5d8e9a1b33"
        self.assertEqual(
            llm_service.progress_cache_key(key), f"insight-progress:{key}"
        )

    def test_anything_that_is_not_a_uuid_is_refused(self):
        """The key reaches a cache key, so it is checked rather than trusted."""
        for bad in ("", "   ", "../etc/passwd", "key with spaces", "a" * 200, "sel;ect"):
            self.assertIsNone(llm_service.progress_cache_key(bad), bad)

    def test_no_key_means_no_writer(self):
        self.assertIsNone(llm_service._progress_writer(None))
        self.assertIsNone(llm_service._progress_writer("not a uuid"))


class ProgressWriterTests(TestCase):
    def setUp(self):
        cache.clear()
        self.key = "3f1b6c2a-9d4e-4a77-b0f1-2c5d8e9a1b33"

    def test_each_report_advances_the_step(self):
        write = llm_service._progress_writer(self.key)
        write("Reading your sleep summary")
        self.assertEqual(llm_service.read_progress(self.key)["step"], 1)
        write("Writing the answer")
        note = llm_service.read_progress(self.key)
        self.assertEqual(note["step"], 2)
        self.assertEqual(note["label"], "Writing the answer")
        self.assertFalse(note["done"])

    def test_reading_an_unknown_key_is_none_rather_than_an_error(self):
        self.assertIsNone(llm_service.read_progress("11111111-2222-3333-4444-555555555555"))
        self.assertIsNone(llm_service.read_progress("nonsense"))


class ToolLabelTests(TestCase):
    def test_every_registered_tool_has_a_label(self):
        """A tool added without one should look unfinished, not invisible."""
        for name in llm_tools.REGISTRY:
            self.assertIn(name, llm_tools.LABELS, f"{name} has no progress label")

    def test_labels_do_not_name_tools(self):
        """These are the only words somebody sees while waiting."""
        for name, label in llm_tools.LABELS.items():
            self.assertNotIn("_", label, f"{name}'s label reads like an identifier")
            self.assertTrue(label[0].isupper(), f"{name}'s label is not a sentence")

    def test_an_unlabelled_tool_still_says_something(self):
        self.assertEqual(llm_tools.label_for("get_future_tool"), "Running get_future_tool")


class ToolLoopProgressTests(TestCase):
    """The loop reports, and a report that fails does not take the answer with it."""

    def test_a_failing_progress_callback_does_not_break_the_loop(self):
        def explode(_label):
            raise RuntimeError("cache is down")

        message = {"role": "assistant", "content": "done", "tool_calls": []}
        with mock.patch.object(
            llm_service.client,
            "chat",
            return_value={
                "message": message,
                "usage": {"prompt_tokens": 1, "completion_tokens": 1},
                "latency_ms": 1,
                "finish_reason": "stop",
            },
        ):
            messages, log_entries, usage = llm_service._run_tool_loop(
                [{"role": "user", "content": "hi"}], "m", None, on_progress=explode
            )
        self.assertEqual(log_entries, [])
        self.assertTrue(messages)

    def test_the_decide_label_appears_once_not_every_round(self):
        """After the first round a tool has just run, and its label is the more
        useful thing to leave on screen while the model reads the result."""
        seen = []
        calls = {"n": 0}

        def chat(*_a, **_k):
            calls["n"] += 1
            tool_calls = (
                [{"id": "1", "function": {"name": "get_goals", "arguments": "{}"}}]
                if calls["n"] == 1
                else []
            )
            return {
                "message": {"role": "assistant", "content": "", "tool_calls": tool_calls},
                "usage": {"prompt_tokens": 1, "completion_tokens": 1},
                "latency_ms": 1,
                "finish_reason": "stop",
            }

        with mock.patch.object(llm_service.client, "chat", side_effect=chat), \
             mock.patch.object(llm_service.tools, "call", return_value={"ok": True}):
            llm_service._run_tool_loop(
                [{"role": "user", "content": "hi"}], "m", None, on_progress=seen.append
            )
        self.assertEqual(seen.count("Deciding what to look up"), 1)
        self.assertIn("Reading your goals", seen)
        self.assertEqual(seen[-1], "Reading your goals")

    def test_the_loop_reports_before_it_decides(self):
        seen = []
        message = {"role": "assistant", "content": "done", "tool_calls": []}
        with mock.patch.object(
            llm_service.client,
            "chat",
            return_value={
                "message": message,
                "usage": {"prompt_tokens": 1, "completion_tokens": 1},
                "latency_ms": 1,
                "finish_reason": "stop",
            },
        ):
            llm_service._run_tool_loop(
                [{"role": "user", "content": "hi"}], "m", None, on_progress=seen.append
            )
        self.assertEqual(seen, ["Deciding what to look up"])


class ProgressEndpointTests(TestCase):
    def setUp(self):
        cache.clear()
        _, self.raw = ApiToken.issue("progress-test")
        self.key = "3f1b6c2a-9d4e-4a77-b0f1-2c5d8e9a1b33"

    def get(self, key):
        return self.client.get(
            reverse("insight-progress", args=[key]),
            HTTP_AUTHORIZATION=f"Bearer {self.raw}",
        )

    def test_it_needs_authentication(self):
        # 403 rather than 401: SessionAuthentication is in AUTH, so DRF omits the
        # WWW-Authenticate challenge. Either way it is refused, which is the
        # thing being asserted.
        response = self.client.get(reverse("insight-progress", args=[self.key]))
        self.assertIn(response.status_code, (401, 403))

    def test_nothing_recorded_yet_is_not_an_error(self):
        """The first poll lands before the first tool, every time."""
        response = self.get(self.key)
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["known"])
        self.assertFalse(response.json()["done"])

    def test_a_recorded_step_is_reported(self):
        llm_service._progress_writer(self.key)("Reading your food log")
        body = self.get(self.key).json()
        self.assertEqual(body["label"], "Reading your food log")
        self.assertTrue(body["known"])
        self.assertFalse(body["done"])

    def test_a_bad_key_reads_as_unknown_rather_than_500(self):
        response = self.get("not-a-uuid-at-all!!")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["known"])


class ContextFitTests(TestCase):
    """A prompt that cannot fit should say so, not be sent and rejected.

    The window changes without anyone touching this app: with LLM_MODEL unset
    the client takes whichever model the server lists first, so loading a model
    in LM Studio can move questions onto one whose context is too small.
    """

    def test_a_window_too_small_is_refused_before_anything_is_sent(self):
        with mock.patch.object(llm_service, "context_tokens", return_value=8192), \
             mock.patch.object(llm_service, "estimate_tokens", return_value=9000), \
             mock.patch.object(llm_service.client, "is_enabled", return_value=True), \
             mock.patch.object(llm_service.client, "resolve_model", return_value="tiny/model"), \
             mock.patch.object(llm_service.client, "chat") as chat:
            payload = llm_service.answer("How is my sleep?", persist=False)

        chat.assert_not_called()
        self.assertFalse(payload["generated"])
        self.assertIn("8,192", payload["error"])
        self.assertIn("tiny/model", payload["error"])
        # The measured half is what the screen falls back to, so it must survive.
        self.assertIsNotNone(payload["snapshot"])

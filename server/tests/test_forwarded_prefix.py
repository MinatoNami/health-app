"""The prefix a gateway mounts this instance under.

The point of these is the asymmetry: the same instance has to generate
prefixed URLs for the admin and unprefixed ones for /v1, decided per request.
"""

from django.test import TestCase, override_settings
from django.urls import reverse


class ForwardedPrefixTests(TestCase):
    def test_the_admin_redirect_carries_the_prefix(self):
        # The concrete symptom this exists for: without the header the admin
        # sends you to /admin/login/, which on a shared origin is a different
        # application's admin.
        response = self.client.get("/admin/", HTTP_X_FORWARDED_PREFIX="/health-app")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response["Location"], "/health-app/admin/login/?next=/health-app/admin/")

    def test_without_the_header_nothing_moves(self):
        response = self.client.get("/admin/")
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response["Location"], "/admin/login/?next=/admin/")

    def test_the_ingest_endpoint_is_untouched_by_a_prefixed_request(self):
        # /v1 stays at the origin root for shipped iOS builds. Resolution runs
        # on path_info, which the gateway has already stripped, so a prefixed
        # request still reaches the same view.
        response = self.client.post("/v1/health/batches", HTTP_X_FORWARDED_PREFIX="/health-app")
        self.assertEqual(response.status_code, 401)

    def test_static_stays_at_the_origin_root(self):
        # Deliberately *not* prefixed, both ways. STATIC_URL is absolute, so
        # Django leaves it alone whatever the script prefix is, and every app
        # on this origin shares /static/. A relative STATIC_URL would be
        # prefixed instead — and worse, inconsistently: the staticfiles storage
        # caches the value the first time it is built, so whichever request
        # arrived first would decide it for the whole worker.
        prefixed = self.client.get("/admin/login/", HTTP_X_FORWARDED_PREFIX="/health-app")
        plain = self.client.get("/admin/login/")
        for response in (prefixed, plain):
            self.assertContains(response, "/static/admin/css/base.css", status_code=200)
            self.assertNotContains(response, "/health-app/static/")

    def test_the_login_form_posts_back_inside_the_mount(self):
        # The one that matters for phishing: an action attribute pointing out
        # of the mount would send the password somewhere else on a shared
        # origin.
        response = self.client.get("/admin/login/", HTTP_X_FORWARDED_PREFIX="/health-app")
        self.assertContains(response, 'action="/health-app/admin/login/"')

    def test_a_prefix_we_do_not_expect_is_ignored(self):
        # Anyone can send this header. An unchecked value would let a caller
        # choose the action on the admin's own login form.
        response = self.client.get("/admin/", HTTP_X_FORWARDED_PREFIX="https://evil.example")
        self.assertEqual(response["Location"], "/admin/login/?next=/admin/")

    @override_settings(FORWARDED_PREFIXES=["/health-app", "/somewhere-else"])
    def test_more_than_one_prefix_can_be_allowed(self):
        response = self.client.get("/admin/", HTTP_X_FORWARDED_PREFIX="/somewhere-else")
        self.assertEqual(response["Location"], "/somewhere-else/admin/login/?next=/somewhere-else/admin/")

    def test_a_trailing_slash_does_not_double_up(self):
        response = self.client.get("/admin/", HTTP_X_FORWARDED_PREFIX="/health-app/")
        self.assertEqual(response["Location"], "/health-app/admin/login/?next=/health-app/admin/")

    def test_reverse_is_prefixed_within_the_request(self):
        # set_script_prefix is a thread-local; this is the check that it is
        # actually being set rather than the Location header happening to be
        # right for some other reason.
        with self.settings(FORWARDED_PREFIXES=["/health-app"]):
            self.client.get("/admin/", HTTP_X_FORWARDED_PREFIX="/health-app")
        # And that it does not leak into the next request on the same thread.
        self.client.get("/admin/")
        self.assertEqual(reverse("admin:index"), "/admin/")

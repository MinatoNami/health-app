"""The path the session and CSRF cookies are scoped to.

This origin is shared with other applications behind a path-routing gateway. A
cookie at "/" is sent to all of them; these pin it to this app's own mount.
"""

from django.test import TestCase, override_settings


class CookieScopeTests(TestCase):
    def test_the_session_cookie_is_scoped_to_the_mount(self):
        from django.conf import settings

        self.assertEqual(settings.SESSION_COOKIE_PATH, "/health-app")

    def test_the_csrf_cookie_is_scoped_to_the_mount(self):
        from django.conf import settings

        self.assertEqual(settings.CSRF_COOKIE_PATH, "/health-app")

    def test_a_set_cookie_carries_the_path(self):
        # The setting is only half of it; this is what the browser actually
        # receives, and what decides whether /athena/ sees this token.
        response = self.client.get("/v1/auth/csrf")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.cookies["csrftoken"]["path"], "/health-app")

    @override_settings(SESSION_COOKIE_PATH="/", CSRF_COOKIE_PATH="/")
    def test_an_instance_that_owns_its_origin_can_still_use_root(self):
        # Scoping is a deployment choice, not a hard-coded assumption: a
        # standalone instance with no neighbours is correct at "/".
        response = self.client.get("/v1/auth/csrf")
        self.assertEqual(response.cookies["csrftoken"]["path"], "/")

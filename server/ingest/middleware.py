"""Letting a gateway mount this instance on a path.

`FORCE_SCRIPT_NAME` is the documented way to do this, and it is the wrong tool
here: it applies to the whole instance. `/v1` has to stay at the origin root —
shipped iOS builds have `https://<origin>/v1/health/batches` compiled in, and
a phone cannot be asked to update before it can sync. So the prefix has to be
a property of the request, not of the process.

That is what this reads. The gateway sends `X-Forwarded-Prefix` on the routes
it mounts under a path and omits it on the ones it leaves at the root, and the
same Django instance answers both, generating the right URLs for each.
"""

from django.conf import settings
from django.urls import set_script_prefix


class ForwardedPrefixMiddleware:
    """Honour `X-Forwarded-Prefix`, if it names a prefix we expect.

    The allowlist is the security boundary and is not optional. Nothing stops a
    client from sending this header itself, and an unchecked value would let it
    choose the URLs this app writes into its own pages — the admin login form's
    action among them, which is a phishing primitive rather than a cosmetic bug.
    A gateway that sets the header overwrites whatever arrived; this check is
    what protects the deployments where something upstream forgets to.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        prefix = request.META.get("HTTP_X_FORWARDED_PREFIX", "").rstrip("/")
        if prefix and prefix in settings.FORWARDED_PREFIXES:
            request.META["SCRIPT_NAME"] = prefix
            # `path_info` is what the gateway left after stripping the prefix,
            # and stays the thing URL resolution matches on. `path` is what the
            # request calls itself, and has to carry the prefix back.
            request.path = prefix + request.path_info
            # `reverse()` reads a thread-local that the WSGI handler set before
            # any middleware ran. Without overwriting it here, every generated
            # URL — redirects, form actions, the whole admin — comes out
            # unprefixed and walks the user out of the mount.
            set_script_prefix(prefix + "/")
        else:
            # Set deterministically rather than inherited. Django's WSGI
            # handler resets this thread-local for every request, so in
            # production the `if` branch alone would be enough — but a
            # middleware that writes a thread-local on some requests and not
            # others is one changed handler away from serving request B under
            # request A's prefix. The test client is already such a handler.
            set_script_prefix(request.META.get("SCRIPT_NAME", "") + "/")
        return self.get_response(request)

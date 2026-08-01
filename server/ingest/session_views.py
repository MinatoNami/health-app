"""Browser session login for the dashboard.

The phone authenticates with a bearer token; a browser should not. A session
cookie is HttpOnly, so it is not readable by script the way a token in
localStorage is, and — the practical reason — it rides along on a plain
`<a href>`, which is what lets a multi-hundred-megabyte CSV stream directly to
disk instead of being assembled in browser memory first.
"""

import logging

from django.contrib.auth import authenticate, login, logout
from django.views.decorators.csrf import ensure_csrf_cookie
from rest_framework import status
from rest_framework.authentication import SessionAuthentication
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.parsers import JSONParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

log = logging.getLogger(__name__)


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
@ensure_csrf_cookie
def csrf(request):
    """Plants the CSRF cookie the login POST has to echo back."""
    return Response({"ok": True})


class SessionLoginView(APIView):
    """Same credentials as the app's token login, different receipt.

    Throttled under the same scope as the token login: this is another door to
    the same password, and rate-limiting one but not the other would be
    pointless.
    """

    authentication_classes = [SessionAuthentication]
    permission_classes = [AllowAny]
    parser_classes = [JSONParser]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "login"

    def post(self, request):
        username = (request.data.get("username") or "").strip()
        password = request.data.get("password") or ""
        if not username or not password:
            return Response(
                {"detail": "username and password are required"},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = authenticate(request, username=username, password=password)
        if user is None or not user.is_active:
            log.warning("Failed dashboard login for %r", username[:64])
            return Response(
                {"detail": "Invalid username or password"},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        login(request, user)
        return Response({"username": user.get_username(), "is_staff": user.is_staff})


@api_view(["POST"])
@authentication_classes([SessionAuthentication])
@permission_classes([IsAuthenticated])
def session_logout(request):
    logout(request)
    return Response({"status": "signed out"})


@api_view(["GET"])
@authentication_classes([SessionAuthentication])
@permission_classes([AllowAny])
def session_me(request):
    """Lets the SPA decide between the login screen and the dashboard on load
    without having to fire a real query first."""
    user = request.user
    if user is None or not user.is_authenticated:
        return Response({"authenticated": False})
    return Response(
        {"authenticated": True, "username": user.get_username(), "is_staff": user.is_staff}
    )

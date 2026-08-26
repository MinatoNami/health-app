from django.utils import timezone
from rest_framework import authentication, exceptions

from .models import ApiToken


class TokenUser:
    """Stand-in principal for a bearer token.

    The endpoint authenticates devices, not people, so there is no Django User
    behind a token. This exists so `IsAuthenticated` and DRF's request.user
    behave normally without inventing a user row per phone.
    """

    is_authenticated = True
    is_anonymous = False
    is_active = True

    def __init__(self, token: ApiToken):
        self.token = token

    def __str__(self):
        return f"token:{self.token.label}"


class BearerTokenAuthentication(authentication.BaseAuthentication):
    keyword = b"bearer"

    def authenticate(self, request):
        header = authentication.get_authorization_header(request).split()
        if not header or header[0].lower() != self.keyword:
            return None
        if len(header) != 2:
            raise exceptions.AuthenticationFailed("Malformed Authorization header")

        try:
            raw = header[1].decode("ascii")
        except UnicodeDecodeError:
            raise exceptions.AuthenticationFailed("Malformed bearer token")

        # Lookup is by digest, so the raw secret is never compared, logged, or
        # stored — and the index makes it constant-work regardless of token.
        digest = ApiToken.hash_token(raw)
        token = ApiToken.objects.filter(token_hash=digest, revoked_at__isnull=True).first()
        if token is None:
            raise exceptions.AuthenticationFailed("Invalid or revoked token")

        # Coarse on purpose: this is a liveness signal for the operator, not an
        # audit log, and a write per request would be a needless cost.
        now = timezone.now()
        if token.last_used_at is None or (now - token.last_used_at).total_seconds() > 300:
            ApiToken.objects.filter(pk=token.pk).update(last_used_at=now)

        return TokenUser(token), token

    def authenticate_header(self, request):
        return 'Bearer realm="health"'


def owner_of(request):
    """The person behind the request, session or token.

    A bearer token authenticates a *device*, not a person, so `request.user` is
    a `TokenUser` with no primary key. But a token obtained by signing in
    records who signed in — and using that is what stops a question asked on the
    phone from being invisible in the dashboard's own history.

    Lives here rather than in a view module because three of them need the same
    answer, and "whose request is this?" is an authentication question.
    """
    user = getattr(request, "user", None)
    if getattr(user, "pk", None):
        return user
    token = getattr(request, "auth", None)
    return getattr(token, "owner", None)

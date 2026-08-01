from django.apps import AppConfig
from django.core.checks import Warning as CheckWarning
from django.core.checks import register


class IngestConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "ingest"

    def ready(self):
        register(check_single_tenant, "ingest")


def check_single_tenant(app_configs, **kwargs):
    """Warn when the single-person assumption stops holding.

    `Record` has no owner: every valid token can read every record. That is a
    deliberate simplification for a personal server with one person's data on
    it, and it is *only* correct while that is true.

    §5 of the integration notes requires that an authenticated user reach only
    their own records. The moment a second account exists this design violates
    that — so rather than pretending otherwise, the assumption is checked and
    said out loud on every management command.

    A check rather than a hard failure: adding a second admin account for
    yourself is a legitimate thing to do, and refusing to start would be a
    disproportionate response to it.
    """
    from django.contrib.auth import get_user_model

    try:
        owners = get_user_model().objects.filter(is_active=True).count()
    except Exception:  # noqa: BLE001 - runs before migrate on a fresh database
        return []

    if owners <= 1:
        return []

    return [
        CheckWarning(
            f"{owners} active accounts exist, but health records are not scoped to a user.",
            hint=(
                "Every valid session or token can read every record in this database. "
                "That is intended for a single-person server. If these accounts belong "
                "to different people, health records need an owner column and every "
                "analytics, export, and insight query needs to filter on it before "
                "this is safe."
            ),
            id="ingest.W001",
        )
    ]

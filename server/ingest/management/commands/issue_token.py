from django.core.management.base import BaseCommand

from ingest.models import ApiToken


class Command(BaseCommand):
    help = "Mint a bearer token for the iOS app. The secret is shown once and never stored."

    def add_arguments(self, parser):
        parser.add_argument("label", help="Human label, e.g. 'lionel-iphone'")

    def handle(self, *args, **options):
        token, raw = ApiToken.issue(options["label"])
        self.stdout.write(self.style.SUCCESS(f"Token '{token.label}' created."))
        self.stdout.write("")
        self.stdout.write(raw)
        self.stdout.write("")
        self.stdout.write(
            self.style.WARNING(
                "Copy it now — only the SHA-256 digest is stored, so this cannot be shown again."
            )
        )

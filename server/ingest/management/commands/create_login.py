from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError
from getpass import getpass


class Command(BaseCommand):
    help = (
        "Create (or reset the password of) an account the iOS app can sign in with. "
        "This is a plain user, not a superuser — signing in from a phone should not "
        "hand out admin access."
    )

    def add_arguments(self, parser):
        parser.add_argument("username")
        parser.add_argument(
            "--password",
            help="Skips the prompt. Avoid: it lands in your shell history.",
        )

    def handle(self, *args, **options):
        User = get_user_model()
        username = options["username"]
        password = options["password"]

        if not password:
            password = getpass("Password: ")
            if password != getpass("Password (again): "):
                raise CommandError("Passwords did not match.")

        try:
            validate_password(password)
        except ValidationError as exc:
            raise CommandError("\n".join(exc.messages)) from exc

        user, created = User.objects.get_or_create(username=username)
        user.set_password(password)
        user.is_active = True
        user.save()

        verb = "created" if created else "password reset for"
        self.stdout.write(self.style.SUCCESS(f"Account {verb}: {username}"))
        self.stdout.write("Sign in from the app with Settings → Sign In.")

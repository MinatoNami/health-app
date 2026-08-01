from django.urls import path

from . import views

urlpatterns = [
    # Path fixed by the client: SinkConfiguration appends /v1/health/batches to
    # a base URL that has no path of its own.
    path("v1/health/batches", views.BatchIngestView.as_view(), name="batch-ingest"),
    path("v1/auth/login", views.LoginView.as_view(), name="login"),
    path("v1/auth/logout", views.logout, name="logout"),
    path("v1/health/ping", views.ping, name="ping"),
    path("v1/health/stats", views.stats, name="stats"),
    path("healthz", views.healthz, name="healthz"),
]

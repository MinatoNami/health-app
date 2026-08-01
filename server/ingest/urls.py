from django.urls import path

from . import analytics_views, session_views, views

urlpatterns = [
    # Path fixed by the client: SinkConfiguration appends /v1/health/batches to
    # a base URL that has no path of its own.
    path("v1/health/batches", views.BatchIngestView.as_view(), name="batch-ingest"),
    path("v1/auth/login", views.LoginView.as_view(), name="login"),
    path("v1/auth/logout", views.logout, name="logout"),
    path("v1/health/ping", views.ping, name="ping"),
    path("v1/health/stats", views.stats, name="stats"),
    path("healthz", views.healthz, name="healthz"),
    # Browser session auth for the dashboard.
    path("v1/auth/csrf", session_views.csrf, name="csrf"),
    path("v1/auth/session", session_views.SessionLoginView.as_view(), name="session-login"),
    path("v1/auth/session/logout", session_views.session_logout, name="session-logout"),
    path("v1/auth/me", session_views.session_me, name="session-me"),
    # Dashboard analytics.
    path("v1/analytics/overview", analytics_views.overview, name="overview"),
    path("v1/analytics/metrics", analytics_views.metrics, name="metrics"),
    path("v1/analytics/series", analytics_views.series, name="series"),
    path("v1/export/summary", analytics_views.export_summary, name="export-summary"),
    path("v1/export/records.csv", analytics_views.export_csv, name="export-csv"),
]

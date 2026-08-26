from django.urls import path

from . import analytics_views, chat_views, insight_views, session_views, views

urlpatterns = [
    # Path fixed by the client: SinkConfiguration appends /v1/health/batches to
    # a base URL that has no path of its own.
    path("v1/health/batches", views.BatchIngestView.as_view(), name="batch-ingest"),
    path("v1/auth/login", views.LoginView.as_view(), name="login"),
    path("v1/auth/logout", views.logout, name="logout"),
    path("v1/health/ping", views.ping, name="ping"),
    path("v1/health/stats", views.stats, name="stats"),
    # Per-metric high-water marks. The client reconciles its anchors against
    # this before a sync; see views.coverage for why it is not part of /stats.
    path("v1/health/coverage", views.coverage, name="coverage"),
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
    # Deterministic analysis: baselines, trends, data quality. No model runs
    # behind any of these.
    path("v1/analysis/snapshot", insight_views.snapshot, name="analysis-snapshot"),
    path("v1/analysis/trend", insight_views.trend, name="analysis-trend"),
    path("v1/analysis/quality", insight_views.quality, name="analysis-quality"),
    path("v1/analysis/sleep", insight_views.sleep, name="analysis-sleep"),
    path("v1/analysis/nutrition", insight_views.nutrition, name="analysis-nutrition"),
    path("v1/analysis/anomalies", insight_views.anomalies, name="analysis-anomalies"),
    path("v1/analysis/correlations", insight_views.correlation_report, name="analysis-correlations"),
    path("v1/analysis/patterns", insight_views.pattern_report, name="analysis-patterns"),
    path("v1/analysis/goals", insight_views.goals, name="analysis-goals"),
    path("v1/analysis/goals/<int:goal_id>", insight_views.goal_detail, name="analysis-goal"),
    # LLM-backed explanation of the numbers above.
    path("v1/insights/status", insight_views.llm_status, name="insight-status"),
    path("v1/insights/daily", insight_views.daily, name="insight-daily"),
    path("v1/insights/ask", insight_views.ask, name="insight-ask"),
    # Where an in-flight answer has got to. Polled while `ask` is still open, so
    # the fifteen to ninety seconds it takes says something other than nothing.
    path("v1/insights/progress/<str:key>", insight_views.progress, name="insight-progress"),
    path("v1/insights/weekly", insight_views.weekly_review, name="insight-weekly"),
    path("v1/insights/history", insight_views.insight_history, name="insight-history"),
    # Conversations: the sidebar's list, one chat's transcript, and the flat
    # message export a feedback loop reads. `<uuid:...>` is doing real work —
    # it 404s a malformed session id at the router instead of letting it raise
    # out of the field inside the view.
    path("v1/chat/projects", chat_views.projects, name="chat-projects"),
    path("v1/chat/projects/<int:project_id>", chat_views.project_detail, name="chat-project"),
    path("v1/chat/sessions", chat_views.sessions, name="chat-sessions"),
    path("v1/chat/sessions/<uuid:session_id>", chat_views.session_detail, name="chat-session"),
    path(
        "v1/chat/sessions/<uuid:session_id>/compact",
        chat_views.session_compact,
        name="chat-session-compact",
    ),
    # The extension is in the path, like `/v1/export/records.csv`, and not a
    # `?format=` parameter — DRF reserves that name for content negotiation, so
    # `?format=md` resolves to "a renderer called md", finds none, and 404s. It
    # is a quiet trap: `?format=json` works by accident because that renderer
    # does exist, which makes the endpoint look half-broken rather than
    # misnamed.
    path(
        "v1/chat/sessions/<uuid:session_id>/export.<str:fmt>",
        chat_views.session_export,
        name="chat-session-export",
    ),
    path("v1/chat/messages", chat_views.messages, name="chat-messages"),
    path(
        "v1/chat/messages/<int:turn_id>/feedback",
        chat_views.message_feedback,
        name="chat-message-feedback",
    ),
    # How the answers are doing, grouped by the model and prompt that produced
    # them. The comparison prompt_version exists for.
    path("v1/chat/feedback", chat_views.feedback_summary, name="chat-feedback"),
]

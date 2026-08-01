"""The controlled LLM layer.

Nothing in here reaches the database directly. The model can only call the
read-only functions in `tools.py`, which return the same deterministic figures
`health_analysis` computes for the dashboard — so an insight and a chart can
never tell different stories, and there is no path from a generated string to a
query.
"""

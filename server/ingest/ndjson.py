"""Streaming NDJSON reader.

The client sends one JSON object per line specifically so the server never has
to buffer a whole batch to parse it. Reading `request.body` here would throw
that away, so this walks the raw stream in fixed-size chunks and yields lines as
they complete.
"""

import json
from typing import Iterator, NamedTuple


class PayloadTooLarge(Exception):
    pass


class ParsedLine(NamedTuple):
    """A decode result rather than an exception, because one corrupt line must
    not abort the whole batch — the caller decides the tolerance."""

    number: int
    obj: dict | None
    error: str | None


def iter_lines(stream, max_bytes: int, chunk_size: int = 65_536) -> Iterator[bytes]:
    """Yields newline-delimited byte strings, refusing to buffer past max_bytes."""
    buffer = b""
    total = 0

    while True:
        chunk = stream.read(chunk_size)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise PayloadTooLarge(f"payload exceeds {max_bytes} bytes")
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            yield line

    if buffer:
        yield buffer


def iter_objects(stream, max_bytes: int) -> Iterator[ParsedLine]:
    """Yields one ParsedLine per non-blank line.

    Line numbers are 1-based and count blank lines, so an error message points
    at the line a human would find in the file.
    """
    for index, raw in enumerate(iter_lines(stream, max_bytes), start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError as exc:
            yield ParsedLine(index, None, f"invalid JSON: {exc}")
            continue
        if not isinstance(obj, dict):
            yield ParsedLine(index, None, "expected a JSON object")
            continue
        yield ParsedLine(index, obj, None)

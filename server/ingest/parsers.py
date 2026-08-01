from rest_framework.parsers import BaseParser


class NDJSONStreamParser(BaseParser):
    """Hands the request stream through untouched.

    DRF would otherwise buffer and decode the body before the view runs, which
    defeats the reason the wire format is NDJSON in the first place.
    """

    media_type = "application/x-ndjson"

    def parse(self, stream, media_type=None, parser_context=None):
        return stream


class NDJSONAltParser(NDJSONStreamParser):
    media_type = "application/ndjson"


class OctetStreamParser(NDJSONStreamParser):
    """Fallback for clients that don't set a specific NDJSON media type."""

    media_type = "application/octet-stream"


class PlainTextStreamParser(NDJSONStreamParser):
    media_type = "text/plain"

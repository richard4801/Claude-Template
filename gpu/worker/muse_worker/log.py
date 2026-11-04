"""Logging with secret redaction. The worker token must never reach a log line."""

from __future__ import annotations

import logging
import sys
from urllib.parse import urlsplit

_SECRETS: set[str] = set()


def add_secret(value: str | None) -> None:
    """Register a value that must be masked in every log line (e.g. WORKER_TOKEN)."""
    if value and len(value) >= 4:
        _SECRETS.add(value)


def redact(text: str) -> str:
    for secret in _SECRETS:
        if secret in text:
            text = text.replace(secret, "***")
    return text


class RedactingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


def setup_logging(level: str = "INFO", stream=None) -> None:
    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(RedactingFormatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())


def safe_url(url: str) -> str:
    """Presigned URLs carry signatures in the query string, so log only scheme://host/path."""
    try:
        parts = urlsplit(url)
        return f"{parts.scheme}://{parts.netloc}{parts.path}"
    except ValueError:
        return "<invalid url>"

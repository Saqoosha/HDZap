from __future__ import annotations

import os
import random
import time
from dataclasses import dataclass
from typing import Protocol

import httpx


@dataclass
class Voice:
    """One specific voice from a provider — what gets dropped into a Premium voice picker."""

    id: str
    label: str
    lang: str  # "ja" or "en"


@dataclass
class Result:
    """One generated mp3 + metadata for the comparison report."""

    audio: bytes
    audio_format: str  # "mp3" or "wav"
    latency_ms: float
    cost_estimate_usd: float | None = None
    error: str | None = None


class Provider(Protocol):
    name: str
    voices: list[Voice]

    def is_available(self) -> bool:
        ...

    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        ...


class ProviderBase:
    name: str = ""
    voices: list[Voice] = []
    env_keys: list[str] = []  # which env vars must be present

    def is_available(self) -> bool:
        return all(os.environ.get(k) for k in self.env_keys)

    def voices_for(self, lang: str) -> list[Voice]:
        return [v for v in self.voices if v.lang == lang]


def timed(func):
    """Decorator: measure wall-clock latency and retry on 429s.

    Many TTS providers throttle bursts hard (Cartesia rate-limits a free key in seconds). Without
    retries the matrix run looks like a quality test failure when it's really an HTTP 429 storm.
    Retries are bounded so a real outage doesn't loop forever.
    """
    def wrapper(*args, **kwargs) -> Result:
        max_attempts = 5
        backoff = 1.0
        t0 = time.perf_counter()
        last_err: str | None = None
        for attempt in range(max_attempts):
            try:
                res: Result = func(*args, **kwargs)
                res.latency_ms = (time.perf_counter() - t0) * 1000
                return res
            except httpx.HTTPStatusError as e:
                last_err = f"HTTPStatusError: {e.response.status_code} {e.response.reason_phrase}"
                if e.response.status_code in (429, 500, 502, 503, 504) and attempt < max_attempts - 1:
                    # Respect Retry-After if the server set one; otherwise back off exponentially.
                    retry_after = e.response.headers.get("Retry-After")
                    delay = float(retry_after) if retry_after and retry_after.replace(".", "").isdigit() else backoff
                    delay += random.uniform(0, 0.5)  # jitter to spread retries
                    time.sleep(delay)
                    backoff = min(backoff * 2, 16.0)
                    continue
                break
            except Exception as e:
                last_err = f"{type(e).__name__}: {e}"
                break
        return Result(
            audio=b"",
            audio_format="mp3",
            latency_ms=(time.perf_counter() - t0) * 1000,
            error=last_err,
        )
    return wrapper

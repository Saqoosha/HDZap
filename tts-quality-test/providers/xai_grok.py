from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# xAI Grok TTS uses an OpenAI-compatible /v1/audio/speech endpoint.
# 5 stock voices, English-optimized but accept JA input.
XAI_VOICES = [
    Voice(id="eve", label="Eve", lang="ja"),
    Voice(id="ara", label="Ara", lang="ja"),
    Voice(id="rex", label="Rex", lang="ja"),
    Voice(id="eve", label="Eve", lang="en"),
    Voice(id="rex", label="Rex", lang="en"),
    Voice(id="leo", label="Leo", lang="en"),
]


class XAIGrok(ProviderBase):
    name = "xai_grok_tts"
    env_keys = ["XAI_API_KEY"]
    voices = XAI_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://api.x.ai/v1/audio/speech",
                headers={
                    "Authorization": f"Bearer {os.environ['XAI_API_KEY']}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "grok-tts-1",
                    "voice": voice.id,
                    "input": text,
                    "response_format": "mp3",
                },
            )
            r.raise_for_status()
            return Result(audio=r.content, audio_format="mp3", latency_ms=0)

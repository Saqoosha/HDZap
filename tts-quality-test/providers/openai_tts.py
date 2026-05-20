from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# OpenAI's 6 stock voices — all are English-optimized but speak JA via gpt-4o-mini-tts.
OPENAI_VOICES = [
    Voice(id="alloy", label="Alloy (neutral)", lang="ja"),
    Voice(id="nova", label="Nova (bright)", lang="ja"),
    Voice(id="echo", label="Echo (calm)", lang="ja"),
    Voice(id="alloy", label="Alloy (neutral)", lang="en"),
    Voice(id="nova", label="Nova (bright)", lang="en"),
    Voice(id="onyx", label="Onyx (deep)", lang="en"),
]


class OpenAIMiniTTS(ProviderBase):
    name = "openai_gpt4o_mini_tts"
    env_keys = ["OPENAI_API_KEY"]
    voices = OPENAI_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://api.openai.com/v1/audio/speech",
                headers={
                    "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "gpt-4o-mini-tts",
                    "voice": voice.id,
                    "input": text,
                    "response_format": "mp3",
                },
            )
            r.raise_for_status()
            return Result(audio=r.content, audio_format="mp3", latency_ms=0)

from __future__ import annotations

import base64
import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# Inworld TTS 1.5 supports prompt-based voice descriptions OR named stock voices.
# Stock JA voices: Asuka, Hiroshi, Yui (estimated from docs; replace if names differ).
INWORLD_VOICES = [
    Voice(id="Asuka", label="Asuka (JA female)", lang="ja"),
    Voice(id="Hiroshi", label="Hiroshi (JA male)", lang="ja"),
    Voice(id="Yui", label="Yui (JA female)", lang="ja"),
    Voice(id="Alex", label="Alex (EN male)", lang="en"),
    Voice(id="Diana", label="Diana (EN female)", lang="en"),
]


class InworldMini(ProviderBase):
    name = "inworld_tts_1_5_mini"
    env_keys = ["INWORLD_API_KEY"]
    voices = INWORLD_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://api.inworld.ai/tts/v1/voice",
                headers={
                    "Authorization": f"Basic {os.environ['INWORLD_API_KEY']}",
                    "Content-Type": "application/json",
                },
                json={
                    "text": text,
                    "voiceId": voice.id,
                    "modelId": "inworld-tts-1",
                    "audio_config": {
                        "audio_encoding": "MP3",
                        "sample_rate_hertz": 24000,
                    },
                },
            )
            r.raise_for_status()
            audio_b64 = r.json().get("audioContent", "")
            return Result(audio=base64.b64decode(audio_b64), audio_format="mp3", latency_ms=0)

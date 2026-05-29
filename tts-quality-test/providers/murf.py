from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# Murf Falcon JA voices. Names from https://murf.ai/api/docs/voices-styles/voice-library
# Picked the most natural-sounding ones from the JP catalog.
MURF_VOICES = [
    Voice(id="ja-JP-kenji", label="Kenji (male)", lang="ja"),
    Voice(id="ja-JP-kimi", label="Kimi (female)", lang="ja"),
    Voice(id="ja-JP-denki", label="Denki (male)", lang="ja"),
    Voice(id="en-US-natalie", label="Natalie (female)", lang="en"),
    Voice(id="en-US-terrell", label="Terrell (male)", lang="en"),
]


class MurfFalcon(ProviderBase):
    name = "murf_falcon"
    env_keys = ["MURF_API_KEY"]
    voices = MURF_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://api.murf.ai/v1/speech/generate",
                headers={
                    "api-key": os.environ["MURF_API_KEY"],
                    "Content-Type": "application/json",
                },
                json={
                    "voiceId": voice.id,
                    "text": text,
                    "format": "MP3",
                    "sampleRate": 24000,
                    "channelType": "MONO",
                    "modelVersion": "GEN2",  # Falcon model
                },
            )
            r.raise_for_status()
            # Murf returns a JSON envelope with `audioFile` URL — fetch the actual mp3.
            payload = r.json()
            audio_url = payload.get("audioFile") or payload.get("encodedAudio")
            if audio_url and audio_url.startswith("http"):
                audio = client.get(audio_url, timeout=30.0).content
                return Result(audio=audio, audio_format="mp3", latency_ms=0)
            # Some endpoints return base64 directly:
            import base64
            return Result(audio=base64.b64decode(audio_url), audio_format="mp3", latency_ms=0)

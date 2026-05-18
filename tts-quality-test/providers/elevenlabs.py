from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# Stock multilingual voices that handle JA and EN. IDs are stable across the v3 / Flash v2.5 models.
# Picked from https://elevenlabs.io/voice-library — these are the most-used "natural conversational"
# voices that ElevenLabs ships out of the box.
ELEVENLABS_VOICES_JA = [
    Voice(id="EXAVITQu4vr4xnSDxMaL", label="Sarah (warm)", lang="ja"),
    Voice(id="JBFqnCBsd6RMkjVDRZzb", label="George (calm)", lang="ja"),
    Voice(id="cgSgspJ2msm6clMCkdW9", label="Jessica (bright)", lang="ja"),
]
ELEVENLABS_VOICES_EN = [
    Voice(id="EXAVITQu4vr4xnSDxMaL", label="Sarah (warm)", lang="en"),
    Voice(id="JBFqnCBsd6RMkjVDRZzb", label="George (calm)", lang="en"),
    Voice(id="cgSgspJ2msm6clMCkdW9", label="Jessica (bright)", lang="en"),
]


class _ElevenLabsBase(ProviderBase):
    env_keys = ["ELEVENLABS_API_KEY"]
    voices = ELEVENLABS_VOICES_JA + ELEVENLABS_VOICES_EN
    model_id: str = ""

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice.id}"
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                url,
                headers={
                    "xi-api-key": os.environ["ELEVENLABS_API_KEY"],
                    "Content-Type": "application/json",
                    "Accept": "audio/mpeg",
                },
                json={
                    "text": text,
                    "model_id": self.model_id,
                    "output_format": "mp3_44100_128",
                    "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
                },
            )
            r.raise_for_status()
            return Result(audio=r.content, audio_format="mp3", latency_ms=0)


class ElevenLabsFlash(_ElevenLabsBase):
    name = "elevenlabs_flash_v2_5"
    model_id = "eleven_flash_v2_5"


class ElevenLabsMultilingual(_ElevenLabsBase):
    name = "elevenlabs_multilingual_v2"
    model_id = "eleven_multilingual_v2"

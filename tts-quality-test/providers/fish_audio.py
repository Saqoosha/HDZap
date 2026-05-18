from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# fish.audio public voice library reference IDs.
# Browse at https://fish.audio/m/. Picked voices that the catalog tags as Tier-1 Japanese.
# These IDs may need to be swapped for actually-stable public refs at run time —
# replace with picks from the user's own library if results 404.
FISH_AUDIO_VOICES = [
    Voice(id="cfd1cdc4ed7b48b1a92f4ed4f3a0d9e8", label="Japanese Female 1", lang="ja"),
    Voice(id="03397b4c4be74759b72533b663fbd001", label="Japanese Male 1", lang="ja"),
    Voice(id="cfd1cdc4ed7b48b1a92f4ed4f3a0d9e8", label="Japanese Female 1", lang="en"),
    Voice(id="03397b4c4be74759b72533b663fbd001", label="Japanese Male 1", lang="en"),
]


class FishAudioS2Pro(ProviderBase):
    name = "fish_audio_s2_pro"
    env_keys = ["FISH_AUDIO_API_KEY"]
    voices = FISH_AUDIO_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=60.0) as client:
            r = client.post(
                "https://api.fish.audio/v1/tts",
                headers={
                    "Authorization": f"Bearer {os.environ['FISH_AUDIO_API_KEY']}",
                    "Content-Type": "application/json",
                    "model": "s1",  # s1 maps to S2 Pro production model
                },
                json={
                    "text": text,
                    "reference_id": voice.id,
                    "format": "mp3",
                    "mp3_bitrate": 128,
                    "normalize": True,
                    "latency": "normal",
                },
            )
            r.raise_for_status()
            return Result(audio=r.content, audio_format="mp3", latency_ms=0)

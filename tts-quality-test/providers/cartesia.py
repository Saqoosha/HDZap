from __future__ import annotations

import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# Cartesia's three native Japanese voices, plus a couple of English ones for parity.
# Voice IDs from https://docs.cartesia.ai/build-with-cartesia/voices
# Voice IDs verified against the live `/voices` API on 2026-05-18.
# Picked the variety most relevant for FPV race-announcer use: expressive males, peppy females,
# at least one explicit Sportscaster persona for English.
CARTESIA_VOICES = [
    # JA — picks for race-announcer fit
    Voice(id="06950fa3-534d-46b3-93bb-f852770ea0b5", label="Takeshi (Hero / expressive male)", lang="ja"),
    Voice(id="9e7ef2cf-b69c-46ac-9e35-bbfd73ba82af", label="Ren (High-Energy Character)", lang="ja"),
    Voice(id="b8e1169c-f16a-4064-a6e0-95054169e553", label="Takashi (Professional, approachable)", lang="ja"),
    Voice(id="0cd0cde2-3b93-42b5-bcb9-f214a591aa29", label="Sayuri (Peppy Colleague / bright female)", lang="ja"),
    Voice(id="2b568345-1d48-4047-b25f-7baccf842eb0", label="Yumiko (Friendly Agent / upbeat female)", lang="ja"),
    Voice(id="44863732-e415-4084-8ba1-deabe34ce3d2", label="Kaori (Friendly Narrator)", lang="ja"),
    Voice(id="498e7f37-7fa3-4e2c-b8e2-8b6e9276f956", label="Aiko (Calming Voice)", lang="ja"),
    # EN — Scott the Sportscaster is the obvious pick for race calls
    Voice(id="2f22b9bc-b0eb-4cb6-b5ae-0c099a0fdfad", label="Scott (Sportscaster)", lang="en"),
    Voice(id="820a3788-2b37-4d21-847a-b65d8a68c99a", label="Tyler (Friendly Salesman)", lang="en"),
    Voice(id="710feaa3-b550-42f3-b3eb-6f37f2a7cc0a", label="Tanner (Upbeat Assistant)", lang="en"),
    Voice(id="62305e79-9d39-4643-b003-5e0b096fe4f4", label="Madison (Happy Best Friend)", lang="en"),
    Voice(id="d3e03deb-5439-4203-add1-ca9a7501eaa7", label="Samantha (Firm female)", lang="en"),
    Voice(id="d6b0c62a-c7ff-477c-9a1f-eadd64b94360", label="Melina (Bright Spirit)", lang="en"),
    Voice(id="ab109683-f31f-40d7-b264-9ec3e26fb85e", label="Russell (Mentor / mature male)", lang="en"),
]


class CartesiaSonic35(ProviderBase):
    name = "cartesia_sonic_3_5"
    env_keys = ["CARTESIA_API_KEY"]
    voices = CARTESIA_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://api.cartesia.ai/tts/bytes",
                headers={
                    "X-API-Key": os.environ["CARTESIA_API_KEY"],
                    "Cartesia-Version": "2024-11-13",
                    "Content-Type": "application/json",
                },
                json={
                    "model_id": "sonic-3.5",
                    "transcript": text,
                    "voice": {"mode": "id", "id": voice.id},
                    "output_format": {
                        "container": "mp3",
                        "bit_rate": 128000,
                        "sample_rate": 44100,
                    },
                    "language": {"ja": "ja", "en": "en"}[lang],
                },
            )
            r.raise_for_status()
            return Result(audio=r.content, audio_format="mp3", latency_ms=0)

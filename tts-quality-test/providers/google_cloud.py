from __future__ import annotations

import base64
import os

import httpx

from .base import ProviderBase, Result, Voice, timed


# Chirp 3 HD voices for JA and EN. Names follow Google's
# https://cloud.google.com/text-to-speech/docs/chirp3-hd convention.
GOOGLE_CLOUD_VOICES = [
    Voice(id="ja-JP-Chirp3-HD-Achernar", label="Achernar (calm female)", lang="ja"),
    Voice(id="ja-JP-Chirp3-HD-Algieba", label="Algieba (warm male)", lang="ja"),
    Voice(id="ja-JP-Chirp3-HD-Charon", label="Charon (energetic male)", lang="ja"),
    Voice(id="en-US-Chirp3-HD-Achernar", label="Achernar (calm female)", lang="en"),
    Voice(id="en-US-Chirp3-HD-Algieba", label="Algieba (warm male)", lang="en"),
    Voice(id="en-US-Chirp3-HD-Charon", label="Charon (energetic male)", lang="en"),
]


def _gcp_access_token() -> str:
    """Mint an OAuth token from the service-account JSON pointed to by GOOGLE_APPLICATION_CREDENTIALS."""
    try:
        from google.oauth2 import service_account
        from google.auth.transport.requests import Request
    except ImportError as e:
        raise RuntimeError(
            "google-auth not installed — `uv pip install google-auth google-auth-httplib2`"
        ) from e
    path = os.environ["GOOGLE_APPLICATION_CREDENTIALS"]
    creds = service_account.Credentials.from_service_account_file(
        path, scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(Request())
    return creds.token


class GoogleChirp3HD(ProviderBase):
    name = "google_cloud_chirp3_hd"
    env_keys = ["GOOGLE_APPLICATION_CREDENTIALS"]
    voices = GOOGLE_CLOUD_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        # Chirp 3 HD only accepts language codes that match the voice prefix.
        language_code = voice.id.split("-Chirp3")[0]
        token = _gcp_access_token()
        with httpx.Client(timeout=30.0) as client:
            r = client.post(
                "https://texttospeech.googleapis.com/v1/text:synthesize",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                json={
                    "input": {"text": text},
                    "voice": {"languageCode": language_code, "name": voice.id},
                    "audioConfig": {"audioEncoding": "MP3", "sampleRateHertz": 24000},
                },
            )
            r.raise_for_status()
            audio_b64 = r.json()["audioContent"]
            return Result(audio=base64.b64decode(audio_b64), audio_format="mp3", latency_ms=0)

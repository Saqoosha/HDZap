from __future__ import annotations

import base64
import os
import struct

import httpx

from .base import ProviderBase, Result, Voice, timed


# Gemini 2.5 Flash TTS prebuilt voices. Same voice IDs work for any supported language.
# https://ai.google.dev/gemini-api/docs/speech-generation#voices
GEMINI_VOICES_BASE = [
    ("Kore", "Kore (firm)"),
    ("Charon", "Charon (informative)"),
    ("Puck", "Puck (upbeat)"),
    ("Aoede", "Aoede (breezy)"),
    ("Fenrir", "Fenrir (excitable)"),
]

GEMINI_VOICES = [Voice(id=vid, label=label, lang="ja") for vid, label in GEMINI_VOICES_BASE] + [
    Voice(id=vid, label=label, lang="en") for vid, label in GEMINI_VOICES_BASE
]


def _pcm_to_wav(pcm: bytes, sample_rate: int = 24000, channels: int = 1, bits: int = 16) -> bytes:
    """Wrap raw PCM in a WAV container. Gemini returns 24kHz s16le mono.

    Browsers and AVAudioPlayer both want a header before they decode the audio, so we synthesize
    a minimal RIFF/WAVE chunk and prepend it.
    """
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    data_size = len(pcm)
    header = b"RIFF"
    header += struct.pack("<I", 36 + data_size)
    header += b"WAVE"
    header += b"fmt "
    header += struct.pack("<I", 16)
    header += struct.pack("<H", 1)  # PCM
    header += struct.pack("<H", channels)
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", byte_rate)
    header += struct.pack("<H", block_align)
    header += struct.pack("<H", bits)
    header += b"data"
    header += struct.pack("<I", data_size)
    return header + pcm


class GeminiFlashTTS(ProviderBase):
    name = "google_gemini_2_5_flash_tts"
    env_keys = ["GEMINI_API_KEY"]
    voices = GEMINI_VOICES

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        url = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            f"gemini-2.5-flash-preview-tts:generateContent?key={os.environ['GEMINI_API_KEY']}"
        )
        with httpx.Client(timeout=60.0) as client:
            r = client.post(
                url,
                headers={"Content-Type": "application/json"},
                json={
                    "contents": [{"parts": [{"text": text}]}],
                    "generationConfig": {
                        "responseModalities": ["AUDIO"],
                        "speechConfig": {
                            "voiceConfig": {
                                "prebuiltVoiceConfig": {"voiceName": voice.id}
                            }
                        },
                    },
                },
            )
            r.raise_for_status()
            payload = r.json()
            inline = payload["candidates"][0]["content"]["parts"][0]["inlineData"]
            pcm = base64.b64decode(inline["data"])
            return Result(audio=_pcm_to_wav(pcm), audio_format="wav", latency_ms=0)

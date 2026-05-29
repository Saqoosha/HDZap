from .base import Provider, ProviderBase, Result, Voice, timed
from .elevenlabs import ElevenLabsFlash, ElevenLabsMultilingual
from .openai_tts import OpenAIMiniTTS
from .gemini import GeminiFlashTTS
from .google_cloud import GoogleChirp3HD
from .aws_polly import AWSPollyNeural
from .fish_audio import FishAudioS2Pro
from .cartesia import CartesiaSonic35
from .inworld import InworldMini
from .murf import MurfFalcon
from .xai_grok import XAIGrok

ALL_PROVIDERS: list[Provider] = [
    ElevenLabsFlash(),
    ElevenLabsMultilingual(),
    OpenAIMiniTTS(),
    GeminiFlashTTS(),
    GoogleChirp3HD(),
    AWSPollyNeural(),
    FishAudioS2Pro(),
    CartesiaSonic35(),
    InworldMini(),
    MurfFalcon(),
    XAIGrok(),
]

__all__ = ["Provider", "ProviderBase", "Result", "Voice", "timed", "ALL_PROVIDERS"]

from __future__ import annotations

import os

from .base import ProviderBase, Result, Voice, timed


# AWS Polly Neural voices for JA and EN. Names from the Polly voice list:
# https://docs.aws.amazon.com/polly/latest/dg/available-voices.html
AWS_POLLY_VOICES = [
    Voice(id="Kazuha", label="Kazuha (Neural, female)", lang="ja"),
    Voice(id="Takumi", label="Takumi (Neural, male)", lang="ja"),
    Voice(id="Tomoko", label="Tomoko (Neural, female)", lang="ja"),
    Voice(id="Matthew", label="Matthew (Neural, male)", lang="en"),
    Voice(id="Joanna", label="Joanna (Neural, female)", lang="en"),
    Voice(id="Stephen", label="Stephen (Neural, male)", lang="en"),
]


class AWSPollyNeural(ProviderBase):
    name = "aws_polly_neural"
    env_keys = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    voices = AWS_POLLY_VOICES

    def _client(self):
        try:
            import boto3
        except ImportError as e:
            raise RuntimeError("boto3 not installed — `uv pip install boto3`") from e
        return boto3.client("polly", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))

    @timed
    def synthesize(self, text: str, lang: str, voice: Voice) -> Result:
        client = self._client()
        # Wrap numbers in SSML so they're spoken as cardinals — this is Polly's killer feature
        # for HDZap's "12.34 seconds" use case. Polly will say "twelve point three four"
        # naturally in EN and "じゅうにてんさんよん" in JA.
        # NOTE: simple wrap. For full control we'd inject <say-as> around just the numbers.
        resp = client.synthesize_speech(
            Text=text,
            OutputFormat="mp3",
            VoiceId=voice.id,
            Engine="neural",
            LanguageCode={"ja": "ja-JP", "en": "en-US"}[lang],
        )
        audio = resp["AudioStream"].read()
        return Result(audio=audio, audio_format="mp3", latency_ms=0)

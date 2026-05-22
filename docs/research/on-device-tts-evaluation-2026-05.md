# On-device TTS evaluation (2026-05)

## TL;DR

**Verdict: stay with cloud Premium TTS (AWS Polly + Microsoft Azure).**

Two open-weight on-device TTS systems were evaluated as candidates to replace HDZap's current Cloudflare Worker–backed Premium TTS. Both failed for HDZap's specific use case:

- **Supertonic 3** (99 M params, ONNX, OpenRAIL-M) — works on-device, Japanese supported, but latency 490–1100 ms on iPhone Air for HDZap utterances vs current cloud TTFA 60–150 ms; audio quality "not bad but not better than Polly Takumi"; app size +415 MB. Net advantage reduces to "offline-only".
- **Kokoro-82M** (Apache 2.0, smaller, faster) — quantized model 88 MB; ~2-3× faster than Supertonic at equivalent text length; **but the model is unintelligible on short utterances** (≤ 10 tokens), exactly HDZap's countdown case ("3", "2", "1", "スタート"). Confirmed by listening to the synthesised audio.

A hybrid (Kokoro for lap announcements + something else for countdowns) would maintain two pipelines for one disputed benefit (offline), and is not justified.

## Why we evaluated

HDZap's Premium TTS currently goes through `workers/hdzap-premium/` to AWS Polly and Microsoft Azure. Costs scale with usage, requires network connectivity at the race venue (sometimes flaky), and adds first-byte latency (60–150 ms streaming PCM). On-device would eliminate all three.

## Benchmark methodology

Same 15 HDZap-specific cases run against both models, capturing per-call wall-clock latency, output audio duration, and the resulting WAV file for subjective quality review.

Cases cover the three utterance shapes HDZap actually produces:

| Shape | Examples |
|---|---|
| Countdown (1-2 tokens) | "3", "2", "1", "スタート" |
| Lap announcement (8-15 tokens) | "ラップ5、12秒34", "Lap 5, 12.34", "ファイナルラップです" |
| Long announcement (~25 tokens) | "ラップ12、ベストラップ、1分08秒56" |

For Supertonic: the `nfe` (denoising steps) parameter was varied across {5, 8, 12}. For Kokoro: `speed` was varied across {0.85, 1.0, 1.3}.

The benchmark harness ran on real hardware:

- **Supertonic**: iPhone Air (iPhone18,4) running iOS 26.5, modified ExampleiOSApp from upstream `supertone-inc/supertonic`, signed with the WHATEVER team. Timings emitted via `os.Logger` and a `Documents/tts.log` file, pulled afterwards via `xcrun devicectl device copy from`.
- **Kokoro**: Mac M-series CPU (Python 3.12, `kokoro` PyPI 0.9.4 + `misaki[ja]` for Japanese G2P + pyopenjtalk + unidic). Mac CPU is roughly 2× faster than the iPhone Air for these workloads, so iPhone numbers would be proportionally slower; this is acknowledged in the comparison below.

## Results

### Supertonic 3 (iPhone Air, NFE=8 unless noted)

| Case | Elapsed | Audio | RTF |
|---|---|---|---|
| ja "3" | 495 ms | 1.29 s | 0.38 |
| ja "スタート" | 493 ms | 1.32 s | 0.37 |
| ja "ラップ5、12秒34" | 753 ms | 2.41 s | 0.31 |
| ja "ラップ12、ベストラップ、1分08秒56" | 1089 ms | 3.90 s | 0.28 |
| ja "ファイナルラップです" | 581 ms | 1.77 s | 0.33 |
| ja lap, NFE=5 | 512 ms | 2.41 s | 0.21 |
| ja lap, NFE=12 | 1158 ms | 2.41 s | 0.48 |
| en "Lap 5, 12.34" | 801 ms | 2.23 s | 0.36 |

NFE scales latency roughly linearly. Voice gender (M vs F) does not affect latency.

App binary including all four ONNX models (duration_predictor 3.5 MB + text_encoder 35 MB + vector_estimator 245 MB + vocoder 97 MB) is 415 MB.

### Kokoro-82M (Mac M-series CPU, hot path)

| Case | Elapsed | Audio | RTF |
|---|---|---|---|
| ja "2" | 149 ms | 0.60 s | 0.25 |
| ja "1" | 203 ms | 1.23 s | 0.17 |
| ja "スタート" | 182 ms | 1.03 s | 0.18 |
| ja "ラップ5、12秒34" | 346 ms | 2.73 s | 0.13 |
| ja "ラップ12、ベストラップ、1分08秒56" | 506 ms | 4.05 s | 0.13 |
| ja "ファイナルラップです" | 299 ms | 2.00 s | 0.15 |
| en "Lap 5, 12.34" | 337 ms | 2.48 s | 0.14 |

Cold-start (first call after model load or voice switch) adds ~1.3-1.5 s; excluded from the hot-path table.

Available variants on Hugging Face: fp32 310 MB, fp16 155 MB, INT8 quantized 88 MB.

### Subjective audio quality

- **Supertonic** — intelligible on all cases; tone roughly comparable to Polly Takumi but with audible neural-vocoder artifacts on short utterances. Not better than the current cloud baseline.
- **Kokoro** — natural and clear on lap announcements (≥ 8 tokens). **Countdown utterances are unintelligible** ("3", "2", "1", "スタート", "Go"): the synthesiser produces something but the spoken word is not recognisable. This matches the upstream README's documented weakness: *"Voices may perform worse … Weakness on short utterances, especially less than 10-20 tokens. Root cause could be lack of short-utterance training data and/or model architecture."*

## What blocks each candidate

### Supertonic 3

- **Latency** — 490 ms on countdown vs the ~60 ms TTFA we get today through streamed Polly PCM. The model is non-streaming (returns the full WAV), so this latency is wall-time before the user hears anything.
- **Quality** — comparable to Polly Takumi, not noticeably better.
- **Size** — bundling all four ONNX files adds ~382 MB to the app; only an on-device download (App Thinning / ODR / custom CDN) would keep the install reasonable.

The only remaining net win is offline operation. For HDZap's typical race-venue connectivity, that is real but not large enough to outweigh the latency regression and the size cost.

### Kokoro-82M

- **Short-utterance failure mode** — countdown is HDZap's most critical and most-used utterance shape, and Kokoro cannot synthesise it intelligibly. This is a model architecture limitation, not a tuning knob.
- **Japanese on iOS would require porting `misaki.ja` (pyopenjtalk + unidic + cutlet) to Swift.** Currently only the English Swift port exists (`mattmireles/kokoro-coreml`, ANE-optimised, 17× realtime on M2 Ultra). The Japanese G2P chain is a multi-day port at minimum.

Even if both were solved, Kokoro alone would still cover only the lap-announcement utterances, requiring a second TTS for countdowns and defeating the simplification a single on-device pipeline would provide.

## When to re-evaluate

Trigger conditions that would justify revisiting:

- Supertonic v4 ships with streaming output (would close the latency gap).
- Supertonic v3 OnnxSlim variant lands publicly with measured 30 %+ size reduction.
- An official CoreML or ANE conversion of either model is published for Japanese.
- Kokoro's short-utterance failure is addressed upstream (the README does not commit to a fix).
- Race-venue connectivity becomes a hard product requirement for HDZap (e.g. a customer-reported regression that we cannot solve through caching).

## Artifacts produced by this investigation (worth carrying forward)

These are independent of the verdict and useful regardless of whether HDZap ever revisits on-device TTS.

### Reliable iOS app log fetch for measurement runs

`NSLog` from Swift on a non-attached run goes through the unified log but variable values get redacted to `<private>` by default — that is what made our first measurement attempt produce no usable data. The pattern that worked:

1. **`os.Logger` with `privacy: .public`** on every interpolated value:
   ```swift
   import os
   private let log = Logger(subsystem: "<bundle id>", category: "<topic>")
   log.info("elapsed=\(elapsed, privacy: .public)s")
   ```
   Captured live via `pymobiledevice3 syslog live -m <process>` and a tight `grep --line-buffered` filter.

2. **Mirror to a file in `Documents/`** for guaranteed-complete capture (live syslog can drop lines under load):
   ```swift
   let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
       .appendingPathComponent("tts.log")
   // append-mode write
   ```
   Set `UIFileSharingEnabled = true` in Info.plist so the container is pullable.

3. **Pull the file after the run** with `xcrun devicectl`:
   ```
   xcrun devicectl device copy from \
     --device <UDID> \
     --domain-type appDataContainer \
     --domain-identifier <bundle id> \
     --source "/Documents" --destination "results/"
   ```

This pattern is reusable for any future HDZap diagnostic that needs offline log capture from a real device — not just TTS work.

### Repeatable benchmark harness

The 15-case shape used here (countdown / lap-short / lap-long / NFE-or-speed sweep / male-voice / English-equivalent) is the right test surface for HDZap. The Supertonic harness lives in commit history under the worktree branch `feature/supertonic-investigation` (now removed); to recreate, the shape is documented above.

## Sources

- Supertonic: <https://github.com/supertone-inc/supertonic> (MIT code, OpenRAIL-M model)
- Kokoro-82M: <https://huggingface.co/hexgrad/Kokoro-82M> (Apache 2.0)
- Kokoro CoreML port (English-only, ANE-optimised): <https://github.com/mattmireles/kokoro-coreml>
- Voice Builder ToS (kept for reference, scope-out): <https://supertone.notion.site/voice-builder-terms-of-service>

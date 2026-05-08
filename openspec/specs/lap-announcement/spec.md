# lap-announcement Specification

## Purpose

Speak each lap aloud through the device speaker so the operator gets audio confirmation without looking at the phone, with bilingual (en / ja) phrasing, voice / rate / pitch customization, and audio-session behavior that coexists with music apps and survives a silent ringer switch.

## Requirements

### Requirement: Bilingual announcement / バイリンガルアナウンス

The system SHALL support exactly two announcement languages: English (`en`) and Japanese (`ja`). The default at first launch SHALL be derived from `Locale.current.language.languageCode` — a Japanese device gets Japanese announcements, every other locale falls back to English. The user SHALL be able to override the choice via Settings.

Adding a third language is a follow-up change, not a silent fallback. 中途半端な third-language fallback は voice / phrase の不一致を生むため明示的に拒否する。

#### Scenario: Default on a Japanese device
- Given a fresh install on `ja-JP` locale
- When the app registers UserDefaults defaults
- Then `lapTTSLanguage` defaults to `"ja"`
- And the first lap announcement uses Japanese phrasing and a `ja-*` voice

### Requirement: Voice picker filters by language / 音声ピッカーは言語フィルタ

The voice picker SHALL list only voices whose language tag has the prefix matching the selected announcement language (`en` → `en-*`, `ja` → `ja-*`). When the language is changed in Settings, the saved `lapTTSVoiceIdentifier` SHALL be cleared. If the saved identifier resolves to a voice in a different language at runtime (Shortcuts/MDM/iCloud-sync write, region change), the system SHALL log and fall back to the system default voice for the selected language.

`AVSpeechSynthesizer` に違う言語の voice を渡すと数字を誤読する (e.g. `ja-JP` voice で `Lap 5` を読ませると意味不明な音になる)。語と voice を一致させ続けることが大原則。

#### Scenario: Language switch clears voice
- Given the user has selected the `Kyoko` ja-JP voice
- When the user changes language to English in Settings
- Then `lapTTSVoiceIdentifier` is cleared
- And the next announcement uses the system default `en-US` voice

### Requirement: Voice quality ranking / 音声品質ランキング

The voice picker SHALL sort voices Premium → Enhanced → Default (Standard), then alphabetically by language and name. The picker SHALL include a "System default" entry (id == empty string) so selection works even when no language-matching voices are installed.

`AVSpeechSynthesisVoiceQuality` の `@unknown default` は `.standard` にマップする。新 SDK が追加した未知の tier を `.standard` に押し込むので、ピッカー底辺に紛れて quality 認識ミスが目立つように設計する。

#### Scenario: New voice install detected
- Given the user installs an Enhanced en-US voice via iOS Settings
- When the picker is opened
- Then the new voice appears in the Enhanced bucket
- And the voice list dump in unified logging records the diff

### Requirement: Rate and pitch ranges / Rate と Pitch の範囲

`rate` SHALL be clamped to `[0.30, 0.65]` (defaults to `0.5`). `pitch` SHALL be clamped to `[0.75, 1.5]` (defaults to `1.0`). Defaults SHALL be exposed as Swift constants and registered with `UserDefaults.register(defaults:)` at launch.

`defaultRate` MUST equal `AVSpeechUtteranceDefaultSpeechRate` at build time; a debug assertion SHALL trip if a future SDK retunes that constant away from the value compiled into HDZap.

実測した可読域。0.30 未満は voice によっては聞き取り不能、0.65 超は ms 単位の値が連結されて時間が読み取れなくなる。

#### Scenario: User sets rate above max
- Given the user moves the slider to 0.80 (somehow)
- When `currentRate()` reads the value
- Then the returned rate is clamped to 0.65

### Requirement: Per-lap announcement phrasing / ラップごとの読み上げ表現

The system SHALL announce each lap as:

- English: `"Lap <id>, <time>"` for normal laps, `"Lap <id>, <time>, best lap"` when `isBest && announceBest`. `<time>` SHALL be the lap time **truncated** (not rounded) to hundredths, formatted `S.SS` with a leading zero in the fractional part.
- Japanese: `"ラップ<id>、<time>"` / `"ラップ<id>、<time>、ベストラップ"`.

`announceBest` SHALL default to `true` and be user-toggleable.

「12.345 → 12.34」と truncate 固定。`%.2f` で round すると画面表示 (floor to ms) と読み上げが異なる事故 (`18.005s` 表示 `18.00`、読み上げ `18.01秒`) を起こすため明示。

#### Scenario: Announce best lap in Japanese
- Given language = ja, announceBest = true, lap = (id 5, time 12.345), isBest = true
- When `announceLap(lap, isBest: true)` is called
- Then the spoken phrase is `"ラップ5、12.34、ベストラップ"`

#### Scenario: Suppress best-lap suffix
- Given announceBest = false
- When `announceLap(lap, isBest: true)` is called
- Then the spoken phrase is the normal-lap form (no "best lap" / "ベストラップ" suffix)

### Requirement: Race-final summary / レース終了時のサマリ読み上げ

The system SHALL announce a race-final summary on the FINAL button path: `"<final lap?> Total <count> laps in <total time>. Best lap was <best>."` (English) / `"ラップN <time>秒、トータル<count>周、<total>、ベストラップは<best>秒でした"` (Japanese).

When invoked from the manual STOP path, the caller SHALL pass `lastLap = nil` so the just-announced lap is not duplicated. When invoked from the FINAL button, the caller SHALL pass the just-recorded lap so the summary preempts the per-lap callout into a single utterance.

`englishMinSecString` / `japaneseMinSecString` は 60 s 以上で minutes を入れ、未満で seconds のみを返す。`0 minutes 45.66 seconds` のような不自然な読みを避ける。

#### Scenario: Race ended via FINAL button
- Given the operator taps FINAL after recording lap 3
- When `announceFinal(lastLap: lap3, lapCount: 3, totalTime: 38.5, bestLapTime: 12.0)` is called
- Then the per-lap callout is replaced by the summary in one utterance

### Requirement: Audio session category and routing / オーディオセッションのカテゴリとルーティング

The synthesizer SHALL configure `AVAudioSession` with category `.playback`, mode `.spokenAudio`, options `[.duckOthers]`. Activation SHALL be deferred until the first announcement so users who never enable TTS aren't disturbed.

`.playback` ensures announcements play even when the silent ringer switch is on (the phone often sits in a chest pocket during a race). `.spokenAudio` tells iOS this is speech, not music — Bluetooth devices stop staying ducked between announcements. `.duckOthers` lets the operator's playlist keep playing at a lower volume during each announcement.

After each utterance ends or is canceled, the session SHALL be deactivated with `[.notifyOthersOnDeactivation]` so other apps' audio fully un-ducks.

`setActive(true)` (50–200 ms) と `setActive(false)` (100–300 ms) はメインアクターで実行すると UI ヒッチが目に見えるため、`audioSessionQueue` (serial) で実行する。

#### Scenario: Activation failure surfaces error
- Given another app holds an exclusive audio category
- When `configureSessionIfNeeded` runs
- Then `setActive(true)` throws
- And `lastAudioError` carries a user-facing message
- And a UINotificationFeedbackGenerator error haptic fires
- And `sessionConfigured` returns to `false` so the next announcement retries activation

### Requirement: Drop-and-replace on rapid laps / 高速タップ時のドロップ・置換

When laps fire faster than the synthesizer can speak them, the most recent lap SHALL preempt any in-flight or queued utterance via `synthesizer.stopSpeaking(at: .immediate)`. The operator wants the latest time, not a backlog running seconds behind the actual race.

#### Scenario: Two taps within 500 ms
- Given lap 4 announcement is mid-utterance
- When the user taps LAP for lap 5
- Then the lap-4 utterance is canceled
- And lap-5 plays immediately

### Requirement: Race-start beep / レース開始のビープ

When the operator taps START to begin a race, the system SHALL announce "Start" (en) or "スタート" (ja). This doubles as a warm-up for the audio session so the first lap announcement is not delayed by the initial `setActive(true)` round-trip.

#### Scenario: Cold start announcement
- Given the app has never spoken before this launch
- When the operator taps START
- Then "Start" plays immediately
- And the next lap announcement does not pay the activation latency

### Requirement: Test-voice preview / 音声プレビュー

The system SHALL expose a Test Voice action that announces a fixed sample (`Lap 3, 12.34, best lap` / `ラップ3、12.34、ベストラップ`) regardless of the `announceBest` setting so the user can audition every phrase piece before relying on it during a race.

#### Scenario: Tap Test Voice
- Given the user is on the Settings audio screen
- When the user taps Test Voice
- Then the sample utterance plays with the currently-selected voice / rate / pitch

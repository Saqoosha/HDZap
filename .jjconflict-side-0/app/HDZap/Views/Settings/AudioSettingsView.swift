import SwiftUI

/// Lap announcer (TTS) configuration. Drilldown sub-screen so the
/// language-conditional voice list, rate / pitch sliders, and
/// missing-voice banners have room to render without crowding the root.
struct AudioSettingsView: View {
    @Environment(LapAnnouncer.self) private var announcer
    @AppStorage(LapAnnouncerDefaults.enabledKey) private var lapTTSEnabled
        = LapAnnouncerDefaults.defaultEnabled
    @AppStorage(LapAnnouncerDefaults.languageKey) private var ttsLanguageRaw
        = LapAnnouncerDefaults.defaultLanguageRaw
    @AppStorage(LapAnnouncerDefaults.announceBestKey) private var announceBest
        = LapAnnouncerDefaults.defaultAnnounceBest
    @AppStorage(LapAnnouncerDefaults.voiceIdentifierKey) private var voiceIdentifier
        = LapAnnouncerDefaults.defaultVoiceIdentifier
    @AppStorage(LapAnnouncerDefaults.rateKey) private var ttsRate: Double
        = Double(LapAnnouncerDefaults.defaultRate)
    @AppStorage(LapAnnouncerDefaults.pitchKey) private var ttsPitch: Double
        = Double(LapAnnouncerDefaults.defaultPitch)

    var body: some View {
        // Re-snapshot the voice list on every body eval — language picker
        // changes trigger this via `@AppStorage`. A voice installed in
        // iOS Settings while we're on screen won't show up until something
        // else drives a re-eval (toggling the section, popping back to
        // the Settings root and re-entering, or dismissing the whole
        // Settings sheet); acceptable since installing a voice also
        // requires leaving the app.
        let language = LapAnnouncerLanguage(rawValue: ttsLanguageRaw) ?? .english
        let voices = LapAnnouncerVoiceCatalog.availableVoices(for: language)
        let voiceMissing = !voiceIdentifier.isEmpty
            && !voices.contains(where: { $0.id == voiceIdentifier })
        let hasPremium = voices.contains(where: { $0.quality == .premium })
        return List {
            Section {
                Toggle("Announce lap times", isOn: $lapTTSEnabled)

                if lapTTSEnabled {
                    Picker("Language", selection: $ttsLanguageRaw) {
                        ForEach(LapAnnouncerLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .onChange(of: ttsLanguageRaw) { _, _ in
                        // The previously-picked voice almost certainly belongs
                        // to the old language; clear it so the picker falls
                        // back to "System default" for the new language rather
                        // than getting silently overridden by `currentVoice()`.
                        voiceIdentifier = LapAnnouncerDefaults.defaultVoiceIdentifier
                    }

                    Toggle("Say \"best lap\" on new best", isOn: $announceBest)

                    Picker("Voice", selection: $voiceIdentifier) {
                        Text("System default").tag(LapAnnouncerDefaults.defaultVoiceIdentifier)
                        ForEach(voices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }

                    if voices.isEmpty {
                        // No voices installed at all for the selected language —
                        // most common cause is the user picked a language whose
                        // base voice was never bundled (rare) or trimmed during
                        // an iOS reinstall. Point them at Settings and surface
                        // the issue so they don't blame the announcer.
                        Text("No voices installed for this language. Install one from iOS Settings → Accessibility → Spoken Content → Voices.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !hasPremium && language == .japanese {
                        // Japanese-specific nudge: Kyoko / Otoya / O-ren
                        // Enhanced are markedly better than the compact
                        // base voices. Apple's "Siri Voice 1/2" bundles
                        // look like the obvious top tier in iOS Settings,
                        // but they're locked out of AVSpeechSynthesizer for
                        // third-party apps (selecting one falls back to
                        // a substitute), so we deliberately don't recommend
                        // them here.
                        Text("Tip: install Kyoko / Otoya / O-ren Enhanced from iOS Settings → Accessibility → Spoken Content → Voices for noticeably better quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if voiceMissing {
                        // The previously-picked voice was uninstalled (or the
                        // user restored to a different device that doesn't have
                        // it). LapAnnouncer also logs and falls back to the
                        // system default for the current language; this banner
                        // is purely UX so the user knows why the voice changed.
                        Text("Selected voice is no longer installed — falling back to the system default.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let audioError = announcer.lastAudioError {
                        // AVAudioSession activation failed — most often because
                        // another app holds an exclusive audio category (Voice
                        // Memos, active call). Surfacing it here means the
                        // operator can see why announcements went silent
                        // without leaving the app for Console.
                        Text(audioError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Rate")
                            Spacer()
                            Text(String(format: "%.2f", ttsRate))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $ttsRate,
                            in: Double(LapAnnouncerDefaults.minRate)...Double(LapAnnouncerDefaults.maxRate),
                            step: 0.05
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pitch")
                            Spacer()
                            Text(String(format: "%.2f", ttsPitch))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $ttsPitch,
                            in: Double(LapAnnouncerDefaults.minPitch)...Double(LapAnnouncerDefaults.maxPitch),
                            step: 0.05
                        )
                    }

                    HStack {
                        Button("Test voice") { announcer.announceTest() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Reset", role: .destructive) {
                            // Restores every Audio @AppStorage key to the value
                            // registered in HDZapApp.init(), including the master
                            // toggle — otherwise "Reset" leaves TTS enabled while
                            // claiming defaults were restored. All defaults route
                            // through `LapAnnouncerDefaults` so a future tweak to
                            // the registered default propagates here in one edit.
                            lapTTSEnabled = LapAnnouncerDefaults.defaultEnabled
                            ttsRate = Double(LapAnnouncerDefaults.defaultRate)
                            ttsPitch = Double(LapAnnouncerDefaults.defaultPitch)
                            ttsLanguageRaw = LapAnnouncerDefaults.defaultLanguageRaw
                            voiceIdentifier = LapAnnouncerDefaults.defaultVoiceIdentifier
                            announceBest = LapAnnouncerDefaults.defaultAnnounceBest
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } footer: {
                // Two notes the operator wouldn't otherwise know:
                // 1. Why announcements still play with the ringer off (the
                //    answer is the AVAudioSession `.playback` category we set —
                //    cued here so the behavior doesn't read as a bug).
                // 2. Why a voice they expect to see isn't in the picker — iOS
                //    ships only a base voice; better-quality voices are an
                //    opt-in download.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plays through the speaker even when the ringer switch is silent. Other audio is briefly ducked during each announcement.")
                    Text("More voices: Settings → Accessibility → Spoken Content → Voices.")
                }
                .font(.caption2)
            }
        }
        .navigationTitle("Lap announcer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

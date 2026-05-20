import SwiftUI

/// Lap announcer (TTS) configuration. Drilldown sub-screen so the
/// language-conditional voice list, rate / pitch sliders, and
/// missing-voice banners have room to render without crowding the root.
struct AudioSettingsView: View {
    @Environment(LapAnnouncer.self) private var announcer
    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingPaywall = false
    /// Programmatic navigation trigger — set true when the operator taps the locked
    /// "Premium — Subscribe ›" tag in the Engine picker so we can push the voice picker
    /// (the conversion surface) instead of popping a modal paywall.
    @State private var navigateToPicker = false
#if DEBUG
    // Premium TTS test harness — only compiled into Debug builds. Production code will
    // create the synth via SubscriptionManager + SpeechRouter; this @State instance is just
    // for end-to-end audition before that wiring lands.
    @State private var premiumSynth = PremiumSpeechSynthesizer()
    @AppStorage(PremiumTTSDevDefaults.workerURLKey) private var premiumWorkerURL
        = PremiumTTSDevDefaults.defaultWorkerURL
    @AppStorage(PremiumTTSDevDefaults.bearerKey) private var premiumBearer = ""
    @AppStorage(PremiumTTSDevDefaults.voiceIdKey) private var premiumVoiceId
        = PremiumTTSDevDefaults.defaultVoiceId
    @State private var premiumTestText = "ラップ3、12.34、ベストラップ"
    @State private var premiumErrorBanner: String?
#endif
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
    @AppStorage(LapAnnouncerDefaults.countdownEnabledKey) private var countdownEnabled
        = LapAnnouncerDefaults.defaultCountdownEnabled
    @AppStorage(LapAnnouncerDefaults.countdownStartSecondsKey) private var countdownStartSeconds
        = LapAnnouncerDefaults.defaultCountdownStartSeconds
    // Premium engine selection — production-facing (not DEBUG) so the operator can opt in to
    // the cloud TTS path during a race. Empty `premiumVoiceId` means "no voice picked yet";
    // LapAnnouncer treats that as a fallthrough back to the system path.
    @AppStorage(LapAnnouncerDefaults.engineKey) private var ttsEngine
        = LapAnnouncerDefaults.defaultEngine
    @AppStorage(LapAnnouncerDefaults.premiumVoiceIdentifierKey) private var premiumLapVoiceId
        = LapAnnouncerDefaults.defaultPremiumVoiceIdentifier
    @AppStorage(LapAnnouncerDefaults.premiumRateKey) private var premiumRate: Double
        = LapAnnouncerDefaults.defaultPremiumRate
    @AppStorage(LapAnnouncerDefaults.premiumPitchKey) private var premiumPitch: Double
        = LapAnnouncerDefaults.defaultPremiumPitch

    /// Trailing-text label for the NavigationLink to the Premium voice picker. Shows the
    /// short name (post-`Cartesia · ` / `Polly · ` / `Azure · ` prefix) so the row stays
    /// scannable; the picker itself groups by provider so we don't need the prefix here.
    private var currentPremiumVoiceLabel: String {
        guard let v = PremiumVoiceCatalog.voices.first(where: { $0.id == premiumLapVoiceId }) else {
            return "Choose voice"
        }
        if let dot = v.label.range(of: " · ") {
            return String(v.label[dot.upperBound...])
        }
        return v.label
    }

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
                    Toggle("Say \"best lap\" on new best", isOn: $announceBest)

                    Toggle("Count down final seconds", isOn: $countdownEnabled)

                    if countdownEnabled {
                        // Stepper instead of Slider: the operator picks a
                        // discrete second count exactly once, and a stepper
                        // is easier to tap precisely than a 5–15 slider on
                        // a small range. Clamped again at race START in
                        // TimerView.primaryAction() before arming
                        // `nextCountdownN`, so a stale out-of-bounds value
                        // from a previous build can't produce a runaway
                        // count.
                        let range = LapAnnouncerDefaults.minCountdownStartSeconds
                            ... LapAnnouncerDefaults.maxCountdownStartSeconds
                        Stepper(value: $countdownStartSeconds, in: range) {
                            HStack {
                                Text("Start at")
                                Spacer()
                                Text("\(countdownStartSeconds) s")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } header: {
                Text("Announcement")
            }

            if lapTTSEnabled {
                // Voice section — language + engine + voice selection + per-engine prosody +
                // test/reset. Language sits here (not under Announcement) because it gates
                // everything below: changing it filters the voice catalog AND resets both
                // voice IDs to defaults, so the operator's mental model is "pick a language,
                // then pick a voice in that language".
                Section {
                    Picker("Language", selection: $ttsLanguageRaw) {
                        ForEach(LapAnnouncerLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .onChange(of: ttsLanguageRaw) { _, _ in
                        // The previously-picked voices (both System and Premium) almost
                        // certainly belong to the old language. Clear both so the pickers
                        // fall back to defaults for the new language instead of silently
                        // speaking new-language text through an old-language voice — Polly
                        // Takumi (ja-JP) reading "Lap 3, best lap" produces hilariously
                        // bad Japanese-accented English.
                        voiceIdentifier = LapAnnouncerDefaults.defaultVoiceIdentifier
                        premiumLapVoiceId = LapAnnouncerDefaults.defaultPremiumVoiceIdentifier
                    }

                    // Engine selector — switches the entire announce path between the built-in
                    // AVSpeechSynthesizer (free, no network) and the hdzap-premium Worker
                    // (Cartesia / Polly / Azure). When Premium is chosen the system voice/rate/
                    // pitch controls below stay visible so the operator can flip back without
                    // losing their old settings; LapAnnouncer's routing key is `ttsEngine`.
                    //
                    // The Premium row is gated on `SubscriptionManager.isEntitled`. A non-
                    // subscriber tapping "Premium" pops the paywall instead of flipping the
                    // engine — and we snap the setting back to "system" until they finish
                    // purchase, so a cancelled paywall doesn't leave them on the Premium row
                    // with no entitlement.
                    Picker("Engine", selection: $ttsEngine) {
                        Text("System").tag("system")
                        if subscription.isEntitled {
                            Text("Premium (cloud)").tag("premium")
                        } else {
                            Text("Premium — Subscribe ›").tag("premium-locked")
                        }
                    }
                    .onChange(of: ttsEngine) { _, newValue in
                        if newValue == "premium-locked" {
                            // Snap back and push the picker — the picker hosts the
                            // subscribers-only banner + sample previews so non-entitled
                            // operators can audition before being asked to pay. They never
                            // see "premium-locked" persisted.
                            ttsEngine = "system"
                            navigateToPicker = true
                        }
                    }

                    // Non-subscriber preview entry — sits under the Engine picker so the
                    // operator who's curious about Premium voices can browse + audition
                    // without committing to a purchase. The picker itself surfaces the
                    // paywall via its in-list banner.
                    if !subscription.isEntitled {
                        NavigationLink {
                            PremiumVoicePickerView(language: language.rawValue)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "waveform.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Listen to Premium voices")
                                        .font(.subheadline.bold())
                                    Text("Free preview — subscribe to use on track")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if ttsEngine == "premium" {
                        // Sub-view for the picker — a 32-voice flat `Picker` was unmanageable.
                        // The drill-in lists voices grouped by provider section, with a "no
                        // voice" escape row at the top so the operator can clear the choice
                        // without flipping the engine back to System.
                        NavigationLink {
                            PremiumVoicePickerView(language: language.rawValue)
                        } label: {
                            HStack {
                                Text("Premium voice")
                                Spacer()
                                Text(currentPremiumVoiceLabel)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        if premiumLapVoiceId.isEmpty {
                            Text("Pick a Premium voice or LAP announcements fall back to the System engine.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        // Per-provider prosody sliders. Polly Neural rejects pitch outright
                        // ("Unsupported Neural feature" 400), and Cartesia Sonic 3.5 disabled
                        // both controls in preview, so we drive visibility off the voice's
                        // provider capabilities rather than hard-coding by name.
                        let selectedProvider = PremiumVoiceCatalog.voices.first {
                            $0.id == premiumLapVoiceId
                        }?.provider

                        if selectedProvider?.supportsRate == true {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Rate")
                                    Spacer()
                                    Text(String(format: "%.2f×", premiumRate))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(
                                    value: $premiumRate,
                                    in: LapAnnouncerDefaults.minPremiumRate
                                        ... LapAnnouncerDefaults.maxPremiumRate,
                                    step: 0.05
                                )
                            }
                        }

                        if selectedProvider?.supportsPitch == true {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Pitch")
                                    Spacer()
                                    Text(String(format: "%+.1f st", premiumPitch))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(
                                    value: $premiumPitch,
                                    in: LapAnnouncerDefaults.minPremiumPitch
                                        ... LapAnnouncerDefaults.maxPremiumPitch,
                                    step: 0.5
                                )
                            }
                        }

                        if selectedProvider == .cartesia {
                            Text("Cartesia Sonic 3.5 (preview) doesn't honour rate / pitch controls yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Voice", selection: $voiceIdentifier) {
                            Text("System default").tag(LapAnnouncerDefaults.defaultVoiceIdentifier)
                            ForEach(voices) { voice in
                                Text(voice.displayName).tag(voice.id)
                            }
                        }
                    }

                    // System-engine-only banners — install nudge, voice-missing notice. None of
                    // these apply when Premium is selected (the cloud voices are always
                    // available without local installs), so we gate them on the engine pick.
                    if ttsEngine == "system" {
                        if voices.isEmpty {
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
                            Text("Selected voice is no longer installed — falling back to the system default.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if let err = announcer.premiumSynth.lastError {
                        // Surface premium errors (bearer missing, network, upstream 5xx) so the
                        // operator doesn't see silent fallback to System and wonder what went
                        // wrong. The router still falls through, so the race keeps going.
                        Text(err).font(.caption).foregroundStyle(.red)
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

                    // Rate / pitch are AVSpeechUtterance properties — they don't carry over to
                    // the cloud TTS path. Cartesia/Polly/Azure each have their own prosody
                    // controls (SSML on Polly, "voice settings" on Cartesia, none on Azure
                    // streaming endpoint), and exposing the System sliders while Premium is
                    // active would be misleading. Hide them when Premium is on; their values
                    // persist in UserDefaults so flipping back to System brings them right
                    // back without a reset.
                    if ttsEngine == "system" {
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
                            countdownEnabled = LapAnnouncerDefaults.defaultCountdownEnabled
                            countdownStartSeconds = LapAnnouncerDefaults.defaultCountdownStartSeconds
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    // Two notes the operator wouldn't otherwise know:
                    // 1. Why announcements still play with the ringer off, and
                    //    why other audio stays ducked for the whole race (the
                    //    warm-keeper streams a silent buffer through the
                    //    `.playback` + `.duckOthers` session so the HAL stays
                    //    hot — the tradeoff is continuous ducking).
                    // 2. Why a voice they expect to see isn't in the picker — iOS
                    //    ships only a base voice; better-quality voices are an
                    //    opt-in download.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plays through the speaker even when the ringer switch is silent. Other audio stays ducked for the duration of a race so announcement timing stays precise.")
                        Text("More voices: Settings → Accessibility → Spoken Content → Voices.")
                    }
                    .font(.caption2)
                }
            }

#if DEBUG
            premiumTestSection
#endif
        }
        .navigationTitle("Lap announcer")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .navigationDestination(isPresented: $navigateToPicker) {
            PremiumVoicePickerView(language: ttsLanguageRaw)
        }
        .onChange(of: subscription.isEntitled) { _, nowEntitled in
            // Roll back to System if the subscription lapsed while the engine was set to
            // Premium. Without this the Picker would render a `premium` tag with no matching
            // option in the menu (we hide it for non-subscribers), and the LapAnnouncer
            // would keep trying to route to Premium until the operator manually switched.
            if !nowEntitled && ttsEngine == "premium" {
                ttsEngine = "system"
            }
        }
    }

#if DEBUG
    /// DEBUG-only Premium TTS harness. Lets the developer paste a Worker bearer, pick a
    /// Cartesia voice, and audition a phrase end-to-end before the StoreKit wiring lands.
    private var premiumTestSection: some View {
        Section {
            HStack {
                Text("Worker URL")
                Spacer()
                TextField("URL", text: $premiumWorkerURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
            }

            HStack {
                Text("Bearer")
                Spacer()
                SecureField("paste from 1Password", text: $premiumBearer)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
            }

            Picker("Voice", selection: $premiumVoiceId) {
                ForEach(PremiumVoiceCatalog.voices) { v in
                    Text("\(v.lang.uppercased()) — \(v.label)").tag(v.id)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Test phrase").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $premiumTestText, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.callout)
            }

            // Bearer status row — makes "did I actually paste it?" obvious without taking the
            // bearer back out of SecureField. Without this it's invisible whether the field is
            // empty or holds 29 chars.
            HStack {
                Text("Bearer status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if premiumBearer.isEmpty {
                    Label("missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("\(premiumBearer.count) chars", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            HStack {
                // Always enabled — the synth itself surfaces "bearer missing" as a visible error.
                // Disabling the button silently was hiding the real state from the operator.
                Button(premiumSynth.isPlaying ? "Speaking…" : "Speak") {
                    premiumErrorBanner = nil
                    // Map the persisted picker selection back to a full PremiumVoiceOption so the
                    // synth knows the provider / lang without us re-deriving them here.
                    if let v = PremiumVoiceCatalog.voices.first(where: { $0.id == premiumVoiceId }) {
                        premiumSynth.speakAsync(text: premiumTestText, lang: v.lang, voice: v)
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Stop", role: .destructive) {
                    premiumSynth.cancel()
                }
                .buttonStyle(.bordered)
                .disabled(!premiumSynth.isPlaying)
            }

            if let err = premiumSynth.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if let ms = premiumSynth.lastFirstAudioMs {
                Text(String(format: "First audio: %.0f ms", ms))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } header: {
            Text("Premium TTS (Debug)")
        } footer: {
            Text("Streams from \(URL(string: premiumWorkerURL)?.host ?? "?") via Cartesia Sonic 3.5. This panel is DEBUG-only and will be replaced by the StoreKit-gated SpeechRouter in the next phase.")
                .font(.caption2)
        }
    }
#endif
}

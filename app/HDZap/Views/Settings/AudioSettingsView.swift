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
    /// One-shot guard for the manual-screenshot route walker. Prevents a second onAppear
    /// (after the picker dismisses, etc.) from re-pushing the same destination.
    @State private var ssRouteApplied = false
    // Standalone Premium synth used by the dev panel below. Production playback flows
    // through `announcer.premiumSynth` (wired in `HDZapApp`); this separate instance lets
    // the panel exercise an utterance without disturbing the announcer's session/engine
    // state mid-race.
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
    @AppStorage(LapAnnouncerDefaults.announceSplitKey) private var announceSplit
        = LapAnnouncerDefaults.defaultAnnounceSplit
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
    /// short name (post-`Polly · ` / `Azure · ` prefix) so the row stays
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

                    Toggle("Announce need / bank", isOn: $announceSplit)

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
                    // (AWS Polly + Microsoft Azure). When Premium is chosen the system voice/rate/
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
                        // No `prewarmFixedPhrases()` call on engine flips either — TimerView
                        // fires the single prewarm on Settings sheet dismissal, which is
                        // when the operator has settled on every Premium control (voice +
                        // language + engine + countdown duration + rate + pitch).
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
                        // ("Unsupported Neural feature" 400), so we drive visibility off the
                        // voice's provider capabilities rather than hard-coding by name.
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
                    // the cloud TTS path. Polly and Azure each have their own SSML prosody
                    // controls applied server-side, and exposing the System sliders while
                    // Premium is active would be misleading. Hide them when Premium is on;
                    // their values persist in UserDefaults so flipping back to System brings
                    // them right back without a reset.
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
                            // Scoped to Voice-section keys only — restoring the master
                            // toggle / announce-best / countdown settings here would
                            // surprise the operator, because those live under the
                            // Announcement section and aren't visually related to the
                            // button. All defaults route through `LapAnnouncerDefaults`
                            // so a future tweak to a registered default propagates here
                            // in one edit.
                            ttsLanguageRaw = LapAnnouncerDefaults.defaultLanguageRaw
                            ttsEngine = LapAnnouncerDefaults.defaultEngine
                            voiceIdentifier = LapAnnouncerDefaults.defaultVoiceIdentifier
                            ttsRate = Double(LapAnnouncerDefaults.defaultRate)
                            ttsPitch = Double(LapAnnouncerDefaults.defaultPitch)
                            premiumLapVoiceId = LapAnnouncerDefaults.defaultPremiumVoiceIdentifier
                            premiumRate = LapAnnouncerDefaults.defaultPremiumRate
                            premiumPitch = LapAnnouncerDefaults.defaultPremiumPitch
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
            // Hide the dev-only Premium TTS test panel during manual-screenshot
            // capture — the bearer field + worker URL + raw voice picker only
            // confuse end users in the published manual.
            if !ScreenshotMode.isActive {
                premiumTestSection
            }
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
        #if DEBUG
        .onAppear { applyScreenshotRouteIfNeeded() }
        #endif
    }

    #if DEBUG
    /// Manual-screenshot route walker for the AudioSettings sub-tree.
    /// `.audioPremium` flips the engine + seeds a real Premium voice ID so the
    /// "Premium" branch of the body actually renders. The picker / paywall
    /// variants push the next surface on appear.
    private func applyScreenshotRouteIfNeeded() {
        guard !ssRouteApplied, let route = ScreenshotMode.route else { return }
        ssRouteApplied = true
        // Force `lapTTSEnabled = true` for every audio-related screenshot so the
        // Voice section is on screen — otherwise an iPhone simulator persisted
        // from a prior route (or with the master toggle flipped off) would
        // render an audio screenshot with no voice controls at all.
        lapTTSEnabled = true
        // Pin the Need/Bank toggle to its shipped default the same way
        // `countdownEnabled` is pinned below: the manual documents it as
        // "off by default", so a screenshot showing it ON contradicts the
        // prose right next to it. The row renders either way, which is all
        // the manual needs from this capture.
        announceSplit = LapAnnouncerDefaults.defaultAnnounceSplit
        switch route {
        case .audio:
            // Ensure a clean System-engine screenshot — the simulator's
            // UserDefaults persist across launches, so a prior `.audioPremium`
            // capture would otherwise leave the engine on Premium.
            ttsEngine = "system"
            countdownEnabled = false
            syncLanguageWithLocale()
        case .audioCountdownOn:
            // Same as `.audio` but flip the countdown toggle on so the
            // "Start at" stepper sub-row renders — used by the manual to
            // document the optional countdown behaviour.
            ttsEngine = "system"
            countdownEnabled = true
            syncLanguageWithLocale()
        case .audioPremium:
            ttsEngine = "premium"
            // Always force the language picker to match the current display
            // locale so a prior run (e.g. en capture) can't leak its
            // `ttsLanguageRaw` into a JA screenshot (or vice-versa).
            syncLanguageWithLocale()
            // Pick the first Premium voice that matches the (now-locale-correct)
            // language so the "Premium voice" label / rate / pitch sliders all
            // render against a real entry. ALWAYS re-pick — UserDefaults persists
            // across launches and a stale ID from a different-language run would
            // otherwise show through (e.g. JA capture rendering Matthew because
            // the en capture wrote it first).
            // Deferred via `Task { @MainActor }` so it lands AFTER the
            // Language Picker's `.onChange(of: ttsLanguageRaw)` handler
            // (lines 132-141) — which resets `premiumLapVoiceId` to the
            // default whenever the language changes — has flushed. A
            // synchronous write here would get clobbered on the next
            // runloop tick when `syncLanguageWithLocale` actually
            // changed the value.
            Task { @MainActor in
                if let voice = PremiumVoiceCatalog.voices(for: ttsLanguageRaw).first {
                    premiumLapVoiceId = voice.id
                }
            }
        case .premiumVoicePicker:
            // Entitled picker view — pre-select the first voice so the row
            // shows the ✓ checkmark, communicating "this is the active voice
            // you'd hear at race time". Same `Task { @MainActor }` rationale
            // as `.audioPremium` above: defer past the language onChange.
            syncLanguageWithLocale()
            Task { @MainActor in
                if let voice = PremiumVoiceCatalog.voices(for: ttsLanguageRaw).first {
                    premiumLapVoiceId = voice.id
                }
                navigateToPicker = true
            }
        case .premiumVoicePickerLocked:
            // Non-subscriber picker view — explicitly CLEAR any persisted
            // selection so no row carries a stale ✓ from an earlier
            // `.premiumVoicePicker` / `.audioPremium` capture run. A
            // non-subscriber has by definition never committed a voice,
            // so a check mark would mis-tell the story. Deferred for the
            // same onChange-race reason as the above two cases.
            syncLanguageWithLocale()
            Task { @MainActor in
                premiumLapVoiceId = ""
                navigateToPicker = true
            }
            navigateToPicker = true
        case .paywall:
            showingPaywall = true
        default:
            break
        }
    }

    /// Force `ttsLanguageRaw` to match the current iOS display locale so the
    /// language picker and the pre-selected voice can't fall out of sync with
    /// the system language during screenshot capture. Without this, a stale
    /// `ttsLanguageRaw` from a prior different-locale launch leaks through
    /// (e.g. the JA capture rendering an English voice because the en run
    /// wrote `"en"` to UserDefaults first).
    private func syncLanguageWithLocale() {
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        let target: LapAnnouncerLanguage = langCode == "ja" ? .japanese : .english
        if ttsLanguageRaw != target.rawValue {
            ttsLanguageRaw = target.rawValue
        }
    }
    #endif

#if DEBUG
    /// DEBUG-only Premium TTS harness. Lets the developer paste a Worker bearer, pick a
    /// Polly or Azure voice, and audition a phrase end-to-end before the StoreKit wiring
    /// lands.
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
            Text("DEBUG-only smoke-test panel that hits \(URL(string: premiumWorkerURL)?.host ?? "?") directly. Production race-time playback already routes through the same Worker via SubscriptionManager + LapAnnouncer.")
                .font(.caption2)
        }
    }
#endif
}

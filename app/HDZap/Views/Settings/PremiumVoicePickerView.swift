import SwiftUI

/// Drill-in voice picker for the Premium engine. The flat 32-voice list got unmanageable
/// inside a `Picker` (a sheet of 32 rows with no grouping), so we surface the catalog as a
/// `List` grouped by provider — the labels already prefix `Cartesia · / Polly · / Azure · `,
/// but the section header lets the operator skip past whole providers when they know which
/// flavor they want.
///
/// Tap a row → write the voice ID into `LapAnnouncerDefaults.premiumVoiceIdentifierKey` and
/// pop back. The current selection gets a checkmark.
struct PremiumVoicePickerView: View {
    /// Restrict the list to one language so the operator's selection lines up with the
    /// `lapTTSLanguage` they already configured up the screen. Catalog has JA + EN.
    let language: String

    @AppStorage(LapAnnouncerDefaults.premiumVoiceIdentifierKey) private var selectedId
        = LapAnnouncerDefaults.defaultPremiumVoiceIdentifier
    @Environment(\.dismiss) private var dismiss
    // The synth that's wired into the rest of the app — we reuse it so the preview
    // plays through the same audio session + AVAudioPlayer as a real lap call.
    @Environment(LapAnnouncer.self) private var announcer

    /// Voice that's currently auditioning. While non-nil, that row shows a stop icon
    /// instead of play; other rows stay play. Cleared when the synth's `isPlaying`
    /// flips false (network finished, AVAudioPlayer about to drain).
    @State private var previewingVoiceId: String?

    /// Sample text used when the operator taps the inline ▶ button. Matches the typical
    /// race-time utterance length so they can judge cadence + number reading, not just
    /// the voice's resting timbre.
    private let sampleText = "ラップ3、12.34、ベストラップ"

    private var voicesByProvider: [(PremiumVoiceProvider, [PremiumVoiceOption])] {
        let voices = PremiumVoiceCatalog.voices(for: language)
        // Operator-facing order: AWS first (lowest TTFA / cleanest reading), then Azure
        // (more voice variety), then Cartesia (most expressive). Matches the order they
        // tend to A/B test in, so the most likely picks sit at the top.
        let providers: [PremiumVoiceProvider] = [.polly, .azure, .cartesia]
        return providers.compactMap { provider in
            let filtered = voices.filter { $0.provider == provider }
            return filtered.isEmpty ? nil : (provider, filtered)
        }
    }

    var body: some View {
        // The "no voice" escape lives on the parent screen via the Engine picker (flip to
        // System) — surfacing a second way out of the catalog here was confusing, so this
        // sub-view's only job is to pick one.
        List {
            ForEach(voicesByProvider, id: \.0) { provider, voices in
                Section {
                    ForEach(voices) { voice in
                        VoiceRow(
                            voice: voice,
                            provider: provider,
                            isSelected: voice.id == selectedId,
                            isPreviewing: previewingVoiceId == voice.id
                                && announcer.premiumSynth.isPlaying,
                            onSelect: {
                                selectedId = voice.id
                                dismiss()
                            },
                            onPreview: {
                                // Tapping the icon during preview cancels it. Otherwise kick
                                // off a new audition without committing the selection.
                                if previewingVoiceId == voice.id, announcer.premiumSynth.isPlaying {
                                    announcer.premiumSynth.cancel()
                                    previewingVoiceId = nil
                                } else {
                                    previewingVoiceId = voice.id
                                    announcer.premiumSynth.speakAsync(
                                        text: sampleText,
                                        lang: voice.lang,
                                        voice: voice
                                    )
                                }
                            }
                        )
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text(provider.footerHint)
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("Premium voice")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: announcer.premiumSynth.isPlaying) { _, isPlaying in
            // Synth has reported playback done — clear the local highlight so the row's
            // icon flips back to play. There's a small lag (AVAudioPlayer trails the
            // network stream by ~100 ms for mp3) but it's accurate enough for the UI.
            if !isPlaying { previewingVoiceId = nil }
        }
        .onDisappear {
            // Leaving the sub-view shouldn't keep speaking — the operator probably
            // navigated away because they're done auditioning.
            if announcer.premiumSynth.isPlaying {
                announcer.premiumSynth.cancel()
            }
            previewingVoiceId = nil
        }
    }
}

/// One row in the voice list — splits the row into "tap the name to select" and "tap ▶ to
/// preview". The split needs an explicit `.contentShape` because the system Button's hit
/// region otherwise overlaps the row's tap target.
private struct VoiceRow: View {
    let voice: PremiumVoiceOption
    let provider: PremiumVoiceProvider
    let isSelected: Bool
    /// True only when THIS row's sample is currently auditioning — flips the icon to
    /// `stop.circle.fill` so the operator has a visible "tap to cancel" affordance.
    let isPreviewing: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack {
            // The selection target — most of the row's width. Tapping anywhere here picks
            // the voice; the trailing ▶ button is the only sub-region that doesn't.
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                    Text(displayLabel)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onPreview) {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
        }
    }

    /// Strip the `Cartesia · / AWS Polly · / Azure · ` prefix from the catalog label since
    /// the section header already conveys the provider.
    private var displayLabel: String {
        let prefix = "\(providerLabelPrefix) · "
        if voice.label.hasPrefix(prefix) {
            return String(voice.label.dropFirst(prefix.count))
        }
        return voice.label
    }

    /// `PremiumVoiceCatalog` labels use "Cartesia", "Polly", "Azure" as prefixes — match
    /// those, not the display-name strings from `PremiumVoicePickerView`.
    private var providerLabelPrefix: String {
        switch provider {
        case .cartesia: return "Cartesia"
        case .polly:    return "Polly"
        case .azure:    return "Azure"
        }
    }
}

private extension PremiumVoiceProvider {
    var displayName: String {
        switch self {
        case .cartesia: return "Cartesia"
        case .polly:    return "AWS Polly"
        case .azure:    return "Azure"
        }
    }

    /// One-liner per provider that the operator might want to see while comparing — TTFA
    /// is the headline number, accent / quirks are the differentiators.
    var footerHint: String {
        switch self {
        case .cartesia: return "Native Japanese voices, ~340 ms TTFA. Most voice variety."
        case .polly:    return "AWS Neural, ~60 ms TTFA. Reads numbers cleanly with SSML."
        case .azure:    return "Azure Neural, ~90 ms TTFA. Bright, broadcast-style delivery."
        }
    }
}

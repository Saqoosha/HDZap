import StoreKit
import SwiftUI

/// HDZap Premium paywall. The job here is to satisfy Apple's App Store Review Guidelines
/// 3.1.2 for auto-renewable subscriptions:
///
///   - Title + price (most prominent element)
///   - Subscription length + auto-renewal disclosure
///   - What's included
///   - Restore Purchases button
///   - Terms of Use + Privacy Policy links
///   - Free trial price + duration if any
///
/// We use SwiftUI primitives rather than StoreKit's `StoreView` / `SubscriptionStoreView`
/// because we want a few HDZap-specific affordances (a sample voice preview, a list of
/// included providers) that the off-the-shelf views don't accommodate.
struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(LapAnnouncer.self) private var announcer
    @Environment(\.dismiss) private var dismiss
    /// "products still loading" / "loaded N products" / "timed out, no products". Drives the
    /// product cards section so a stuck StoreKit configuration (e.g. running via devicectl
    /// instead of Xcode's Run button, no real ASC products yet) doesn't leave the operator
    /// staring at an indefinite spinner.
    @State private var productLoadState: ProductLoadState = .loading
    /// Which sample voice (if any) is currently auditioning. Cleared when the synth's
    /// `isPlaying` flips false so the row icon flips back to play.
    @State private var previewingVoiceId: String?

    private enum ProductLoadState {
        case loading
        case loaded
        case empty   // store reachable but returned no products (most often: ASC not configured)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    voiceSamples
                    valueProps
                    productPickers
                    actionButtons
                    legalLinks
                }
                .padding()
            }
            .navigationTitle("HDZap Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadProductsWithTimeout()
        }
        .onChange(of: subscription.isEntitled) { _, nowEntitled in
            // Auto-dismiss the moment the user is entitled — they don't need to look at the
            // paywall after a successful purchase.
            if nowEntitled { dismiss() }
        }
        .onChange(of: announcer.premiumSynth.isPlaying) { _, isPlaying in
            if !isPlaying { previewingVoiceId = nil }
        }
        .onDisappear {
            if announcer.premiumSynth.isPlaying {
                announcer.premiumSynth.cancel()
            }
            previewingVoiceId = nil
        }
    }

    /// Refresh products + entitlement, but cap how long we show the spinner. If StoreKit
    /// returns nothing after 5 seconds we flip to the `.empty` state so the UI explains what
    /// to do (open in Xcode for sandbox, or wait for App Store Connect to approve the IAPs).
    private func loadProductsWithTimeout() async {
        productLoadState = .loading
        async let load: Void = {
            await subscription.loadProducts()
            await subscription.refreshEntitlement()
        }()
        async let timeout: Void = Task.sleep(for: .seconds(5))
        _ = await (load, try? timeout)
        productLoadState = subscription.products.isEmpty ? .empty : .loaded
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Realistic AI announcer voices")
                .font(.largeTitle.bold())
            Text("Race-time call-outs powered by cloud TTS. 35+ Japanese and English voices across AWS Polly, Azure, and Cartesia.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ValueRow(icon: "sparkles", title: "Natural Japanese pronunciation",
                     subtitle: "Cardinal number reading (\"12.34\" → \"じゅうにてん さんよん\"), no robotic digit-by-digit.")
            ValueRow(icon: "bolt.fill", title: "Sub-100 ms first-audio",
                     subtitle: "Polly Takumi: 56 ms TTFA. Azure Daichi: 93 ms. Cartesia: 339 ms with full prosody.")
            ValueRow(icon: "person.2.fill", title: "Pick your announcer",
                     subtitle: "Calm narrator, race sportscaster, energetic character — auditioned per voice in Settings.")
            ValueRow(icon: "slider.horizontal.3", title: "Tune the pace",
                     subtitle: "Rate slider for Polly + Azure. Pitch slider for Azure. Cartesia plays natural.")
        }
    }

    @ViewBuilder
    private var productPickers: some View {
        switch productLoadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        case .loaded:
            VStack(spacing: 12) {
                ForEach(subscription.products, id: \.id) { product in
                    ProductCard(product: product, isPurchasing: subscription.purchasing == product.id) {
                        await purchase(product)
                    }
                }
            }
        case .empty:
            VStack(alignment: .leading, spacing: 8) {
                Label("Subscription products are not available right now.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text("Two reasons this can happen:\n• The app is running outside Xcode's local StoreKit sandbox. Run from Xcode (Cmd+R) to test the paywall against the bundled .storekit config.\n• The App Store Connect products are still in review / Missing Metadata. They have to be approved before they appear in real builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await loadProductsWithTimeout() }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.4)))
        }
    }

    /// A tiny "try-before-you-buy" section: three handpicked voices across the three
    /// providers, each with a play button that triggers the same Premium synth the rest of
    /// the app uses. Lets the operator audition the sound quality before committing — the
    /// engine gate previously hid the entire voice picker behind the subscription, leaving
    /// non-subscribers with no way to hear what they were paying for.
    @ViewBuilder
    private var voiceSamples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listen first")
                .font(.headline)
            Text("Tap a voice to hear it speak 「ラップ3、12.34、ベストラップ」.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(PaywallView.sampleVoices) { voice in
                    PaywallSampleRow(
                        voice: voice,
                        isPreviewing: previewingVoiceId == voice.id
                            && announcer.premiumSynth.isPlaying,
                        onTap: { togglePreview(voice) }
                    )
                }
            }
        }
    }

    /// Curated 3-voice teaser, one per provider. IDs sourced from `PremiumVoiceCatalog`.
    fileprivate static let sampleVoices: [PremiumVoiceOption] = [
        // Cartesia Takeshi — most expressive option, user-rated 5/5.
        PremiumVoiceCatalog.voices.first { $0.id == "06950fa3-534d-46b3-93bb-f852770ea0b5" }!,
        // Azure Daichi — clean broadcast male, fastest among the high-quality options.
        PremiumVoiceCatalog.voices.first { $0.id == "ja-JP-DaichiNeural" }!,
        // Polly Takumi — lowest-latency option, classic ELT race-call cadence with x-fast.
        PremiumVoiceCatalog.voices.first { $0.id == "Takumi" }!,
    ]

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button("Restore Purchases") {
                Task { await subscription.restore() }
            }
            .font(.footnote)

            if let err = subscription.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                // Apple's standard subscription-management sheet — deep-links into Settings
                // → Apple ID → Subscriptions. Required by Guideline 3.1.2.
                Task {
                    if let scene = await UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        try? await AppStore.showManageSubscriptions(in: scene)
                    }
                }
            } label: {
                Text("Manage Subscription")
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity)
    }

    private var legalLinks: some View {
        VStack(spacing: 4) {
            Text(autoRenewDisclosure)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            HStack(spacing: 16) {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy Policy", destination: URL(string: "https://hdzap.saqoo.sh/privacy.html")!)
            }
            .font(.caption2)
        }
    }

    private var autoRenewDisclosure: String {
        "Subscription auto-renews unless cancelled at least 24 hours before the period ends. " +
        "Manage or cancel in Settings → Apple ID → Subscriptions. " +
        "Payment is charged to your Apple ID account after a 7-day free trial."
    }

    /// Sample text used when auditioning. Same string as the in-app picker — short enough
    /// to be quick, long enough to expose the number-reading bug providers used to have.
    private static let sampleText = "ラップ3、12.34、ベストラップ"

    private func togglePreview(_ voice: PremiumVoiceOption) {
        if previewingVoiceId == voice.id, announcer.premiumSynth.isPlaying {
            announcer.premiumSynth.cancel()
            previewingVoiceId = nil
        } else {
            previewingVoiceId = voice.id
            announcer.premiumSynth.speakAsync(
                text: PaywallView.sampleText,
                lang: voice.lang,
                voice: voice
            )
        }
    }

    private func purchase(_ product: Product) async {
        do {
            _ = try await subscription.purchase(product)
        } catch {
            // Errors thrown from Product.purchase() go here — usually
            // SKError.paymentCancelled (already handled inside the manager) or network.
            // Surface so the operator can retry.
            // SubscriptionManager.lastError is set inside catch paths too — we don't need
            // to re-set it here.
        }
    }
}

/// Inline preview row used by the paywall's "Listen first" section. Visually distinct from
/// `PremiumVoicePickerView.VoiceRow` (no select target, no checkmark) because the paywall
/// can't commit a selection — the operator hasn't subscribed yet.
private struct PaywallSampleRow: View {
    let voice: PremiumVoiceOption
    let isPreviewing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.label)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(voice.providerHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension PremiumVoiceOption {
    /// "Cartesia · Expressive male" → "Expressive male". Same de-prefixing logic as the
    /// picker view but inlined here to keep the paywall self-contained.
    var providerHint: String {
        switch provider {
        case .cartesia: return "Cartesia · most expressive"
        case .polly:    return "AWS Polly · lowest latency"
        case .azure:    return "Azure · broadcast-style"
        }
    }
}

private struct ValueRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProductCard: View {
    let product: Product
    let isPurchasing: Bool
    let onTap: () async -> Void

    var body: some View {
        Button {
            Task { await onTap() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName)
                            .font(.headline)
                        // Per-period price — the most prominent number on the screen.
                        Text("\(product.displayPrice) / \(periodLabel)")
                            .font(.title2.bold())
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }

                if let intro = product.subscription?.introductoryOffer,
                   intro.paymentMode == .freeTrial {
                    Text("\(introDescription(intro)) free trial included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    /// Format a period as "month" / "year" / "week" / "N day(s)" for the price denominator.
    private var periodLabel: String {
        guard let p = product.subscription?.subscriptionPeriod else { return "subscription" }
        switch p.unit {
        case .day:   return p.value == 1 ? "day"   : "\(p.value) days"
        case .week:  return p.value == 1 ? "week"  : "\(p.value) weeks"
        case .month: return p.value == 1 ? "month" : "\(p.value) months"
        case .year:  return p.value == 1 ? "year"  : "\(p.value) years"
        @unknown default: return "period"
        }
    }

    private func introDescription(_ offer: Product.SubscriptionOffer) -> String {
        let p = offer.period
        switch p.unit {
        case .day:   return "\(p.value)-day"
        case .week:  return p.value == 1 ? "7-day" : "\(p.value)-week"
        case .month: return "\(p.value)-month"
        case .year:  return "\(p.value)-year"
        @unknown default: return "Trial"
        }
    }
}

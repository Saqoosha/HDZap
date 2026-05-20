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
            Text(Self.headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ValueRow(icon: "sparkles",
                     title: Self.isJa ? "自然な数字の読み上げ" : "Natural number reading",
                     subtitle: Self.numberReadingSubtitle)
            ValueRow(icon: "waveform.path.ecg",
                     title: Self.isJa ? "放送局グレードの音質" : "Broadcast-grade audio",
                     subtitle: Self.isJa
                        ? "プロのレース実況と区別がつかないニューラルボイス。iPhone のスピーカーでも Bluetooth ヘッドホンでもクリアに聞こえます。"
                        : "Neural voices indistinguishable from professional race announcers. Clear over the iPhone speaker or Bluetooth headphones.")
            ValueRow(icon: "person.2.fill",
                     title: Self.isJa ? "実況キャラを選べる" : "Pick your announcer",
                     subtitle: Self.isJa
                        ? "落ち着いたナレーター、レース実況、エネルギッシュなキャラクター — 設定でボイスごとに試聴できます。"
                        : "Calm narrator, race sportscaster, energetic character — auditioned per voice in Settings.")
            ValueRow(icon: "slider.horizontal.3",
                     title: Self.isJa ? "ペースを調整" : "Tune the pace",
                     subtitle: Self.isJa
                        ? "Polly と Azure は Rate スライダー、Azure は Pitch スライダーで微調整。Cartesia は自然なまま再生。"
                        : "Rate slider for Polly + Azure. Pitch slider for Azure. Cartesia plays natural.")
            ValueRow(icon: "wifi.exclamationmark",
                     title: Self.isJa ? "インターネット接続が必要" : "Internet connection required",
                     subtitle: Self.isJa
                        ? "クラウドで音声合成するため通信が必要です。電波が弱い場所では再生が遅れたり途切れる場合があります。圏外時は System ボイスに自動フォールバックします。"
                        : "Voices are synthesised in the cloud. Weak-signal areas may cause delays or dropouts. Offline, the app falls back to the System voice automatically.")
        }
    }

    /// Cached locale check — `Locale.current` is cheap but reads cleaner as `Self.isJa`
    /// at the call sites where the value props decide which language to render.
    private static var isJa: Bool {
        Locale.current.language.languageCode?.identifier == "ja"
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
            Text(Self.isJa
                 ? "ボイスをタップしてサンプル実況を再生。"
                 : "Tap a voice to hear a sample race call-out.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(Self.sampleVoices) { voice in
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

    /// Curated 3-voice teaser, one per provider, ordered fastest-first (Polly → Azure →
    /// Cartesia) to match the picker. The voices are picked from the user's UI locale so a
    /// Japanese-system iPhone hears Japanese voices and an English-system iPhone hears
    /// English voices — showing the wrong-language side of the catalogue on the paywall
    /// hides half the value (and produces a confused first impression).
    fileprivate static var sampleVoices: [PremiumVoiceOption] {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        let ids: [String] = isJapanese
            ? [
                "Takumi",                                  // Polly · Takumi (male, Neural)
                "ja-JP-DaichiNeural",                      // Azure · Daichi (male)
                "06950fa3-534d-46b3-93bb-f852770ea0b5",    // Cartesia · Takeshi - Hero
            ]
            : [
                "Matthew",                                  // Polly · Matthew (US male, newscaster)
                "en-US-DavisNeural",                        // Azure · Davis (US male)
                "2f22b9bc-b0eb-4cb6-b5ae-0c099a0fdfad",     // Cartesia · Scott - Sportscaster
            ]
        return ids.compactMap { id in PremiumVoiceCatalog.voices.first { $0.id == id } }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button(Self.isJa ? "購入の復元" : "Restore Purchases") {
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
                Link(Self.isJa ? "利用規約" : "Terms of Use",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link(Self.isJa ? "プライバシーポリシー" : "Privacy Policy",
                     destination: URL(string: Self.isJa
                        ? "https://hdzap.saqoo.sh/privacy/ja/"
                        : "https://hdzap.saqoo.sh/privacy/")!)
            }
            .font(.caption2)
        }
    }

    private var autoRenewDisclosure: String {
        if Self.isJa {
            return "期間終了の 24 時間以上前に解約しない限り、サブスクリプションは自動更新されます。" +
                "設定 → Apple ID → サブスクリプション から管理・解約できます。" +
                "料金は Apple ID アカウントに請求されます。"
        }
        return "Subscription auto-renews unless cancelled at least 24 hours before the period ends. " +
            "Manage or cancel in Settings → Apple ID → Subscriptions. " +
            "Payment is charged to your Apple ID account."
    }

    /// Paywall headline subtitle. Mentions the user's primary language first ("English
    /// and Japanese" for EN locales, "日本語と英語" for JA locales) so the first thing the
    /// operator reads is "this works for my language".
    private static var headerSubtitle: String {
        let isJa = Locale.current.language.languageCode?.identifier == "ja"
        return isJa
            ? "AI音声合成によるレース実況。AWS Polly・Azure・Cartesia の 50 種類以上の日本語・英語ボイスから選べます。"
            : "Race-time call-outs powered by AI voice synthesis. 50+ voices in English and Japanese across AWS Polly, Azure, and Cartesia."
    }

    /// Value-prop body for the "Natural number reading" row. Localised so the example
    /// is in the reader's language and the language pair leads with their own.
    private static var numberReadingSubtitle: String {
        let isJa = Locale.current.language.languageCode?.identifier == "ja"
        return isJa
            ? "「12.34」を「じゅうにいてん さんよん」と自然に読み上げ。ロボットのような桁ごと読みなし。日本語と英語の両方に対応。"
            : "\"12.34\" reads as \"twelve point three four\" — no robotic digit-by-digit. Works in both English and Japanese."
    }

    /// Sample text per voice language — short enough to be quick, long enough to expose
    /// number-reading regressions. Sending JA text through an EN voice (or vice versa)
    /// produces phonetic-approximation gibberish, so each row's preview uses the script
    /// that matches the voice's `lang`.
    private static func sampleText(for lang: String) -> String {
        switch lang {
        case "ja": return "ラップ3、12.34、ベストラップ"
        default:   return "Lap 3, 12.34, best lap"
        }
    }

    private func togglePreview(_ voice: PremiumVoiceOption) {
        if previewingVoiceId == voice.id, announcer.premiumSynth.isPlaying {
            announcer.premiumSynth.cancel()
            previewingVoiceId = nil
        } else {
            previewingVoiceId = voice.id
            announcer.premiumSynth.speakAsync(
                text: Self.sampleText(for: voice.lang),
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
        let isJa = Locale.current.language.languageCode?.identifier == "ja"
        switch provider {
        case .cartesia: return isJa ? "Cartesia · 最も表情豊か"   : "Cartesia · most expressive"
        case .polly:    return isJa ? "AWS Polly · クリアな読み上げ" : "AWS Polly · clear newscaster"
        case .azure:    return isJa ? "Azure · 放送局スタイル"    : "Azure · broadcast-style"
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

    /// Locale check — same logic as `PaywallView.isJa`, repeated here so the helpers can
    /// stay in this struct's private scope.
    private static var isJa: Bool {
        Locale.current.language.languageCode?.identifier == "ja"
    }

    /// Format a period as the price denominator. EN: "month" / "year" / "N days".
    /// JA: 「月」「年」「N日」「N週間」.
    private var periodLabel: String {
        guard let p = product.subscription?.subscriptionPeriod else {
            return Self.isJa ? "サブスクリプション" : "subscription"
        }
        if Self.isJa {
            switch p.unit {
            case .day:   return "\(p.value)日"
            case .week:  return "\(p.value)週間"
            case .month: return p.value == 1 ? "月" : "\(p.value)ヶ月"
            case .year:  return p.value == 1 ? "年" : "\(p.value)年"
            @unknown default: return "期間"
            }
        }
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
        if Self.isJa {
            switch p.unit {
            case .day:   return "\(p.value)日間"
            case .week:  return p.value == 1 ? "7日間" : "\(p.value)週間"
            case .month: return "\(p.value)ヶ月"
            case .year:  return "\(p.value)年"
            @unknown default: return "試用"
            }
        }
        switch p.unit {
        case .day:   return "\(p.value)-day"
        case .week:  return p.value == 1 ? "7-day" : "\(p.value)-week"
        case .month: return "\(p.value)-month"
        case .year:  return "\(p.value)-year"
        @unknown default: return "Trial"
        }
    }
}

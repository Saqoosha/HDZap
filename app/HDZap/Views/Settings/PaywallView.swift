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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
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
            // Refresh whenever the paywall opens — products + entitlement might have changed
            // since launch (subscription renewed in the background, restore done elsewhere).
            await subscription.loadProducts()
            await subscription.refreshEntitlement()
        }
        .onChange(of: subscription.isEntitled) { _, nowEntitled in
            // Auto-dismiss the moment the user is entitled — they don't need to look at the
            // paywall after a successful purchase.
            if nowEntitled { dismiss() }
        }
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
        if subscription.products.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            VStack(spacing: 12) {
                ForEach(subscription.products, id: \.id) { product in
                    ProductCard(product: product, isPurchasing: subscription.purchasing == product.id) {
                        await purchase(product)
                    }
                }
            }
        }
    }

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

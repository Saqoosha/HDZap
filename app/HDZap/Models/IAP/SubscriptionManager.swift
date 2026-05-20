import Foundation
import StoreKit
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "Subscription")

/// Two product IDs ship in the catalog — monthly + yearly. Single subscription group called
/// `HDZap Premium`. App Store Connect uses the same IDs (configured once Paid Apps Agreement
/// has been signed); the `.storekit` config file mirrors them for local testing.
enum SubscriptionProductID {
    static let monthly = "sh.saqoo.HDZap.premium.monthly"
    static let yearly  = "sh.saqoo.HDZap.premium.yearly"
    static let all: Set<String> = [monthly, yearly]
}

/// What the rest of the app sees re: subscription state. `.active(expires:)` covers both the
/// free trial and the paid period — Apple's StoreKit2 `Transaction` doesn't distinguish in
/// `currentEntitlements`, and we don't need to. `.inGracePeriod` covers Apple's billing-retry
/// window (~16 days after a failed renewal) during which we should still treat the user as
/// entitled — Apple says "if you see currentEntitlements after expiration, the user is in
/// grace period; honour the subscription".
enum SubscriptionStatus: Equatable {
    case unknown
    case none
    case active(expires: Date?)
    case inGracePeriod(expires: Date?)
}

/// StoreKit 2 wrapper. Holds the loaded `Product`s, tracks current entitlement, and exposes
/// `purchase` / `restore`. Owned by `HDZapApp` and injected via `@Environment`.
///
/// `@MainActor` because every observable property is read from SwiftUI; the actual StoreKit
/// calls run async on background threads, we just hop back to main when writing state.
@MainActor
@Observable
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var status: SubscriptionStatus = .unknown
    /// JWS representation of the active entitlement transaction. The Worker's `/tts`
    /// endpoint verifies this against Apple Root CA G3 to authorize Premium audio — when
    /// non-nil, callers should ship it as `Authorization: Bearer <jws>`. Lives next to
    /// `status` because they're updated together (`refreshEntitlement`).
    private(set) var currentJWS: String?
    /// Surface for the paywall — "purchase didn't complete", "restore found nothing", etc.
    private(set) var lastError: String?
    /// In-flight purchase so the paywall can show a spinner instead of letting the operator
    /// tap the button repeatedly while StoreKit is talking to App Store.
    private(set) var purchasing: String?

    /// Helper for views that just need "is the user entitled right now?". Treats grace
    /// period as active — Apple expects services to keep working through the retry window.
    var isEntitled: Bool {
        switch status {
        case .active, .inGracePeriod: return true
        case .unknown, .none: return false
        }
    }

    private var updateListenerTask: Task<Void, Never>?

    // `SubscriptionManager` lives as a `@State` on `HDZapApp` for the entire process lifetime,
    // so we don't bother cleaning up `updateListenerTask` in `deinit` — Swift 6's main-actor
    // isolation makes that touch awkward, and the OS reclaims the task at app termination.

    /// Call once at app launch. Starts the `Transaction.updates` listener and loads the
    /// product catalog + current entitlement. Re-entrant: a second call is ignored.
    func start() {
        guard updateListenerTask == nil else { return }
        updateListenerTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                // Apple's `Transaction.updates` is how out-of-band events reach the app:
                // subscription renewed automatically, refunded, family-shared seat added,
                // etc. We re-resolve entitlement on every update — cheaper than parsing
                // each transaction's fields by hand.
                await self?.handle(verificationResult: result)
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlement()
        }
    }

    /// Fetch product metadata for the paywall. Empty array means StoreKit couldn't reach the
    /// store — either offline, or App Store Connect hasn't approved the products yet.
    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: SubscriptionProductID.all)
            // Surface monthly first — it's the lower-friction entry point (¥450 vs ¥4000)
            // and the yearly card sits underneath it where the discount story is still
            // visible without forcing the bigger commitment to be the first thing the
            // operator reads.
            products = fetched.sorted { lhs, rhs in
                lhs.id == SubscriptionProductID.monthly && rhs.id == SubscriptionProductID.yearly
            }
            log.notice("loaded \(self.products.count, privacy: .public) products: \(self.products.map { $0.id }.joined(separator: ", "), privacy: .public)")
        } catch {
            log.error("loadProducts failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't load subscription products: \(error.localizedDescription)"
        }
    }

    /// Purchase or upgrade. Returns true if the user is now entitled, false if they
    /// cancelled or the transaction is pending. Errors throw.
    func purchase(_ product: Product) async throws -> Bool {
        purchasing = product.id
        defer { purchasing = nil }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            await handle(verificationResult: verification)
            await refreshEntitlement()
            return isEntitled
        case .userCancelled:
            log.notice("purchase userCancelled")
            return false
        case .pending:
            // Family approval / SCA challenge. Transaction will arrive via the updates
            // listener once Apple has processed it; nothing else to do here.
            log.notice("purchase pending (waiting for parental approval / 3DS)")
            return false
        @unknown default:
            log.error("purchase returned unknown result")
            return false
        }
    }

    /// `AppStore.sync()` triggers Apple to re-deliver any past purchases this account owns.
    /// We then re-resolve `currentEntitlements`. If nothing comes back the toast says so.
    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isEntitled {
                lastError = "No active subscription found on this Apple ID."
            }
        } catch {
            log.error("restore failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Walk `Transaction.currentEntitlements` and set `status` to the latest matching one.
    /// Apple guarantees the most recent transaction for a subscription group wins.
    func refreshEntitlement() async {
        var latest: SubscriptionStatus = .none
        var latestJWS: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result,
                  SubscriptionProductID.all.contains(tx.productID) else { continue }

            let expires = tx.expirationDate
            // `revocationDate` non-nil = Apple revoked the transaction (refund, family share
            // ended, etc.) — treat as no entitlement.
            if tx.revocationDate != nil { continue }

            if let expires, expires < Date() {
                // Past expiration but Apple still hands it back in currentEntitlements:
                // that's the grace-period signal per StoreKit2 docs.
                latest = .inGracePeriod(expires: expires)
            } else {
                latest = .active(expires: expires)
            }
            // The Worker needs the original JWS (not the decoded payload) to verify
            // signature + cert chain. `result.jwsRepresentation` is on the
            // `VerificationResult`, not the inner `Transaction`, so reach back for it.
            latestJWS = result.jwsRepresentation
        }
        status = latest
        currentJWS = latestJWS
        log.notice("entitlement refresh: \(String(describing: self.status), privacy: .public) jws=\(latestJWS != nil ? "yes" : "no", privacy: .public)")
    }

    private func handle(verificationResult: VerificationResult<Transaction>) async {
        switch verificationResult {
        case .verified(let tx):
            // Always finish() — failing to call `finish()` keeps the transaction in the
            // queue and Apple will keep re-delivering it. We've recorded it via the
            // entitlement refresh, so we're done with the transaction object itself.
            await tx.finish()
            log.notice("handled transaction \(tx.id, privacy: .public) product=\(tx.productID, privacy: .public)")
        case .unverified(let tx, let error):
            // Apple couldn't verify the JWS signature. Don't grant entitlement — this is
            // either tampering or a corrupted receipt. Surface to the operator so they can
            // restore from a clean Apple ID.
            log.error("UNVERIFIED transaction \(tx.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

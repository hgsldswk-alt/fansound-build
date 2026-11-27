import Foundation
import Combine
import StoreKit

@MainActor
final class Purchases: ObservableObject {
    let proID = L.bundle.object(forInfoDictionaryKey: "FanProProductID") as? String ?? "com.hgsldswk.fansound.pro"
    let trialID = L.bundle.object(forInfoDictionaryKey: "FanTrialProductID") as? String ?? "com.hgsldswk.fansound.trial"

    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?
    private var deliver: ((StoreKit.Transaction) -> Void)?
    private var onRefresh: (() -> Void)?

    private var enabled: Bool { !Launch.isFree && !Launch.isUITesting }

    func observe(deliver: @escaping (StoreKit.Transaction) -> Void, onRefresh: @escaping () -> Void) {
        guard enabled, updates == nil else { return }
        self.deliver = deliver
        self.onRefresh = onRefresh
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    self.deliver?(transaction)
                    self.onRefresh?()
                    if transaction.productID == self.proID || transaction.productID == self.trialID {
                        await transaction.finish()
                    }
                }
            }
        }
        Task { await refresh() }
    }

    deinit { updates?.cancel() }

    func refresh() async {
        guard enabled else { return }
        for id in [proID, trialID] {
            if let result = await StoreKit.Transaction.latest(for: id),
               case .verified(let transaction) = result {
                deliver?(transaction)
            }
        }
        onRefresh?()
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func load() async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            products = try await Product.products(for: [proID, trialID])
            if products.count != 2 { message = L.t("purchase.unavailable") }
        } catch {
            message = L.t("purchase.unavailable")
        }
    }

    func purchase(_ id: String) async {
        guard enabled, !busy, let product = product(id) else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                deliver?(transaction)
                onRefresh?()
                await transaction.finish()
            case .success(.unverified):
                message = L.t("purchase.unverified")
            case .pending:
                message = L.t("purchase.pending")
            case .userCancelled:
                break
            @unknown default:
                message = L.t("purchase.failed")
            }
        } catch {
            message = L.t("purchase.failed")
        }
    }

    func restore() async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            message = L.t("purchase.restoreComplete")
        } catch {
            message = L.t("purchase.restoreFailed")
        }
    }
}

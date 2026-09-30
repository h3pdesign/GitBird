import Foundation
import Observation
import StoreKit

/// Optional consumable tips never change access to app features.
@MainActor
@Observable
final class SupportPurchaseManager {
    static let productID = "com.h3p.GitBird.support.tip"

    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var canMakePayments = false
    private(set) var hasCheckedAvailability = false
    var statusMessage: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var unfinishedTask: Task<Void, Never>?
    @ObservationIgnored private var completedTips = 0
    @ObservationIgnored private let loadProducts: @MainActor () async throws -> [Product]
    @ObservationIgnored private let paymentAvailability: @MainActor () -> Bool

    init(
        loadProducts: @escaping @MainActor () async throws -> [Product] = {
            try await Product.products(for: [SupportPurchaseManager.productID])
        },
        paymentAvailability: @escaping @MainActor () -> Bool = { AppStore.canMakePayments }
    ) {
        self.loadProducts = loadProducts
        self.paymentAvailability = paymentAvailability
    }

    deinit {
        updatesTask?.cancel()
        unfinishedTask?.cancel()
    }

    var canPurchase: Bool {
        hasCheckedAvailability && canMakePayments && product != nil && !isLoading && !isPurchasing
    }

    var purchaseTitle: String {
        if isPurchasing { return "Purchasing…" }
        guard let product else { return "Send Support Tip" }
        return "Send Support Tip — \(product.displayPrice)"
    }

    /// Start once for the app lifetime, including purchases approved after Settings closes.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.complete(result)
            }
        }
        unfinishedTask = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard let self else { return }
                await self.complete(result)
            }
        }
    }

    func refresh() async {
        canMakePayments = paymentAvailability()
        hasCheckedAvailability = true
        if let loadTask {
            await loadTask.value
            return
        }
        isLoading = true
        let task = Task {
            defer { isLoading = false }
            do {
                let products = try await loadProducts()
                // A transient response must not erase already validated pricing.
                if let tip = products.first(where: { $0.id == Self.productID && $0.type == .consumable }) {
                    product = tip
                }
            } catch is CancellationError {
                return
            } catch {
                if product == nil {
                    statusMessage = "Couldn’t load the App Store price. Please try again."
                }
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func purchase(using purchase: @MainActor (Product) async throws -> Product.PurchaseResult = { try await $0.purchase() }) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        statusMessage = nil
        // Recheck restrictions immediately before presenting the payment sheet.
        canMakePayments = paymentAvailability()
        hasCheckedAvailability = true
        guard canMakePayments else {
            statusMessage = "In-App Purchases are unavailable. Check your App Store account and payment restrictions."
            return
        }
        if product == nil { await refresh() }
        guard let product else {
            statusMessage = "The support tip is currently unavailable. Please retry the App Store."
            return
        }
        let completedBeforePurchase = completedTips
        do {
            switch try await purchase(product) {
            case .success(let result):
                await complete(result)
            case .pending:
                if completedTips == completedBeforePurchase {
                    statusMessage = "Your support tip is pending approval. You can keep using GitBird."
                }
            case .userCancelled:
                if completedTips == completedBeforePurchase {
                    statusMessage = "Purchase canceled."
                }
            @unknown default:
                statusMessage = "The purchase did not complete. Please try again."
            }
        } catch is CancellationError {
            return
        } catch {
            statusMessage = "The purchase failed. Please try again."
        }
    }

    private func complete(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == Self.productID,
                  transaction.productType == .consumable,
                  transaction.revocationDate == nil else { return }
            completedTips += 1
            statusMessage = "Thank you for supporting GitBird!"
            await transaction.finish()
        case .unverified(let transaction, _):
            guard transaction.productID == Self.productID else { return }
            statusMessage = "The App Store transaction couldn’t be verified. No support tip was acknowledged."
        }
    }
}

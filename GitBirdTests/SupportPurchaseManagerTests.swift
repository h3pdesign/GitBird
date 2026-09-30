import XCTest
import StoreKit
import StoreKitTest
@testable import GitBird

@MainActor
private final class TestState {
    var lookups = 0
    var fails = true
    var calls = 0
    var purchaseGate: CheckedContinuation<Void, Never>?
}

@MainActor
final class SupportPurchaseManagerTests: XCTestCase {
    func testMissingProductCannotStartPurchase() async {
        let manager = SupportPurchaseManager(loadProducts: { [] }, paymentAvailability: { true })
        XCTAssertFalse(manager.canPurchase)
        await manager.refresh()
        XCTAssertTrue(manager.hasCheckedAvailability)
        XCTAssertFalse(manager.canPurchase)
        var invoked = false
        await manager.purchase { _ in invoked = true; return .userCancelled }
        XCTAssertFalse(invoked)
        XCTAssertFalse(manager.isPurchasing)
        XCTAssertNotNil(manager.statusMessage)
    }

    func testRestrictedPaymentsCannotStartPurchase() async {
        let state = TestState()
        let manager = SupportPurchaseManager(loadProducts: { state.lookups += 1; return [] }, paymentAvailability: { false })
        await manager.refresh()
        XCTAssertEqual(state.lookups, 1, "Pricing must load even when payments are restricted")
        var invoked = false
        await manager.purchase { _ in invoked = true; return .userCancelled }
        XCTAssertFalse(invoked)
        XCTAssertFalse(manager.canPurchase)
        XCTAssertFalse(manager.isPurchasing)
    }

    func testConcurrentRefreshSharesLookupAndPreservesPurchaseFeedback() async {
        let state = TestState()
        let manager = SupportPurchaseManager(loadProducts: {
            state.lookups += 1
            try await Task.sleep(for: .milliseconds(20))
            return []
        }, paymentAvailability: { true })
        manager.statusMessage = "Thank you for supporting GitBird!"
        async let first: Void = manager.refresh()
        async let second: Void = manager.refresh()
        _ = await (first, second)
        XCTAssertEqual(state.lookups, 1)
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(manager.statusMessage, "Thank you for supporting GitBird!")
    }

    func testLookupFailureAndRetry() async {
        let state = TestState()
        let manager = SupportPurchaseManager(loadProducts: {
            if state.fails { throw URLError(.notConnectedToInternet) }
            return []
        }, paymentAvailability: { true })
        await manager.refresh()
        XCTAssertFalse(manager.isLoading)
        XCTAssertNotNil(manager.statusMessage)
        state.fails = false
        manager.statusMessage = nil
        await manager.refresh()
        XCTAssertFalse(manager.isLoading)
        XCTAssertNil(manager.statusMessage)
    }

    func testStoreKitPurchaseStatesAndRepeatableTip() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SupportOptional", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let manager = SupportPurchaseManager(paymentAvailability: { true })
        manager.start()
        await manager.refresh()
        let product = try XCTUnwrap(manager.product, "Local StoreKit must return the configured tip")
        XCTAssertEqual(product.id, SupportPurchaseManager.productID)
        XCTAssertEqual(manager.product?.type, .consumable)
        XCTAssertTrue(manager.canPurchase)
        XCTAssertFalse(try XCTUnwrap(manager.product).displayPrice.isEmpty)

        await manager.purchase { _ in .userCancelled }
        XCTAssertEqual(manager.statusMessage, "Purchase canceled.")
        await manager.purchase { _ in .pending }
        XCTAssertTrue(manager.statusMessage?.contains("pending") == true)
        await manager.purchase { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(manager.statusMessage, "The purchase failed. Please try again.")
        XCTAssertTrue(manager.canPurchase)

        var purchasedIDs: [UInt64] = []
        let purchase: @MainActor (Product) async throws -> Product.PurchaseResult = { product in
            let result = try await product.purchase()
            if case .success(.verified(let transaction)) = result {
                purchasedIDs.append(transaction.id)
            }
            return result
        }
        await manager.purchase(using: purchase)
        XCTAssertEqual(manager.statusMessage, "Thank you for supporting GitBird!")
        XCTAssertTrue(manager.canPurchase)
        await manager.purchase(using: purchase)
        XCTAssertEqual(Set(purchasedIDs).count, 2, "Repeat tips must create separate transactions: \(purchasedIDs)")
        XCTAssertEqual(session.allTransactions().count, 2)
        // StoreKit's sequence snapshot can lag the finish acknowledgement. Assert
        // the external state settles within a deadline, without finishing it here.
        let deadline = Date.now.addingTimeInterval(2)
        var unfinishedTips: [UInt64] = []
        repeat {
            unfinishedTips = []
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result,
                   transaction.productID == SupportPurchaseManager.productID {
                    unfinishedTips.append(transaction.id)
                }
            }
            if unfinishedTips.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        } while Date.now < deadline
        XCTAssertTrue(unfinishedTips.isEmpty, "Verified tips must finish; remaining transaction IDs: \(unfinishedTips)")

        let state = TestState()
        let first = Task { @MainActor in
            await manager.purchase { _ in
                state.calls += 1
                await withCheckedContinuation { state.purchaseGate = $0 }
                return .userCancelled
            }
        }
        while state.purchaseGate == nil { await Task.yield() }
        await manager.purchase { _ in state.calls += 1; return .pending }
        state.purchaseGate?.resume()
        await first.value
        XCTAssertEqual(state.calls, 1, "Only one payment sheet may be presented at a time")
    }
}

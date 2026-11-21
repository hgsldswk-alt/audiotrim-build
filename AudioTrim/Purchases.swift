import Foundation
import StoreKit
import SwiftUI

actor EntitlementDisk {
    let url: URL
    init(_ url: URL) { self.url = url }

    func read() -> Entitlement? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entitlement.self, from: data)
    }

    func save(_ value: Entitlement) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published var notice: ClipFailure?
    @Published var expiry = false

    let free: Bool
    private let disk: EntitlementDisk
    private let simulated: Bool
    private let expired: Bool
    private var updates: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false
    private let launchWall = Date()
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private var now: Date {
        max(Date(), launchWall.addingTimeInterval(ProcessInfo.processInfo.systemUptime - launchUptime))
    }

    let proID = Bundle.main.object(forInfoDictionaryKey: "AudioTrimProProductID") as? String
        ?? "com.hgsldswk.audiotrim.pro"
    let trialID = Bundle.main.object(forInfoDictionaryKey: "AudioTrimTrialProductID") as? String
        ?? "com.hgsldswk.audiotrim.trial"

    init(root: URL, arguments: [String], simulated: Bool) {
        disk = EntitlementDisk(root.appendingPathComponent("entitlement.json"))
        self.simulated = simulated
        expired = simulated && arguments.contains("-expired")
        free = Launch.isFree(arguments: arguments) || (simulated && arguments.contains("-store-shots"))
    }

    deinit { updates?.cancel() }

    var hasPro: Bool { ready && entitlement.hasPro(at: now, free: free) }
    var pro: Product? { products.first { $0.id == proID } }
    var trial: Product? { products.first { $0.id == trialID } }
    var daysRemaining: Int {
        max(0, Int(ceil(entitlement.trialEnd.timeIntervalSince(entitlement.effectiveDate(now)) / 86400)))
    }

    func start() async {
        guard !ready else { return }
        let now = self.now
        var value = await disk.read() ?? Entitlement(firstOpen: now)
        value.open(at: now, free: free)
        if expired {
            value.proStartedAt = now.addingTimeInterval(-31 * 86400)
            value.trialClaimedAt = nil
            value.purchasedPro = false
            value.showedExpiry = true
        }
        entitlement = value
        await save()
        ready = true
        guard !free, !simulated else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      [self.proID, self.trialID].contains(transaction.productID) else { continue }
                await self.refresh()
                await transaction.finish()
            }
        }
        Task { await refresh() }
    }

    func foreground() async {
        guard ready, !free else { return }
        entitlement.open(at: now, free: free)
        await save()
        if !simulated { await refresh() }
    }

    func checkExpiry() async {
        guard ready, !free, !simulated, !entitlement.purchasedPro, !entitlement.showedExpiry,
              entitlement.effectiveDate(now) >= entitlement.trialEnd else { return }
        entitlement.showedExpiry = true
        await save()
        expiry = true
    }

    func load() async {
        guard !free, !simulated, products.count < 2, !busy else { return }
        busy = true
        defer { busy = false }
        do { products = try await Product.products(for: [proID, trialID]) }
        catch { notice = .store }
    }

    func buy(_ id: String) async {
        guard !free, !simulated, !busy else { return }
        if products.first(where: { $0.id == id }) == nil { await load() }
        guard let product = products.first(where: { $0.id == id }) else { notice = .store; return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                accept(transaction)
                await save()
                await refresh()
                await transaction.finish()
            case .success(.unverified): notice = .store
            case .pending: notice = .pending
            case .userCancelled: break
            @unknown default: notice = .store
            }
        } catch { notice = .store }
    }

    func restore() async {
        guard !free, !simulated, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
        } catch { notice = .store }
    }

    private func accept(_ transaction: StoreKit.Transaction) {
        if transaction.productID == proID { entitlement.purchasedPro = transaction.revocationDate == nil }
        if transaction.productID == trialID, transaction.revocationDate == nil {
            entitlement.trialClaimedAt = min(entitlement.trialClaimedAt ?? .distantFuture, transaction.originalPurchaseDate)
        }
    }

    private func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            var owned = false
            var comparable = true
            for await result in StoreKit.Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    guard transaction.revocationDate == nil else { continue }
                    if transaction.productID == proID { owned = true }
                    if transaction.productID == trialID { accept(transaction) }
                case .unverified(let transaction, _):
                    if transaction.productID == proID { comparable = false }
                }
            }
            if comparable { entitlement.purchasedPro = owned }
            await save()
        } while refreshAgain
        refreshing = false
    }

    private func save() async {
        do { try await disk.save(entitlement) }
        catch { notice = .data }
    }
}

import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen = Date()
    var trialClaimedAt: Date?
    var purchasedPro = false
    var proStartedAt: Date?
    var latestSeen: Date?
    var showedExpiry = false

    var trialStart: Date { min(proStartedAt ?? firstOpen, trialClaimedAt ?? .distantFuture) }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86400) }
    func effectiveDate(_ now: Date) -> Date { max(now, latestSeen ?? now) }

    mutating func open(at now: Date, free: Bool) {
        if !free && proStartedAt == nil { proStartedAt = now }
        latestSeen = effectiveDate(now)
    }

    func isPremium(at now: Date) -> Bool {
        let effective = effectiveDate(now)
        return purchasedPro || (effective >= trialStart && effective < trialEnd)
    }
    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool { free || isPremium(at: now) }
}

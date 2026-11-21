import Foundation

struct Milestone: Equatable, Sendable {
    var count: Int
    var seconds: Double
}

struct SharingProgress: Codable, Sendable {
    private(set) var clipped: [String: Double] = [:]
    private(set) var effectiveExports = 0
    private(set) var exportDays: Set<Date> = []
    private(set) var shared = false
    private(set) var reviewRequestedAt: Date?
    private(set) var reviewedVersions: Set<String> = []
    private(set) var shownMilestones: Set<Int> = []

    mutating func record(source: SourceAsset, spec: ExportSpec, single: Bool, date: Date,
                         calendar: Calendar = .current) -> Milestone? {
        guard spec.selection.count < source.frames else { return nil }
        if single {
            effectiveExports += 1
            if exportDays.count < 2 { exportDays.insert(calendar.startOfDay(for: date)) }
        }
        guard clipped[source.hash] == nil else { return nil }
        clipped[source.hash] = Double(spec.selection.count) / Double(source.rate)
        let count = clipped.count
        guard [5, 20, 50].contains(count), shownMilestones.insert(count).inserted else { return nil }
        return Milestone(count: count, seconds: clipped.values.reduce(0, +))
    }

    mutating func completedShare() { shared = true }

    mutating func claimReview(at now: Date, version: String) -> Bool {
        guard eligibleForReview(at: now, version: version) else { return false }
        reviewedVersions.insert(version)
        reviewRequestedAt = now
        return true
    }

    func eligibleForReview(at now: Date, version: String) -> Bool {
        effectiveExports >= 3 && exportDays.count >= 2 && shared && !reviewedVersions.contains(version)
            && (reviewRequestedAt.map { now.timeIntervalSince($0) >= 120 * 86400 } ?? true)
    }
}

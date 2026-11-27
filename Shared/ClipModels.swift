import Foundation

struct FrameRange: Codable, Equatable, Hashable, Sendable {
    var start: Int64
    var end: Int64
    var count: Int64 { end - start }

    static func minimum(total: Int64, rate: Int) -> Int64 { min(total, Int64((rate + 9) / 10)) }

    func isValid(total: Int64, rate: Int) -> Bool {
        total > 0 && rate > 0 && start >= 0 && end <= total && end > start
            && count >= Self.minimum(total: total, rate: rate)
    }

    func movingStart(_ frame: Int64, total: Int64, rate: Int) -> Self {
        .init(start: min(max(0, frame), end - Self.minimum(total: total, rate: rate)), end: end)
    }

    func movingEnd(_ frame: Int64, total: Int64, rate: Int) -> Self {
        .init(start: start, end: max(start + Self.minimum(total: total, rate: rate), min(total, frame)))
    }

    func segments(cuts: [Int64], total: Int64, rate: Int) -> [Self]? {
        guard isValid(total: total, rate: rate), !cuts.isEmpty else { return nil }
        let edges = [start] + Array(Set(cuts)).sorted() + [end]
        let ranges = zip(edges, edges.dropFirst()).map { Self(start: $0.0, end: $0.1) }
        return ranges.allSatisfy { $0.isValid(total: total, rate: rate) } ? ranges : nil
    }
}

enum ClipPreset: String, Codable, CaseIterable {
    case both, head, all

    func range(total: Int64, rate: Int) -> FrameRange? {
        let second = Int64(rate)
        let result: FrameRange
        switch self {
        case .both: result = .init(start: second, end: total - second)
        case .head: result = .init(start: second, end: total)
        case .all: result = .init(start: 0, end: total)
        }
        return result.isValid(total: total, rate: rate) ? result : nil
    }
}

enum ClipClock {
    static func parse(_ text: String, rate: Int) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard rate > 0, (1...3).contains(parts.count), let last = parts.last,
              last.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let seconds = Double(last), parts.count == 1 || seconds < 60 else { return nil }
        var value = seconds
        for (index, part) in parts.dropLast().reversed().enumerated() {
            guard part.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  let number = Double(part), index != 0 || parts.count != 3 || number < 60 else { return nil }
            value += number * (index == 0 ? 60 : 3600)
        }
        let frames = (value * Double(rate)).rounded()
        guard frames.isFinite, frames < Double(Int64.max) else { return nil }
        return Int64(frames)
    }

    static func display(_ frame: Int64, rate: Int, fractions: Bool = true) -> String {
        guard rate > 0 else { return "00:00" }
        let value = Double(max(frame, 0)) / Double(rate)
        let whole = fractions ? Int64((value * 100).rounded()) : Int64(value) * 100
        let seconds = whole / 100
        let minutes = seconds / 60
        let base = minutes >= 60
            ? String(format: "%02lld:%02lld:%02lld", minutes / 60, minutes % 60, seconds % 60)
            : String(format: "%02lld:%02lld", minutes, seconds % 60)
        guard fractions else { return base }
        let separator = Locale.current.decimalSeparator ?? "."
        return base + separator + String(format: "%02lld", whole % 100)
    }
}

enum SourceKind: String, Codable, Sendable { case audio, video, recording }

struct SourceAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var originalName: String
    var storedName: String
    var kind: SourceKind
    var hash: String
    var trackIndex: Int
    var rate: Int
    var channels: Int
    var frames: Int64
    var bytes: Int64
    var audioFrames: FrameRange { .init(start: 0, end: frames) }
    var title: String { (originalName as NSString).deletingPathExtension }
    var label: String { (originalName as NSString).pathExtension.uppercased() }
}

struct Draft: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var sourceID: UUID
    var selection: FrameRange
    var preset: ClipPreset?
    var cuts: [Int64] = []
    var zoom = 1.0
    var center = 0.5
    var updatedAt = Date()

    init(source: SourceAsset) {
        sourceID = source.id
        selection = source.audioFrames
    }
}

enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case m4a, wav
    var title: String { rawValue.uppercased() }
    var codec: String { self == .m4a ? "M4A / AAC" : "WAV / 16-bit PCM" }
}

struct ExportSpec: Codable, Equatable, Hashable, Sendable {
    var draftID: UUID
    var sourceID: UUID
    var selection: FrameRange
    var format: ExportFormat
    var merge: MergeSpec? = nil
    var fade: Double? = nil
}

enum ExportFade {
    static let choices: [Double] = [0, 1, 2, 3, 5, 10]

    static func frames(seconds: Double?, rate: Int, total: Int64) -> Int64 {
        guard let seconds, seconds > 0, total > 1 else { return 0 }
        return min(Int64(seconds * Double(rate)), total / 2)
    }

    static func gain(frame: Int64, total: Int64, fadeFrames: Int64) -> Float {
        guard fadeFrames > 0 else { return 1 }
        let fromStart = Float(frame) / Float(fadeFrames)
        let toEnd = Float(total - 1 - frame) / Float(fadeFrames)
        return max(0, min(1, fromStart, toEnd))
    }
}

enum MergeGap: Int, CaseIterable, Codable, Sendable {
    case none = 0, half = 500, one = 1000

    var seconds: Double { Double(rawValue) / 1000 }

    func duration(of sources: [SourceAsset]) -> Double {
        sources.reduce(seconds * Double(max(0, sources.count - 1))) {
            $0 + Double($1.frames) / Double($1.rate)
        }
    }
}

struct MergeSpec: Codable, Equatable, Hashable, Sendable {
    var sourceIDs: [UUID]
    var gap: MergeGap
}

struct ExportItem: Identifiable, Codable, Sendable {
    var id = UUID()
    var spec: ExportSpec
    var fileName: String
    var failure: ClipFailure?
}

enum JobKind: String, Codable, Sendable { case single, split, batch, merge }

struct ExportJob: Identifiable, Codable, Sendable {
    var id = UUID()
    var kind: JobKind
    var authorizedAt: Date
    var items: [ExportItem]
}

struct ExportRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var spec: ExportSpec
    var fileName: String
    var seconds: Double
    var bytes: Int64
    var createdAt = Date()
}

enum ClipFailure: String, Error, Codable, Sendable {
    case access, damaged, unsupported, noAudio, protected, channels, storage, export, paused
    case badCode, differentSource, microphone, recording, playback, data
    var messageKey: String { "error." + rawValue }
}

struct WavePeaks: Codable, Sendable {
    var framesPerPeak: Int
    var levels: [[UInt16]]

    init(framesPerPeak: Int, peaks: [UInt16]) {
        self.framesPerPeak = framesPerPeak
        levels = [peaks]
        var current = peaks
        while current.count > 96 {
            var reduced: [UInt16] = []
            reduced.reserveCapacity((current.count + 1) / 2)
            for index in stride(from: 0, to: current.count, by: 2) {
                reduced.append(max(current[index], current[min(index + 1, current.count - 1)]))
            }
            levels.append(reduced)
            current = reduced
        }
    }

    func values(in range: FrameRange, bars: Int) -> [Double] {
        guard bars > 0, range.start >= 0, range.end > range.start, framesPerPeak > 0, !levels.isEmpty else { return [] }
        let perBar = max(1, range.count / Int64(bars))
        var level = 0
        var window = Int64(framesPerPeak)
        while level + 1 < levels.count && window * 2 <= perBar {
            window *= 2
            level += 1
        }
        let base = levels[0]
        guard !base.isEmpty else { return [] }
        let step = window / Int64(framesPerPeak)
        return (0..<bars).map { index in
            let startFrame = range.start + range.count * Int64(index) / Int64(bars)
            let endFrame = range.start + range.count * Int64(index + 1) / Int64(bars)
            var position = min(Int64(base.count - 1), startFrame / Int64(framesPerPeak))
            let end = min(Int64(base.count), max(position + 1, (endFrame + Int64(framesPerPeak - 1)) / Int64(framesPerPeak)))
            var peak: UInt16 = 0
            while position < end {
                var block = step
                var detail = level
                while position % block != 0 || position + block > end {
                    block /= 2
                    detail -= 1
                }
                peak = max(peak, levels[detail][Int(position / block)])
                position += block
            }
            return min(1, Double(peak) / 32768)
        }
    }
}

struct LibraryState: Codable, Sendable {
    var version = 1
    var sources: [SourceAsset] = []
    var drafts: [Draft] = []
    var jobs: [ExportJob] = []
    var records: [ExportRecord] = []
    var progress = SharingProgress()

    func source(for draft: Draft) -> SourceAsset? { sources.first { $0.id == draft.sourceID } }
}

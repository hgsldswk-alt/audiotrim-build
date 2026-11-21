import Foundation

struct SelectionCode: Codable, Equatable, Sendable {
    static let typeIdentifier = "com.hgsldswk.audiotrim.selection"
    static let maxSize = 2048
    var version = 1
    var start: Int64
    var end: Int64
    var timescale: Int
    var duration: Int64
    var sha256: String

    init(source: SourceAsset, range: FrameRange) {
        start = range.start
        end = range.end
        timescale = source.rate
        duration = source.frames
        sha256 = source.hash
    }

    var range: FrameRange { .init(start: start, end: end) }

    func matches(_ source: SourceAsset) -> Bool {
        source.hash == sha256 && source.rate == timescale && source.frames == duration
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func token(prefix: String) throws -> String {
        let base = try encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(prefix) AC1:\(base)"
    }

    static func decode(token: String) throws -> Self {
        guard token.utf8.count <= maxSize,
              let marker = token.range(of: "AC1:") else { throw ClipFailure.badCode }
        var value = String(token[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw ClipFailure.badCode }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw ClipFailure.badCode }
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> Self {
        guard data.count <= maxSize, let clip = try? JSONDecoder().decode(Self.self, from: data),
              clip.version == 1, [44100, 48000].contains(clip.timescale),
              clip.sha256.utf8.count == 64,
              clip.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              clip.range.isValid(total: clip.duration, rate: clip.timescale) else { throw ClipFailure.badCode }
        return clip
    }
}

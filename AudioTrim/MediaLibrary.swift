import AVFoundation
import CryptoKit
import Foundation

actor MediaLibrary {
    struct JobResult {
        var records: [ExportRecord]
        var milestone: Milestone?
    }

    let root: URL
    let cache: URL
    private var state = LibraryState()
    private var opened = false
    private let files = FileManager.default
    private var running: UUID?

    init(root: URL, cache: URL) {
        self.root = root
        self.cache = cache
    }

    private var manifest: URL { root.appendingPathComponent("library.json") }
    private var media: URL { root.appendingPathComponent("Sources", isDirectory: true) }
    private var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    private var inbox: URL { root.appendingPathComponent("Imports", isDirectory: true) }

    func open() throws -> LibraryState {
        if opened { return state }
        for folder in [root, media, exports, inbox, cache] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if files.fileExists(atPath: manifest.path) {
            let loaded = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest))
            guard loaded.version == 1 else { throw ClipFailure.data }
            state = loaded
            for index in state.drafts.indices {
                let draft = state.drafts[index]
                guard let source = state.source(for: draft),
                      draft.selection.isValid(total: source.frames, rate: source.rate) else {
                    throw ClipFailure.data
                }
                state.drafts[index].zoom = min(32, max(1, draft.zoom))
                state.drafts[index].center = min(1, max(0, draft.center))
            }
        }
        let known = Set(state.sources.map { $0.id.uuidString })
        for url in try files.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)
            where !known.contains(url.lastPathComponent) {
            try? files.removeItem(at: url)
        }
        for url in try files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
            try? files.removeItem(at: url)
        }
        for folder in try files.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil) {
            for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where url.deletingPathExtension().lastPathComponent == "partial" {
                try? files.removeItem(at: url)
            }
        }
        opened = true
        return state
    }

    func snapshot() -> LibraryState { state }

    private func write(_ next: LibraryState) throws {
        do {
            try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
            state = next
        } catch { throw MediaIO.map(error, fallback: .data) }
    }

    @discardableResult func save(_ draft: Draft, coreAction: Bool = false) throws -> CoreReviewProgress? {
        guard let index = state.drafts.firstIndex(where: { $0.id == draft.id }),
              state.drafts[index].updatedAt <= draft.updatedAt,
              let asset = state.source(for: draft),
              draft.selection.isValid(total: asset.frames, rate: asset.rate) else { return nil }
        var next = state
        if coreAction {
            next.progress.coreReviewProgress = .recording(next.progress.coreReviewProgress)
        }
        next.drafts[index] = draft
        try write(next)
        return coreAction ? next.progress.coreReviewProgress : nil
    }

    private func folder(for source: SourceAsset) -> URL {
        media.appendingPathComponent(source.id.uuidString, isDirectory: true)
    }

    func pcmURL(_ source: SourceAsset) -> URL { folder(for: source).appendingPathComponent("audio.caf") }
    private func waveURL(_ source: SourceAsset) -> URL { cache.appendingPathComponent(source.id.uuidString + ".plist") }

    func wave(_ source: SourceAsset) throws -> WavePeaks {
        let location = waveURL(source)
        if let data = try? Data(contentsOf: location),
           let value = try? PropertyListDecoder().decode(WavePeaks.self, from: data) { return value }
        let result = try MediaIO.wave(for: pcmURL(source), rate: source.rate)
        storeWave(result, at: location)
        return result
    }

    private func storeWave(_ wave: WavePeaks, at url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(wave) { try? data.write(to: url, options: .atomic) }
    }

    func importFile(_ url: URL, kind: SourceKind, displayName: String? = nil,
                    usingAccess acquired: Bool = false) async throws -> Draft {
        var accessForCopy = acquired
        defer { if accessForCopy { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { throw ClipFailure.access }
        let id = UUID()
        let staging = inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let extensionName = url.pathExtension
        let original = staging.appendingPathComponent("original").appendingPathExtension(extensionName)
        accessForCopy = false
        let fingerprint = try Self.copy(url, to: original, usingAccess: acquired)
        if let source = state.sources.first(where: {
            $0.hash == fingerprint.hash && files.fileExists(atPath: pcmURL($0).path)
        }), let draft = state.drafts.filter({ $0.sourceID == source.id }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return draft
        }
        let decoded = try await MediaIO.decode(original, to: staging.appendingPathComponent("audio.caf"))
        try Task.checkCancellation()
        let source = SourceAsset(id: id, originalName: displayName ?? url.lastPathComponent,
                                 storedName: original.lastPathComponent, kind: kind, hash: fingerprint.hash,
                                 trackIndex: decoded.track, rate: decoded.rate, channels: decoded.channels,
                                 frames: decoded.frames, bytes: fingerprint.bytes)
        let draft = Draft(source: source)
        let destination = folder(for: source)
        try files.moveItem(at: staging, to: destination)
        var next = state
        next.sources.append(source)
        next.drafts.append(draft)
        do { try write(next) }
        catch {
            try? files.removeItem(at: destination)
            throw error
        }
        storeWave(decoded.wave, at: waveURL(source))
        return draft
    }

    private static func copy(_ url: URL, to destination: URL, usingAccess acquired: Bool) throws -> (hash: String, bytes: Int64) {
        let access = acquired || url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<(String, Int64), Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let input = try FileHandle(forReadingFrom: readable)
                defer { try? input.close() }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw ClipFailure.storage
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var hash = SHA256()
                var length: Int64 = 0
                while let piece = try input.read(upToCount: 1_048_576), !piece.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: piece)
                    length += Int64(piece.count)
                    try output.write(contentsOf: piece)
                }
                guard length > 0 else { throw ClipFailure.damaged }
                try output.synchronize()
                return (hash.finalize().map { String(format: "%02x", $0) }.joined(), length)
            }
        }
        do {
            if let coordinationError { throw coordinationError }
            guard let result else { throw ClipFailure.access }
            return try result.get()
        } catch { throw MediaIO.map(error, fallback: .access) }
    }

    func readSelection(_ url: URL, usingAccess acquired: Bool = false) throws -> SelectionCode {
        let access = acquired || url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<SelectionCode, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let file = try FileHandle(forReadingFrom: readable)
                defer { try? file.close() }
                return try SelectionCode.decode(data: file.read(upToCount: SelectionCode.maxSize + 1) ?? Data())
            }
        }
        if coordinationError != nil { throw ClipFailure.access }
        guard let result else { throw ClipFailure.access }
        return try result.get()
    }

    func apply(_ code: SelectionCode, to sourceID: UUID) throws -> Draft {
        guard let source = state.sources.first(where: { $0.id == sourceID }), code.matches(source) else {
            throw ClipFailure.differentSource
        }
        var draft = Draft(source: source)
        draft.selection = code.range
        var next = state
        next.drafts.append(draft)
        try write(next)
        return draft
    }

    func enqueue(_ specs: [ExportSpec], kind: JobKind) throws -> ExportJob {
        guard !specs.isEmpty else { throw ClipFailure.data }
        var taken = Set(state.records.map(\.fileName))
        taken.formUnion(state.jobs.flatMap { $0.items.map(\.fileName) })
        let items = try specs.map { spec -> ExportItem in
            guard let source = state.sources.first(where: { $0.id == spec.sourceID }),
                  spec.selection.isValid(total: source.frames, rate: source.rate) else { throw ClipFailure.data }
            if let merge = spec.merge { _ = try mergeSources(merge) }
            let base = String(source.title.filter { !$0.isNewline && !$0.isASCIIControl && !"/\\:".contains($0) }.prefix(48))
            let suffix = spec.merge == nil ? "Clip" : L.t("merge.title")
            let stem = (base.isEmpty ? "Audio" : base) + " - " + suffix
            var name = "\(stem).\(spec.format.rawValue)"
            var number = 2
            while !taken.insert(name).inserted {
                name = "\(stem) \(number).\(spec.format.rawValue)"
                number += 1
            }
            return ExportItem(spec: spec, fileName: name)
        }
        let job = ExportJob(kind: kind, authorizedAt: Date(), items: items)
        var next = state
        next.jobs.append(job)
        try write(next)
        return job
    }

    func run(_ id: UUID, only itemID: UUID? = nil) async throws -> JobResult {
        guard running == nil, let job = state.jobs.first(where: { $0.id == id }) else { throw ClipFailure.data }
        running = id
        defer { running = nil }
        var result = JobResult(records: [], milestone: nil)
        for item in job.items where itemID == nil || item.id == itemID {
            if let record = state.records.first(where: { $0.id == item.id }), available(record) {
                result.records.append(record)
                continue
            }
            if Task.isCancelled { break }
            guard let source = state.sources.first(where: { $0.id == item.spec.sourceID }) else { continue }
            do {
                let record = try await produce(item, source: source)
                var next = state
                let isNew = !next.records.contains { $0.id == record.id }
                next.records.removeAll { $0.id == record.id }
                next.records.append(record)
                updateFailure(nil, id: id, item: item.id, in: &next)
                let milestone = isNew && item.spec.merge == nil ? next.progress.record(source: source, spec: item.spec,
                    single: job.kind == .single, date: record.createdAt) : nil
                try write(next)
                if let milestone { result.milestone = milestone }
                result.records.append(record)
            } catch {
                var next = state
                let issue = MediaIO.map(error, fallback: .export)
                updateFailure(issue, id: id, item: item.id, in: &next)
                try write(next)
                if issue == .paused || Task.isCancelled { break }
            }
        }
        if job.items.allSatisfy({ item in state.records.contains(where: { $0.id == item.id }) }) {
            var next = state
            next.jobs.removeAll { $0.id == id }
            try write(next)
        }
        return result
    }

    private func updateFailure(_ error: ClipFailure?, id: UUID, item: UUID, in next: inout LibraryState) {
        guard let index = next.jobs.firstIndex(where: { $0.id == id }),
              let position = next.jobs[index].items.firstIndex(where: { $0.id == item }) else { return }
        next.jobs[index].items[position].failure = error
    }

    private func produce(_ item: ExportItem, source: SourceAsset) async throws -> ExportRecord {
        let joined = try item.spec.merge.map { merge in
            let sources = try mergeSources(merge)
            return (inputs: sources.map { (source: $0, url: pcmURL($0)) }, seconds: merge.gap.duration(of: sources), gap: merge.gap)
        }
        let expected = joined?.seconds ?? Double(item.spec.selection.count) / Double(source.rate)
        let destination = exportURL(id: item.id, name: item.fileName)
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) {
            if let recovered = try? validate(destination, item: item, expected: expected, rate: source.rate) { return recovered }
            try files.removeItem(at: destination)
        }
        let pcmBytes = item.spec.selection.count * Int64(source.channels * 2)
        let budget = item.spec.format == .wav ? pcmBytes : Int64(expected * 21_000)
        if let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
           Int64(free) < budget + 1_048_576 { throw ClipFailure.storage }
        let partial = folder.appendingPathComponent("partial").appendingPathExtension(item.spec.format.rawValue)
        try? files.removeItem(at: partial)
        defer { try? files.removeItem(at: partial) }
        if let joined {
            try await MediaIO.merge(joined.inputs, gap: joined.gap, to: partial)
        } else {
            try await MediaIO.export(item.spec, source: source, from: pcmURL(source), to: partial)
        }
        var record = try validate(partial, item: item, expected: expected, rate: source.rate)
        try files.moveItem(at: partial, to: destination)
        if let previous = state.records.first(where: { $0.id == item.id }) { record.createdAt = previous.createdAt }
        return record
    }

    private func mergeSources(_ merge: MergeSpec) throws -> [SourceAsset] {
        guard merge.sourceIDs.count >= 2 else { throw ClipFailure.data }
        let sources = Dictionary(uniqueKeysWithValues: state.sources.map { ($0.id, $0) })
        return try merge.sourceIDs.map {
            guard let source = sources[$0] else { throw ClipFailure.data }
            return source
        }
    }

    private func validate(_ url: URL, item: ExportItem, expected: Double, rate: Int) throws -> ExportRecord {
        let audio = try AVAudioFile(forReading: url)
        let seconds = Double(audio.length) / audio.fileFormat.sampleRate
        let tolerance = item.spec.format == .wav ? 1 / Double(rate) : 0.06
        guard seconds.isFinite, seconds > 0, abs(seconds - expected) <= tolerance,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { throw ClipFailure.export }
        return ExportRecord(id: item.id, spec: item.spec, fileName: item.fileName,
                            seconds: seconds, bytes: Int64(size))
    }

    private func exportURL(id: UUID, name: String) -> URL {
        exports.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
    }

    func exportURL(_ record: ExportRecord) -> URL { exportURL(id: record.id, name: record.fileName) }
    func available(_ record: ExportRecord) -> Bool { files.fileExists(atPath: exportURL(record).path) }
    func availableRecords() -> Set<UUID> { Set(state.records.filter { available($0) }.map(\.id)) }

    func rebuild(_ record: ExportRecord) async throws -> ExportRecord {
        guard running == nil, state.records.contains(where: { $0.id == record.id }),
              let source = state.sources.first(where: { $0.id == record.spec.sourceID }) else { throw ClipFailure.data }
        running = record.id
        defer { running = nil }
        let updated = try await produce(ExportItem(id: record.id, spec: record.spec, fileName: record.fileName), source: source)
        var next = state
        if let index = next.records.firstIndex(where: { $0.id == record.id }) { next.records[index] = updated }
        try write(next)
        return updated
    }

    func deleteFile(_ record: ExportRecord) throws {
        guard running == nil else { throw ClipFailure.data }
        if available(record) { try files.removeItem(at: exportURL(record)) }
    }

    func sourceBytes(_ source: SourceAsset) -> Int64 {
        let pcm = (try? pcmURL(source).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return source.bytes + Int64(pcm)
    }

    func deleteDraft(_ draft: Draft) throws {
        guard running == nil else { throw ClipFailure.data }
        var next = state
        let records = next.records.filter { $0.spec.draftID == draft.id }
        let items = next.jobs.flatMap(\.items).filter { $0.spec.draftID == draft.id }
        next.records.removeAll { $0.spec.draftID == draft.id }
        for index in next.jobs.indices { next.jobs[index].items.removeAll { $0.spec.draftID == draft.id } }
        next.jobs.removeAll { $0.items.isEmpty }
        next.drafts.removeAll { $0.id == draft.id }
        let retained = Set(next.drafts.map(\.sourceID)
            + next.records.flatMap { $0.spec.merge?.sourceIDs ?? [] }
            + next.jobs.flatMap(\.items).flatMap { $0.spec.merge?.sourceIDs ?? [] })
        let unusedSources = next.sources.filter { !retained.contains($0.id) }
        next.sources.removeAll { !retained.contains($0.id) }
        try write(next)
        for id in Set(records.map(\.id) + items.map(\.id)) {
            try? files.removeItem(at: exports.appendingPathComponent(id.uuidString))
        }
        for source in unusedSources {
            try? files.removeItem(at: folder(for: source))
            try? files.removeItem(at: waveURL(source))
        }
    }

    func shared() throws {
        var next = state
        next.progress.completedShare()
        try write(next)
    }

    func markReviewRequested(at date: Date, version: String) throws {
        var next = state
        next.progress.markReviewRequested(at: date, version: version)
        try write(next)
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

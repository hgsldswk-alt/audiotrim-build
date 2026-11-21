import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ClipController: ObservableObject {
    enum Panel: String, Identifiable {
        case settings, storage, recording, time, format, split, batch, tasks, result, history
        case card, paywall, shareSelection, importSelection, privacy
        var id: String { rawValue }
    }

    enum Picker { case audio, video, audioOrVideo, selection }
    struct Activity: Identifiable {
        let id = UUID()
        let url: URL
        let countsForReview: Bool
    }
    private struct Incoming {
        let url: URL
        let kind: SourceKind
        let displayName: String?
        let access: Bool
    }

    @Published private(set) var state = LibraryState()
    @Published private(set) var draft: Draft?
    @Published private(set) var peaks: WavePeaks?
    @Published private(set) var availableRecords: Set<UUID> = []
    @Published private(set) var ready = false
    @Published private(set) var unavailable = false
    @Published private(set) var working = false
    @Published private(set) var preparingRecording = false
    @Published private(set) var playhead: Int64?
    @Published private(set) var undo: FrameRange?
    @Published private(set) var result: ExportRecord?
    @Published private(set) var milestone: Milestone?
    @Published private(set) var code: SelectionCode?
    @Published private(set) var codeSource: SourceAsset?
    @Published private(set) var sourceSizes: [UUID: Int64] = [:]
    @Published var panel: Panel?
    @Published var activity: Activity?
    @Published var failure: ClipFailure?
    @Published var notice: String?
    @Published var pickerShown = false
    @Published var picker = Picker.audio

    let purchases: Purchases
    let audio = LocalAudio()
    let simulated: Bool
    let microphoneDenied: Bool
    private let library: MediaLibrary
    private let root: URL
    private let cache: URL
    private let arguments = ProcessInfo.processInfo.arguments
    private var incoming: [Incoming] = []
    private var failedImport: Incoming?
    private var saveTask: Task<Void, Never>?
    private var waveTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var nextPanel: Panel?
    private var booting = false
    private var importingCodeSource = false
    private var reviewEarliest = Date.distantPast
    private var reviewAfterShareNeedsHome = false
    private var resultPeaks: WavePeaks?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    var source: SourceAsset? { draft.flatMap { state.source(for: $0) } }
    var drafts: [Draft] { state.drafts.sorted { $0.updatedAt > $1.updatedAt } }
    var history: [ExportRecord] { state.records.filter { $0.spec.draftID == draft?.id }.sorted { $0.createdAt > $1.createdAt } }
    var cardPeaks: [Double] {
        guard let range = result?.spec.selection else { return [] }
        return resultPeaks?.values(in: range, bars: 88) ?? []
    }
    var resultSource: SourceAsset? { state.sources.first { $0.id == result?.spec.sourceID } }
    var selectedTypes: [UTType] {
        switch picker {
        case .audio: return [.audio]
        case .video: return [.movie, .video]
        case .audioOrVideo: return [.audio, .movie, .video]
        case .selection: return [UTType(exportedAs: SelectionCode.typeIdentifier, conformingTo: .json)]
        }
    }
    var idleHome: Bool {
        ready && !unavailable && draft == nil && panel == nil && !working && !pickerShown && activity == nil
            && failure == nil && notice == nil && !audio.recording && !audio.interrupted
    }

    init() {
        #if DEBUG
        simulated = arguments.contains("-ui-testing")
        #else
        simulated = false
        #endif
        microphoneDenied = simulated && arguments.contains("-mic-denied")
        let manager = FileManager.default
        if simulated {
            let token = ProcessInfo.processInfo.environment["AUDIOTRIM_TEST_SANDBOX"].flatMap(UUID.init(uuidString:)) ?? UUID()
            root = manager.temporaryDirectory.appendingPathComponent("AudioTrim-UI-\(token.uuidString)", isDirectory: true)
            cache = root.appendingPathComponent("Cache", isDirectory: true)
        } else {
            root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AudioTrim", isDirectory: true)
            cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AudioTrim", isDirectory: true)
        }
        library = MediaLibrary(root: root, cache: cache)
        purchases = Purchases(root: root, arguments: simulated ? arguments : [], simulated: simulated)
    }

    func boot() async {
        guard !ready, !booting else { return }
        booting = true
        defer { booting = false }
        if simulated && arguments.contains("-reset") {
            let folder = root
            await Task.detached { try? FileManager.default.removeItem(at: folder) }.value
        }
        do {
            state = try await library.open()
            availableRecords = await library.availableRecords()
            await purchases.start()
            if simulated && (arguments.contains("-fixture") || arguments.contains("-open-fixture")) {
                let file = root.appendingPathComponent("fixtures").appendingPathComponent("podcast.wav")
                try await makeFixture(file)
                if arguments.contains("-open-fixture") {
                    receive(file, kind: .audio, displayName: L.t("fixture.name") + ".wav")
                } else {
                    _ = try await library.importFile(file, kind: .audio, displayName: L.t("fixture.name") + ".wav")
                    await refresh()
                }
            }
            ready = true
            if simulated && arguments.contains("-paywall") { panel = .paywall }
            if simulated && arguments.contains("-code") {
                if let draft = drafts.first, let source = state.source(for: draft),
                   let token = ProcessInfo.processInfo.environment["AUDIOTRIM_SELECTION"] {
                    open(draft)
                    let value = token == "fixture" ? try SelectionCode(source: source,
                        range: ClipPreset.both.range(total: source.frames, rate: source.rate) ?? draft.selection)
                        .token(prefix: L.t("app.name")) : token
                    acceptCode(try SelectionCode.decode(token: value), preferCurrent: true)
                }
            }
            await recoverRecording()
            drain()
        } catch {
            unavailable = !ready
            ready = true
            failure = MediaIO.map(error, fallback: .data)
            if unavailable {
                for item in incoming where item.access { item.url.stopAccessingSecurityScopedResource() }
                incoming.removeAll()
            }
        }
    }

    func receive(_ url: URL, kind: SourceKind = .audio, displayName: String? = nil) {
        guard url.isFileURL, !unavailable else { return }
        let access = url.startAccessingSecurityScopedResource()
        incoming.append(Incoming(url: url, kind: kind, displayName: displayName, access: access))
        drain()
    }

    private func drain() {
        guard ready, !unavailable, !working, !audio.recording, !preparingRecording, !incoming.isEmpty,
              activity == nil, failure == nil,
              panel == nil || panel == .history
              || panel == .importSelection && (importingCodeSource || incoming.first?.url.pathExtension.lowercased() == "audioclip")
        else { return }
        let item = incoming.removeFirst()
        failedImport = nil
        working = true
        flushDraft()
        operation = Task {
            defer {
                working = false
                drain()
            }
            do {
                if item.url.pathExtension.lowercased() == "audioclip" {
                    let value = try await library.readSelection(item.url, usingAccess: item.access)
                    acceptCode(value, preferCurrent: false)
                    return
                }
                let ext = item.url.pathExtension
                let video = UTType(filenameExtension: ext)?.conforms(to: .movie) == true
                    || UTType(filenameExtension: ext)?.conforms(to: .video) == true
                let kind: SourceKind = item.kind == .audio && video ? .video : item.kind
                let imported = try await library.importFile(item.url, kind: kind, displayName: item.displayName, usingAccess: item.access)
                await refresh()
                if kind == .recording {
                    let url = item.url
                    await Task.detached { try? FileManager.default.removeItem(at: url) }.value
                }
                if importingCodeSource, let code {
                    importingCodeSource = false
                    codeSource = state.source(for: imported).flatMap { code.matches($0) ? $0 : nil }
                    if codeSource == nil { failure = .differentSource }
                    if panel == nil { panel = .importSelection }
                } else {
                    open(imported)
                }
            } catch {
                importingCodeSource = false
                let issue = MediaIO.map(error, fallback: .damaged)
                if issue == .storage { failedImport = item }
                failure = issue
            }
        }
    }

    func select(_ picker: Picker, codeSource: Bool = false) {
        self.picker = picker
        importingCodeSource = codeSource
        pickerShown = true
    }

    func picked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let first = urls.first else { importingCodeSource = false; return }
            receive(first, kind: picker == .video ? .video : .audio)
        case .failure(let error):
            importingCodeSource = false
            let cocoa = error as NSError
            if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError { failure = .access }
        }
    }

    func open(_ item: Draft) {
        audio.stopPlayback()
        flushDraft()
        draft = item
        peaks = nil
        undo = nil
        playhead = nil
        waveTask?.cancel()
        guard let source = state.source(for: item) else { return }
        waveTask = Task {
            let loaded = try? await library.wave(source)
            if !Task.isCancelled, draft?.id == item.id { peaks = loaded }
        }
    }

    func home() {
        flushDraft()
        audio.stopPlayback()
        waveTask?.cancel()
        draft = nil
        peaks = nil
        result = nil
        reviewAfterShareNeedsHome = false
    }

    private func refresh() async {
        let latest = await library.snapshot()
        state = latest
        availableRecords = await library.availableRecords()
    }

    private func update(_ apply: (inout Draft) -> Void) {
        guard var item = draft else { return }
        apply(&item)
        item.updatedAt = Date()
        draft = item
        if let index = state.drafts.firstIndex(where: { $0.id == item.id }) { state.drafts[index] = item }
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try await library.save(item)
            } catch is CancellationError {} catch { failure = MediaIO.map(error, fallback: .data) }
        }
    }

    func flushDraft() {
        saveTask?.cancel()
        guard let draft else { return }
        Task {
            do { try await library.save(draft) }
            catch { failure = MediaIO.map(error, fallback: .data) }
        }
    }

    func setRange(_ range: FrameRange, preset: ClipPreset? = nil, remember: Bool = true) {
        guard let source, let draft, range.isValid(total: source.frames, rate: source.rate) else { return }
        if remember && range != draft.selection { undo = draft.selection }
        audio.stopPlayback()
        update { item in
            item.selection = range
            item.preset = preset
        }
        playhead = nil
    }

    func captureUndo() { undo = draft?.selection }

    func undoRange() {
        guard let undo else { return }
        setRange(undo, remember: false)
        self.undo = nil
    }

    func preset(_ value: ClipPreset) {
        guard let source, let range = value.range(total: source.frames, rate: source.rate) else { return }
        setRange(range, preset: value)
    }

    func viewport(zoom: Double, center: Double) {
        let zoom = min(32, max(1, zoom))
        let half = 0.5 / zoom
        update {
            $0.zoom = zoom
            $0.center = min(1 - half, max(half, center))
        }
    }

    func movePlayhead(_ frame: Int64) { playhead = frame }

    func addCut(_ frame: Int64) -> Bool {
        guard let draft, let source, draft.cuts.count < 99, !draft.cuts.contains(frame) else { return false }
        let active = draft.cuts.filter { $0 > draft.selection.start && $0 < draft.selection.end }
        guard draft.selection.segments(cuts: active + [frame], total: source.frames, rate: source.rate) != nil else { return false }
        update { $0.cuts.append(frame); $0.cuts.sort() }
        return true
    }

    func removeCut(_ frame: Int64) { update { $0.cuts.removeAll { $0 == frame } } }

    func preview(range: FrameRange? = nil) {
        guard let source, let draft else { return }
        let selection = range ?? draft.selection
        let key = range == nil ? "selection" : "segment.\(selection.start).\(selection.end)"
        Task {
            do {
                let url = await library.pcmURL(source)
                guard self.draft?.id == draft.id, !working, !audio.recording else { return }
                try audio.toggle(url, key: key,
                                 start: Double(selection.start) / Double(source.rate),
                                 end: Double(selection.end) / Double(source.rate))
            } catch { failure = .playback }
        }
    }

    func preview(_ record: ExportRecord) {
        Task {
            do {
                let url = await library.exportURL(record)
                guard result?.id == record.id, !working, !audio.recording else { return }
                try audio.toggle(url, key: record.id.uuidString)
            }
            catch { failure = .playback }
        }
    }

    func startRecording() {
        guard !working, !preparingRecording, !audio.recording else { return }
        if microphoneDenied { failure = .microphone; return }
        preparingRecording = true
        Task {
            defer { preparingRecording = false; drain() }
            let folder = root.appendingPathComponent("Recordings", isDirectory: true)
            let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            do {
                try await Task.detached { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }.value
                try await audio.startRecording(at: file, simulated: simulated)
                panel = .recording
            } catch { failure = MediaIO.map(error, fallback: .recording) }
        }
    }

    func stopRecording() {
        guard let url = audio.stopRecording(simulated: simulated) else { return }
        panel = nil
        Task {
            do {
                if simulated { try await makeFixture(url, seconds: 2.2) }
                let title = L.t("recording.name") + " " + Date().formatted(.dateTime.month().day().hour().minute()) + ".wav"
                receive(url, kind: .recording, displayName: title.replacingOccurrences(of: "/", with: "-"))
            } catch { failure = .recording }
        }
    }

    private func recoverRecording() async {
        guard !simulated else { return }
        let folder = root.appendingPathComponent("Recordings", isDirectory: true)
        let recovered = await Task.detached {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return candidates.filter { $0.pathExtension == "wav" && RecordingRecovery.isPlayable($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
        for url in recovered {
            receive(url, kind: .recording, displayName: L.t("recording.recovered") + ".wav")
        }
    }

    func requestPro(_ panel: Panel) {
        if purchases.hasPro { show(panel) }
        else { show(.paywall) }
    }

    func export(_ format: ExportFormat, selected: [Draft]? = nil, segments: [FrameRange]? = nil) {
        guard !working else { return }
        let kind: JobKind = selected != nil ? .batch : (segments != nil ? .split : .single)
        if (kind != .single || format == .wav) && !purchases.hasPro { show(.paywall); return }
        let specs: [ExportSpec]
        if let selected {
            guard (1...10).contains(selected.count) else { return }
            specs = selected.map { ExportSpec(draftID: $0.id, sourceID: $0.sourceID, selection: $0.selection, format: format) }
        } else if let draft {
            specs = (segments ?? [draft.selection]).map {
                ExportSpec(draftID: draft.id, sourceID: draft.sourceID, selection: $0, format: format)
            }
        } else { return }
        performExport {
            let job = try await self.library.enqueue(specs, kind: kind)
            try await self.finish(jobID: job.id, kind: kind)
        }
    }

    func retry(_ job: ExportJob, item: ExportItem? = nil) {
        performExport { try await self.finish(jobID: job.id, kind: job.kind, itemID: item?.id) }
    }

    func rebuild(_ record: ExportRecord) {
        performExport {
            let value = try await self.library.rebuild(record)
            await self.refresh()
            await self.present(value)
        }
    }

    private func performExport(_ body: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        flushDraft()
        audio.stopPlayback()
        working = true
        operation = Task {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AudioTrim export") { [weak self] in
                Task { @MainActor in
                    self?.operation?.cancel()
                    self?.endBackgroundTask()
                }
            }
            defer {
                endBackgroundTask()
                working = false
                drain()
            }
            do { try await body() }
            catch {
                await refresh()
                failure = MediaIO.map(error, fallback: .export)
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func finish(jobID: UUID, kind: JobKind, itemID: UUID? = nil) async throws {
        let outcome = try await library.run(jobID, only: itemID)
        await refresh()
        let pending = state.jobs.first { $0.id == jobID }
        if kind == .single, let item = outcome.records.first {
            await present(item, milestone: outcome.milestone)
        } else if pending != nil || outcome.records.isEmpty {
            show(.tasks)
            if kind == .single { failure = pending?.items.first?.failure ?? .paused }
        } else {
            if let item = outcome.records.last { await present(item, milestone: outcome.milestone) }
            notice = L.f("jobs.completed", outcome.records.count)
        }
    }

    func present(_ record: ExportRecord, milestone: Milestone? = nil) async {
        audio.stopPlayback()
        result = record
        self.milestone = milestone
        resultPeaks = nil
        if let asset = resultSource {
            if asset.id == source?.id, let peaks { resultPeaks = peaks }
            else { resultPeaks = try? await library.wave(asset) }
        }
        show(.result)
    }

    func shareAudio(_ record: ExportRecord) {
        audio.stopPlayback()
        Task {
            guard await library.available(record) else { failure = .access; return }
            activity = Activity(url: await library.exportURL(record), countsForReview: true)
        }
    }

    func shareCard(_ data: Data) {
        shareTemporary(data, name: L.t("card.filename") + ".png", countsForReview: true)
    }

    func recommend() {
        if let url = ShareArtwork.storeURL {
            activity = Activity(url: url, countsForReview: false)
        } else { notice = L.t("card.storePending") }
    }

    func hideMilestone() { milestone = nil }

    func shareSelection() {
        guard let draft, let source else { return }
        do {
            let data = try SelectionCode(source: source, range: draft.selection).encoded()
            shareTemporary(data, name: "AudioTrim.audioclip", countsForReview: false)
        } catch { failure = .badCode }
    }

    private func shareTemporary(_ data: Data, name: String, countsForReview: Bool) {
        Task {
            do {
                let location = cache.appendingPathComponent("Shared", isDirectory: true).appendingPathComponent(name)
                try await Task.detached {
                    try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: location, options: .atomic)
                }.value
                activity = Activity(url: location, countsForReview: countsForReview)
            } catch { failure = MediaIO.map(error, fallback: .storage) }
        }
    }

    func copyCode() {
        guard let draft, let source else { return }
        do {
            let value = try SelectionCode(source: source, range: draft.selection).token(prefix: L.t("app.name"))
            UIPasteboard.general.string = L.t("code.instructions") + "\n" + value
            notice = L.t("code.copied")
        } catch { failure = .badCode }
    }

    func importCode(_ text: String) {
        do { acceptCode(try SelectionCode.decode(token: text), preferCurrent: true) }
        catch { failure = .badCode }
    }

    private func acceptCode(_ value: SelectionCode, preferCurrent: Bool) {
        code = value
        if preferCurrent, let source {
            codeSource = value.matches(source) ? source : nil
            if codeSource == nil { failure = .differentSource }
        } else {
            codeSource = state.sources.first { value.matches($0) }
        }
        show(.importSelection)
    }

    func clearCode() { code = nil; codeSource = nil }

    func applyCode() {
        guard let code, let source = codeSource, !working else { return }
        let priorDraft = draft
        working = true
        Task {
            defer { working = false; drain() }
            do {
                let copy = try await library.apply(code, to: source.id)
                await refresh()
                open(copy)
                undo = priorDraft?.sourceID == source.id ? priorDraft?.selection : source.audioFrames
                clearCode()
                panel = nil
            } catch { failure = MediaIO.map(error, fallback: .badCode) }
        }
    }

    func loadStorage() async {
        var sizes: [UUID: Int64] = [:]
        for source in state.sources { sizes[source.id] = await library.sourceBytes(source) }
        sourceSizes = sizes
    }

    func delete(_ record: ExportRecord) {
        audio.stopPlayback()
        Task {
            do { try await library.deleteFile(record); await refresh() }
            catch { failure = MediaIO.map(error, fallback: .data) }
        }
    }

    func delete(_ item: Draft) {
        audio.stopPlayback()
        Task {
            do {
                try await library.deleteDraft(item)
                if draft?.id == item.id { home() }
                await refresh()
                await loadStorage()
            } catch { failure = MediaIO.map(error, fallback: .data) }
        }
    }

    func show(_ target: Panel) {
        if target == panel { return }
        if panel != nil {
            nextPanel = target
            panel = nil
        } else { panel = target }
    }

    func dismissed() {
        if let next = nextPanel {
            nextPanel = nil
            panel = next
        } else {
            if draft == nil { reviewAfterShareNeedsHome = false }
            audio.stopPlayback()
            drain()
        }
    }

    func activityEnded(countsForReview: Bool) {
        if countsForReview {
            reviewAfterShareNeedsHome = true
            reviewEarliest = Date().addingTimeInterval(20)
            Task { try? await library.shared() }
        }
        activity = nil
        drain()
    }

    func failureDismissed() { failure = nil; drain() }

    var canRetryImport: Bool { failedImport != nil }

    func retryImport() {
        guard let item = failedImport else { return }
        failure = nil
        receive(item.url, kind: item.kind, displayName: item.displayName)
    }

    func foreground() { Task { await purchases.foreground(); drain() } }

    func considerReview() async -> Bool {
        guard !simulated, idleHome, !reviewAfterShareNeedsHome, Date() >= reviewEarliest else { return false }
        await purchases.checkExpiry()
        guard !purchases.expiry, idleHome else { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        guard (try? await library.claimReview(at: Date(), version: version)) == true else { return false }
        return idleHome
    }

    func stopForInterruption() {
        audio.sessionInterrupted(true)
        if audio.recording { stopRecording() }
    }

    private func makeFixture(_ url: URL, seconds: Double = 48.2) async throws {
        try await Task.detached { try MediaFixture.make(url, seconds: seconds) }.value
    }
}

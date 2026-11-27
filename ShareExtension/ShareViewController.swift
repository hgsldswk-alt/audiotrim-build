import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = L.t("share.importing")
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.textAlignment = .center
        status.numberOfLines = 0
        done.setTitle(L.t("common.ok"), for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isHidden = true
        progress.hidesWhenStopped = true
        progress.startAnimating()
        let stack = UIStackView(arrangedSubviews: [progress, status, done])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task {
            defer { progress.stopAnimating(); done.isHidden = false }
            do {
                try await Self.stage(providers)
                status.text = L.t("share.imported")
            } catch {
                status.text = L.t("share.importFailed")
            }
            UIAccessibility.post(notification: .layoutChanged, argument: status)
        }
    }

    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    private nonisolated static func stage(_ providers: [NSItemProvider]) async throws {
        guard !providers.isEmpty, let inbox = ShareInbox.directory else { throw CocoaError(.fileReadUnknown) }
        let id = UUID().uuidString
        let folder = inbox.appendingPathComponent("." + id, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        for (index, provider) in providers.enumerated() {
            let slot = folder.appendingPathComponent(String(format: "%010d", index), isDirectory: true)
            try files.createDirectory(at: slot, withIntermediateDirectories: true)
            try await save(provider, into: slot)
        }
        try files.moveItem(at: folder, to: inbox.appendingPathComponent(id, isDirectory: true))
    }

    private nonisolated static func save(_ provider: NSItemProvider, into slot: URL) async throws {
        let audioType = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: .audio) }
        if let audioType {
            do {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    _ = provider.loadFileRepresentation(forTypeIdentifier: audioType.identifier) { url, error in
                        done.resume(with: Result {
                            guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                            try copy(url, into: slot, suggestedName: provider.suggestedName, type: audioType)
                        })
                    }
                }
                return
            } catch {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { throw error }
            }
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                done.resume(with: Result {
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, url.isFileURL,
                          let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else {
                        throw error ?? CocoaError(.fileReadUnsupportedScheme)
                    }
                    try copy(url, into: slot, suggestedName: provider.suggestedName, type: type)
                })
            }
        }
    }

    private nonisolated static func copy(_ url: URL, into slot: URL, suggestedName: String?, type: UTType) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            guard (try? readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            let names = [suggestedName, readable.lastPathComponent].compactMap { $0 }
            let name = names.map { ($0 as NSString).lastPathComponent }
                .first { !$0.isEmpty && !$0.hasPrefix(".") } ?? "Audio"
            let suffix = readable.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "" : readable.pathExtension
            let ext = (name as NSString).pathExtension
            let hasAudioExtension = UTType(filenameExtension: ext)?.conforms(to: .audio) == true
            let target = slot.appendingPathComponent(name)
            let file = hasAudioExtension || suffix.isEmpty ? target : target.appendingPathExtension(suffix)
            copied = (try? FileManager.default.copyItem(at: readable, to: file)) != nil
        }
        guard copied else {
            if let error { throw error }
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

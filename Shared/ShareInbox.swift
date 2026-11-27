import Foundation

enum ShareInbox {
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ShareAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("AudioInbox", isDirectory: true)
    }

    static func pending() -> [(folder: URL, files: [URL])] {
        guard let directory else { return [] }
        return children(of: directory).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil else { return nil }
            let files = children(of: folder).compactMap { children(of: $0).first }
            guard !files.isEmpty else { return nil }
            return (folder, files)
        }
    }

    private static func children(of directory: URL) -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
        return (files ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

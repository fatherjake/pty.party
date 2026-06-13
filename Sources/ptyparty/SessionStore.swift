import Foundation

/// The on-disk catalog of saved canvases under Application Support/ptyparty/sessions/.
/// Each session is a folder named by a UUID, holding a session.json (the canvas
/// snapshot, including its display name) and an images/ subfolder.
enum SessionStore {
    /// A single saved session. The folder name is the stable identity; the
    /// name is a human label stored inside session.json.
    struct Info: Equatable {
        let id: String
        var name: String
        var modifiedAt: Date

        var folderURL: URL { sessionsDirURL.appendingPathComponent(id, isDirectory: true) }
        var sessionFileURL: URL { folderURL.appendingPathComponent("session.json") }
        var imagesDirURL: URL { folderURL.appendingPathComponent("images", isDirectory: true) }
        var notesDirURL: URL { folderURL.appendingPathComponent("notes", isDirectory: true) }
    }

    static let supportDirURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty", isDirectory: true)
    }()

    static let sessionsDirURL = supportDirURL.appendingPathComponent("sessions", isDirectory: true)

    private static let lastSessionKey = "LastSessionID"

    /// The id of the session opened last time, so the picker can preselect it.
    static var lastOpenedID: String? {
        get { UserDefaults.standard.string(forKey: lastSessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSessionKey) }
    }

    /// Every saved session, most recently modified first.
    static func list() -> [Info] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let dirs = (try? fm.contentsOfDirectory(
            at: sessionsDirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var infos: [Info] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let id = dir.lastPathComponent
            let sessionFile = dir.appendingPathComponent("session.json")

            var name = id
            if let data = try? Data(contentsOf: sessionFile),
               let state = try? JSONDecoder().decode(SessionState.self, from: data),
               let stored = state.name, !stored.isEmpty {
                name = stored
            }
            let modified = (try? sessionFile.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate)
                ?? (try? dir.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate)
                ?? Date.distantPast

            infos.append(Info(id: id, name: name, modifiedAt: modified))
        }
        return infos.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Creates a new empty session folder and returns its info.
    @discardableResult
    static func create(name: String) -> Info {
        let info = Info(id: UUID().uuidString, name: name, modifiedAt: Date())
        let fm = FileManager.default
        try? fm.createDirectory(at: info.imagesDirURL, withIntermediateDirectories: true)
        writeEmptyState(named: name, to: info.sessionFileURL)
        return info
    }

    /// Renames a session by rewriting the name stored in its session.json.
    static func rename(_ info: Info, to newName: String) {
        guard let data = try? Data(contentsOf: info.sessionFileURL),
              var state = try? JSONDecoder().decode(SessionState.self, from: data)
        else {
            writeEmptyState(named: newName, to: info.sessionFileURL)
            return
        }
        state.name = newName
        if let encoded = try? JSONEncoder().encode(state) {
            try? encoded.write(to: info.sessionFileURL)
        }
    }

    static func delete(_ info: Info) {
        try? FileManager.default.removeItem(at: info.folderURL)
        if lastOpenedID == info.id { lastOpenedID = nil }
    }

    /// Moves a pre-multi-session session.json (and its images/) into a fresh
    /// session folder, so existing users keep their canvas on upgrade. A no-op
    /// once any session folder exists.
    static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let legacySession = supportDirURL.appendingPathComponent("session.json")
        guard fm.fileExists(atPath: legacySession.path) else { return }

        // If sessions already exist, the legacy file is stale leftovers.
        guard list().isEmpty else {
            try? fm.removeItem(at: legacySession)
            return
        }

        let info = Info(id: UUID().uuidString, name: "My Canvas", modifiedAt: Date())
        try? fm.createDirectory(at: info.folderURL, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacySession, to: info.sessionFileURL)

        let legacyImages = supportDirURL.appendingPathComponent("images", isDirectory: true)
        if fm.fileExists(atPath: legacyImages.path) {
            try? fm.moveItem(at: legacyImages, to: info.imagesDirURL)
        }
        rename(info, to: info.name)  // stamp the name into the migrated file
    }

    private static func writeEmptyState(named name: String, to url: URL) {
        let empty = SessionState(
            name: name,
            workingDirectory: nil,
            magnification: 1,
            scrollX: 0, scrollY: 0,
            tiles: [],
            imageConnections: [],
            terminalConnections: []
        )
        if let data = try? JSONEncoder().encode(empty) {
            try? data.write(to: url)
        }
    }
}

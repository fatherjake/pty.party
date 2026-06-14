import AppKit

/// Watches the activity directory that Claude Code hooks write into, and reports
/// each terminal's current state. A hook command inside a pty.party terminal
/// writes one of `working` / `asking` / `idle` to a file named after that
/// terminal's `PTYPARTY_TERMINAL_ID`; this maps those files back to tiles so the
/// border reflects the real lifecycle (working → needs you → done) instead of
/// scraping the screen.
final class ActivityWatcher {
    static let directoryURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty/activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let onActivity: (_ terminalID: String, _ state: String) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(onActivity: @escaping (_ terminalID: String, _ state: String) -> Void) {
        self.onActivity = onActivity
    }

    func start() {
        drain()  // pick up the latest state written while the app wasn't watching
        let fd = open(Self.directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }

    /// Reads every state file and reports it. The files hold current state, so
    /// they're left in place (not consumed like the inbox); re-reading all of
    /// them on each change is cheap for the handful of terminals on a canvas.
    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directoryURL, includingPropertiesForKeys: nil
        )) ?? []
        for url in files {
            // Hooks stage writes under a dotted name and rename in, so anything
            // starting with "." is still in flight.
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let state = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !state.isEmpty else { continue }
            onActivity(name, state)
        }
    }
}

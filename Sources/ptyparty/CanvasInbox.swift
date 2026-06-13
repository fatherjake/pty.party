import AppKit

/// Watches an inbox directory that external tools (the MCP server) drop
/// image files into, and feeds each one onto the canvas.
final class CanvasInbox {
    static let directoryURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A drop from the MCP server: an image or a note plus, when the call came
    /// from a Claude session inside a pty.party terminal, that terminal's ID.
    struct Manifest: Decodable {
        struct Note: Decodable {
            let title: String?
            let body: String
        }
        let image: String?       // base64-encoded image data
        let note: Note?          // a sticky note to drop on the canvas
        let terminalId: String?  // PTYPARTY_TERMINAL_ID of the calling terminal
    }

    private let onImage: (NSImage, _ terminalID: String?) -> Void
    private let onNote: (_ title: String, _ body: String, _ terminalID: String?) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(
        onImage: @escaping (NSImage, _ terminalID: String?) -> Void,
        onNote: @escaping (_ title: String, _ body: String, _ terminalID: String?) -> Void
    ) {
        self.onImage = onImage
        self.onNote = onNote
    }

    func start() {
        drain()  // pick up anything dropped while the app wasn't running
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

    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directoryURL, includingPropertiesForKeys: nil
        )) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Writers stage uploads under a dotted name and rename when done,
            // so anything starting with "." is still in flight.
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            if url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                    if let note = manifest.note {
                        onNote(note.title ?? "", note.body, manifest.terminalId)
                    } else if let base64 = manifest.image,
                              let imageData = Data(base64Encoded: base64),
                              let image = NSImage(data: imageData) {
                        onImage(image, manifest.terminalId)
                    }
                }
            } else if let image = NSImage(contentsOf: url) {
                // A bare image file, e.g. dropped in by hand.
                onImage(image, nil)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

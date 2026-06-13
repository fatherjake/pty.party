import AppKit

/// Filesystem RPC for the MCP server: it drops `<id>.json` into requests/,
/// we answer with responses/<id>.json. Used for queries that need live app
/// state, like a connected terminal's current output.
final class RequestBroker {
    static let requestsDirURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty/requests", isDirectory: true)
    }()

    static let responsesDirURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ptyparty/responses", isDirectory: true)
    }()

    private let handler: ([String: Any]) -> [String: Any]
    private var source: DispatchSourceFileSystemObject?

    init(handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    func start() {
        let fileManager = FileManager.default
        for dir in [Self.requestsDirURL, Self.responsesDirURL] {
            try? fileManager.removeItem(at: dir)  // clear stale traffic
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fd = open(Self.requestsDirURL.path, O_EVTONLY)
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
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: Self.requestsDirURL, includingPropertiesForKeys: nil
        )) ?? []
        for url in files {
            guard !url.lastPathComponent.hasPrefix("."), url.pathExtension == "json" else { continue }
            defer { try? fileManager.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let response = try? JSONSerialization.data(withJSONObject: handler(request))
            else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let staging = Self.responsesDirURL.appendingPathComponent(".staging-\(name)")
            let final = Self.responsesDirURL.appendingPathComponent("\(name).json")
            try? response.write(to: staging)
            try? fileManager.moveItem(at: staging, to: final)
        }
    }
}

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
    private var socketFD: Int32 = -1
    private let socketQueue = DispatchQueue(label: "ptyparty.rpc.socket")

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
        if socketFD >= 0 { close(socketFD) }
    }

    /// Opens a Unix-domain socket that serves the same `handler` as the file
    /// RPC. Remote tiles reverse-forward this socket so a remote MCP server can
    /// reach the canvas. One request per connection: a single newline-terminated
    /// JSON object in, one JSON line out.
    func startSocket(at url: URL) {
        let path = url.path
        try? FileManager.default.removeItem(at: url)  // clear a stale socket
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { close(fd); return }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, maxLen)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        socketFD = fd

        socketQueue.async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self?.serveConnection(client)
            }
        }
    }

    private func serveConnection(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Read up to the first newline (the framed request).
        readLoop: while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break readLoop }
        }
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        // The handler touches canvas/UI state, so run it on the main queue.
        let response: [String: Any] = DispatchQueue.main.sync { self.handler(request) }
        guard var out = try? JSONSerialization.data(withJSONObject: response) else { return }
        out.append(0x0A)
        out.withUnsafeBytes { _ = write(client, $0.baseAddress, out.count) }
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

import Foundation
import Darwin

struct LocalBridgeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Private same-user IPC. The helper forwards requests; only the GUI owns state.
final class LocalBridge {
    static var defaultURL: URL {
        ProfileStore().directoryURL.appendingPathComponent("agent.sock")
    }
    private let url: URL
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "life.mograph.KeydialStudio.agent")
    private let clientSlots = DispatchSemaphore(value: 4)
    private let handle: (String, [String: Any]) throws -> [String: Any]
    init(url: URL = LocalBridge.defaultURL,
         handle: @escaping (String, [String: Any]) throws -> [String: Any]) {
        self.url = url; self.handle = handle
    }

    func start() throws {
        guard listener == -1 else { return }
        let directory = url.deletingLastPathComponent()
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw LocalBridgeError(message: "Unsafe agent socket directory")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        guard chmod(directory.path, 0o700) == 0 else { throw Self.failure("Protect agent directory") }
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw LocalBridgeError(message: "Agent socket path is occupied by another file")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { if probe >= 0 { Darwin.close(probe) } }
            var address = try Self.address(url)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected != 0 else { throw LocalBridgeError(message: "KDCustom is already running") }
            guard errno == ECONNREFUSED || errno == ENOENT else { throw Self.failure("Inspect agent socket") }
            guard unlink(url.path) == 0 || errno == ENOENT else { throw Self.failure("Remove stale agent socket") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("Create agent socket") }
        var address = try Self.address(url)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw Self.failure("Bind agent socket") }
        guard chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd); unlink(url.path); throw Self.failure("Protect agent socket")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listener = fd
        let event = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        event.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard self.clientSlots.wait(timeout: .now()) == .success else { Darwin.close(client); return }
            DispatchQueue.global(qos: .utility).async {
                defer { self.clientSlots.signal() }
                self.serve(client)
            }
        }
        event.setCancelHandler { Darwin.close(fd) }
        source = event; event.resume()
    }

    func stop() {
        guard listener >= 0 else { return }
        source?.cancel(); source = nil; listener = -1
        unlink(url.path)
    }
    deinit { stop() }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        Self.configure(fd)
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        let response: [String: Any]
        do {
            let bytes = try Self.readLine(fd)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["operation", "arguments"],
                  let operation = object["operation"] as? String,
                  let arguments = object["arguments"] as? [String: Any] else {
                throw LocalBridgeError(message: "Invalid app bridge request")
            }
            response = ["result": try handle(operation, arguments)]
        } catch { response = ["error": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            try? Self.writeLine(fd, data)
        }
    }

    static func request(operation: String, arguments: [String: Any], url: URL = defaultURL) throws -> [String: Any] {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw LocalBridgeError(message: "Open KDCustom before using its MCP tools")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("Create bridge connection") }
        defer { Darwin.close(fd) }
        configure(fd)
        var address = try address(url)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { throw LocalBridgeError(message: "KDCustom is unavailable; open the app and retry") }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw LocalBridgeError(message: "App bridge belongs to another user")
        }
        try writeLine(fd, JSONSerialization.data(withJSONObject: ["operation": operation, "arguments": arguments]))
        guard let response = try JSONSerialization.jsonObject(with: readLine(fd)) as? [String: Any] else {
            throw LocalBridgeError(message: "Invalid app bridge response")
        }
        if let error = response["error"] as? String { throw LocalBridgeError(message: error) }
        guard let result = response["result"] as? [String: Any] else {
            throw LocalBridgeError(message: "Missing app bridge result")
        }
        return result
    }

    private static func configure(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }
    private static func address(_ url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalBridgeError(message: "App bridge path is too long")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        return address
    }
    private static func readLine(_ fd: Int32) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LocalBridgeError(message: "App bridge message deadline exceeded") }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LocalBridgeError(message: "App bridge closed or timed out") }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= MCPTools.maxMessageBytes else { throw LocalBridgeError(message: "App bridge message too large") }
                return data
            }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= MCPTools.maxMessageBytes else { throw LocalBridgeError(message: "App bridge message too large") }
        }
    }
    private static func writeLine(_ fd: Int32, _ data: Data) throws {
        guard data.count <= MCPTools.maxMessageBytes else { throw LocalBridgeError(message: "App bridge message too large") }
        let bytes = data + Data([10])
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, MSG_NOSIGNAL)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Write app bridge") }
                sent += count
            }
        }
    }
    private static func failure(_ action: String) -> LocalBridgeError {
        LocalBridgeError(message: "\(action): \(String(cString: strerror(errno)))")
    }
}

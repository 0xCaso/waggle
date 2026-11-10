import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Knock

/// A minimal unix-socket JSON-RPC 2.0 test server standing in for `knock
/// daemon` while KNOCK-02 (the real daemon) is built in parallel. Accepts one
/// client at a time, loops to accept a new one after the current client
/// disconnects (so reconnect tests can exercise `KnockClient`'s backoff).
final class FakeKnockServer: @unchecked Sendable {
    enum ServerError: Error {
        case socketFailed, bindFailed, listenFailed, pathTooLong
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private var acceptThread: Thread?
    private var stopped = false

    /// Called on a background thread for every complete line received from
    /// the client. `id` is present for a request, nil for a notification.
    /// Return the raw response line (no trailing newline) to write back, or
    /// nil to send nothing back for that line.
    var onRequest: ((_ method: String, _ id: Int?, _ line: Data) -> Data?)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for (i, byte) in pathBytes.enumerated() { base[i] = byte }
            base[pathBytes.count] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw ServerError.listenFailed
        }
        listenFD = fd

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let stoppedNow = stopped
            let fd = listenFD
            lock.unlock()
            if stoppedNow || fd < 0 { break }

            let client = accept(fd, nil, nil)
            if client < 0 { break }
            lock.lock()
            clientFD = client
            lock.unlock()
            readLoop(fd: client)
        }
    }

    private func readLoop(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                // Off the read thread (HAIL-47 test support): a test's
                // `onRequest` can deliberately block one request (a slow
                // `cases.get`) to exercise a real client-side race. Handling
                // each line on its own queued task keeps this loop reading -
                // and other in-flight requests answering - instead of one
                // slow handler stalling every request on the connection, the
                // same out-of-order-response behaviour a real async daemon
                // has (`KnockClient` already matches responses by their own
                // "id", never by arrival order).
                if !line.isEmpty {
                    DispatchQueue.global().async { [weak self] in
                        self?.handle(line: line, fd: fd)
                    }
                }
            }
        }
    }

    private struct LinePeek: Decodable {
        let method: String?
        let id: Int?
    }

    private func handle(line: Data, fd: Int32) {
        guard let peek = try? JSONDecoder().decode(LinePeek.self, from: line),
              let method = peek.method else { return }
        if let response = onRequest?(method, peek.id, line) {
            write(response, to: fd)
        }
    }

    /// Pushes a raw line to the currently connected client (used for
    /// server-initiated event notifications).
    func send(_ data: Data) {
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return }
        write(data, to: fd)
    }

    func pushEvent(_ event: Event) {
        struct Notification: Encodable {
            let jsonrpc = "2.0"
            let method = "event"
            let params: Event
        }
        if let data = try? JSONEncoder().encode(Notification(params: event)) {
            send(data)
        }
    }

    /// Serialized with `lock` (HAIL-47): request lines are now handled
    /// concurrently (see `readLoop`), so two responses can reach `write` at
    /// once - an unguarded `Darwin.write` from two threads at the same time
    /// can interleave their bytes on the wire, corrupting both lines.
    private func write(_ data: Data, to fd: Int32) {
        var payload = data
        payload.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        _ = payload.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }

    /// Forcibly disconnects the current client, so `KnockClient` observes a
    /// closed connection and starts its reconnect loop.
    ///
    /// Waits (up to 10 s) for the accept loop to take the client first. The
    /// client's connect() returns once the kernel queues the connection, so a
    /// test can see `.connected` before accept() stores `clientFD`; on a loaded
    /// runner the disconnect then closed nothing and the test timed out.
    func disconnectClient() {
        let deadline = Date().addingTimeInterval(10)
        var fd: Int32 = -1
        while true {
            lock.lock()
            fd = clientFD
            if fd >= 0 { clientFD = -1 }
            lock.unlock()
            if fd >= 0 || Date() >= deadline { break }
            usleep(5_000)
        }
        if fd >= 0 { close(fd) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let listen = listenFD
        let client = clientFD
        listenFD = -1
        clientFD = -1
        lock.unlock()
        if client >= 0 { close(client) }
        if listen >= 0 { close(listen) }
        unlink(socketPath)
    }
}

func makeTempSocketPath() -> String {
    "/tmp/knock_test_\(UUID().uuidString.prefix(8)).sock"
}

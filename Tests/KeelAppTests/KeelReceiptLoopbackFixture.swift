import Darwin
import Foundation

/// A deliberately small HTTP/1.1 fixture for WebKit tests. It binds only to loopback,
/// supports fixture response headers, has no TLS, and never opens an AppKit window.
final class KeelReceiptLoopbackFixture: @unchecked Sendable {
    struct Response: Sendable {
        let status: String
        let headers: [String: String]
        let body: Data
        let bodyChunkSize: Int
        let bodyChunkDelay: TimeInterval

        init(
            status: String = "200 OK",
            headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"],
            body: String,
            bodyChunkSize: Int = 0,
            bodyChunkDelay: TimeInterval = 0
        ) {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
            self.bodyChunkSize = bodyChunkSize
            self.bodyChunkDelay = bodyChunkDelay
        }

        init(
            status: String = "200 OK",
            headers: [String: String],
            body: Data,
            bodyChunkSize: Int = 0,
            bodyChunkDelay: TimeInterval = 0
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.bodyChunkSize = bodyChunkSize
            self.bodyChunkDelay = bodyChunkDelay
        }
    }

    private let descriptor: Int32
    private let routes: [String: Response]
    private let acceptSource: DispatchSourceRead
    private let worker = DispatchQueue(label: "com.rowesk.Keel.offscreen-loopback")
    let port: UInt16

    init(routes: [String: Response]) throws {
        self.routes = routes

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        self.descriptor = descriptor

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0 else {
            close(descriptor)
            throw POSIXError(.ENFILE)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0, listen(descriptor, SOMAXCONN) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard didReadAddress == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: worker)
        acceptSource.setEventHandler { [weak self] in self?.acceptConnections() }
        acceptSource.resume()
    }

    deinit {
        acceptSource.cancel()
        close(descriptor)
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func acceptConnections() {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }
            worker.async { [weak self] in self?.respond(to: client) }
        }
    }

    private func respond(to client: Int32) {
        defer { close(client) }

        let clientFlags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
        var noSignalPipe: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignalPipe,
            socklen_t(MemoryLayout.size(ofValue: noSignalPipe))
        )
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )

        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0,
              let request = String(bytes: buffer.prefix(Int(count)), encoding: .utf8),
              let firstLine = request.split(separator: "\n", maxSplits: 1).first
        else { return }

        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count >= 2 else { return }
        let requestTarget = String(requestParts[1])
        let routePath = URLComponents(string: "http://loopback\(requestTarget)")?.path ?? requestTarget
        let response = routes[routePath] ?? Response(status: "404 Not Found", body: "not found")

        var headerLines = ["HTTP/1.1 \(response.status)", "Content-Length: \(response.body.count)", "Connection: close"]
        headerLines += response.headers.map { "\($0.key): \($0.value)" }
        send(Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8), to: client)
        guard response.bodyChunkSize > 0 else {
            send(response.body, to: client)
            return
        }

        var offset = 0
        while offset < response.body.count {
            let end = min(offset + response.bodyChunkSize, response.body.count)
            send(response.body.subdata(in: offset ..< end), to: client)
            offset = end
            if offset < response.body.count, response.bodyChunkDelay > 0 {
                Thread.sleep(forTimeInterval: response.bodyChunkDelay)
            }
        }
    }

    private func send(_ payload: Data, to client: Int32) {
        payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let written = Darwin.send(client, baseAddress.advanced(by: sent), bytes.count - sent, 0)
                guard written > 0 else { return }
                sent += written
            }
        }
    }
}

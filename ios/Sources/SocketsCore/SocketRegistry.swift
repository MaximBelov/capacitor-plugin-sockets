import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The transport of a socket, fixed when it is created.
public enum SocketTransport: String {
    case tcp
    case udp
}

/// The error codes of the TypeScript API (`SocketErrorCode`).
public enum SocketErrorCode {
    public static let closedByPeer = "CLOSED_BY_PEER"
    public static let timedOut = "TIMED_OUT"
    public static let refused = "REFUSED"
    public static let unreachable = "UNREACHABLE"
    public static let notConnected = "NOT_CONNECTED"
    public static let invalidSocket = "INVALID_SOCKET"
    public static let invalidArgument = "INVALID_ARGUMENT"
    public static let io = "IO"
}

public struct SocketError: Error, Equatable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    /// Maps an errno onto the codes of the API.
    public static func posix(_ number: Int32, _ what: String) -> SocketError {
        let text = "\(what): \(String(cString: strerror(number)))"
        switch number {
        case ECONNREFUSED:
            return SocketError(SocketErrorCode.refused, text)
        case ETIMEDOUT:
            return SocketError(SocketErrorCode.timedOut, text)
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL:
            return SocketError(SocketErrorCode.unreachable, text)
        case EPIPE, ECONNRESET, ECONNABORTED:
            return SocketError(SocketErrorCode.closedByPeer, text)
        case ENOTCONN:
            return SocketError(SocketErrorCode.notConnected, text)
        case EINVAL:
            return SocketError(SocketErrorCode.invalidArgument, text)
        default:
            return SocketError(SocketErrorCode.io, text)
        }
    }
}

public struct SocketInfo: Equatable {
    public let socketId: Int
    public let transport: SocketTransport
    public let name: String
    public let bufferSize: Int
    public let connected: Bool
    public let localAddress: String?
    public let localPort: Int?
    public let peerAddress: String?
    public let peerPort: Int?

    public init(socketId: Int, transport: SocketTransport, name: String, bufferSize: Int, connected: Bool,
                localAddress: String?, localPort: Int?, peerAddress: String?, peerPort: Int?) {
        self.socketId = socketId
        self.transport = transport
        self.name = name
        self.bufferSize = bufferSize
        self.connected = connected
        self.localAddress = localAddress
        self.localPort = localPort
        self.peerAddress = peerAddress
        self.peerPort = peerPort
    }
}

/// Every socket of the plugin, by id. Plain BSD sockets on GCD, the way CocoaAsyncSocket drives them: each socket has a
/// serial queue of its own for its calls and its reads, so its sends keep their order and a slow peer holds up no other
/// socket. Foundation and Darwin only, so `swift test` runs it on a Mac.
public final class SocketRegistry {
    public static let defaultTcpBufferSize = 32768
    public static let defaultUdpBufferSize = 65535
    public static let maxBufferSize = 1 << 20
    public static let defaultConnectTimeoutMs = 5000
    /// How long a send waits for room in the socket's send buffer.
    static let sendTimeoutMs: Int32 = 10000

    /// Bytes arrived: socket id, transport, bytes, sender address, sender port. Called on the socket's queue.
    public var onReceive: ((Int, SocketTransport, Data, String, Int) -> Void)?
    /// A socket failed outside a call: socket id, transport, code, message. Called on the socket's queue.
    public var onReceiveError: ((Int, SocketTransport, String, String) -> Void)?

    private let lock = NSLock()
    private var sockets: [Int: Entry] = [:]
    private var nextId = 1

    public init() {}

    deinit {
        closeAll()
    }

    public func create(transport: SocketTransport, bufferSize: Int?, name: String?) throws -> Int {
        let size = bufferSize ?? (transport == .tcp ? Self.defaultTcpBufferSize : Self.defaultUdpBufferSize)
        guard size > 0, size <= Self.maxBufferSize else {
            throw SocketError(SocketErrorCode.invalidArgument, "bufferSize must be 1...\(Self.maxBufferSize)")
        }
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let entry: Entry
        switch transport {
        case .tcp:
            entry = TcpEntry(id: id, bufferSize: size, name: name ?? "", registry: self)
        case .udp:
            entry = try UdpEntry(id: id, bufferSize: size, name: name ?? "", registry: self)
        }
        lock.lock()
        sockets[id] = entry
        lock.unlock()
        return id
    }

    public func connect(socketId: Int, address: String, port: Int, timeoutMs: Int,
                        completion: @escaping (Result<Void, SocketError>) -> Void) {
        do {
            let entry = try tcp(socketId)
            entry.queue.async {
                completion(Result { try entry.connect(address: address, port: port, timeoutMs: timeoutMs) }.mapError(Self.socketError))
            }
        } catch {
            completion(.failure(Self.socketError(error)))
        }
    }

    public func disconnect(socketId: Int) throws {
        let entry = try tcp(socketId)
        entry.queue.sync { entry.dropConnection(report: nil) }
    }

    public func bind(socketId: Int, address: String?, port: Int) throws {
        let entry = try udp(socketId)
        try entry.queue.sync { try entry.bind(address: address, port: port) }
    }

    public func setBroadcast(socketId: Int, enabled: Bool) throws {
        let entry = try udp(socketId)
        try entry.queue.sync { try entry.setBroadcast(enabled) }
    }

    /// Queues a send behind the earlier ones on that socket.
    public func send(socketId: Int, data: Data, address: String?, port: Int?,
                     completion: @escaping (Result<Int, SocketError>) -> Void) {
        do {
            let entry = try self.entry(socketId)
            entry.queue.async {
                completion(Result {
                    if let tcp = entry as? TcpEntry {
                        return try tcp.send(data)
                    }
                    guard let udp = entry as? UdpEntry else {
                        throw SocketError(SocketErrorCode.invalidSocket, "socket \(socketId) has no transport")
                    }
                    guard let address = address, !address.isEmpty, let port = port else {
                        throw SocketError(SocketErrorCode.invalidArgument, "a UDP send needs an address and a port")
                    }
                    return try udp.send(data, address: address, port: port)
                }.mapError(Self.socketError))
            }
        } catch {
            completion(.failure(Self.socketError(error)))
        }
    }

    public func close(socketId: Int) {
        lock.lock()
        let entry = sockets.removeValue(forKey: socketId)
        lock.unlock()
        entry?.close()
    }

    public func closeAll() {
        lock.lock()
        let all = Array(sockets.values)
        sockets.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
    }

    public func info(socketId: Int) throws -> SocketInfo {
        let entry = try self.entry(socketId)
        return entry.queue.sync { entry.info() }
    }

    public func list() -> [SocketInfo] {
        lock.lock()
        let all = sockets.values.sorted { $0.id < $1.id }
        lock.unlock()
        return all.map { entry in entry.queue.sync { entry.info() } }
    }

    // MARK: - lookup

    private func entry(_ socketId: Int) throws -> Entry {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = sockets[socketId] else {
            throw SocketError(SocketErrorCode.invalidSocket, "no socket has the id \(socketId)")
        }
        return entry
    }

    private func tcp(_ socketId: Int) throws -> TcpEntry {
        guard let entry = try entry(socketId) as? TcpEntry else {
            throw SocketError(SocketErrorCode.invalidArgument, "socket \(socketId) is not a TCP socket")
        }
        return entry
    }

    private func udp(_ socketId: Int) throws -> UdpEntry {
        guard let entry = try entry(socketId) as? UdpEntry else {
            throw SocketError(SocketErrorCode.invalidArgument, "socket \(socketId) is not a UDP socket")
        }
        return entry
    }

    static func socketError(_ error: Error) -> SocketError {
        (error as? SocketError) ?? SocketError(SocketErrorCode.io, "\(error)")
    }

    fileprivate func received(_ id: Int, _ transport: SocketTransport, _ data: Data, _ address: String, _ port: Int) {
        onReceive?(id, transport, data, address, port)
    }

    fileprivate func failed(_ id: Int, _ transport: SocketTransport, _ error: SocketError) {
        onReceiveError?(id, transport, error.code, error.message)
    }
}

// MARK: - sockets

private class Entry {
    let id: Int
    let transport: SocketTransport
    let bufferSize: Int
    let name: String
    let queue: DispatchQueue
    weak var registry: SocketRegistry?

    init(id: Int, transport: SocketTransport, bufferSize: Int, name: String, registry: SocketRegistry) {
        self.id = id
        self.transport = transport
        self.bufferSize = bufferSize
        self.name = name
        self.registry = registry
        queue = DispatchQueue(label: "sockets.\(transport.rawValue).\(id)")
    }

    func info() -> SocketInfo {
        fatalError("subclass")
    }

    func close() {}
}

private final class TcpEntry: Entry {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var closed = false

    init(id: Int, bufferSize: Int, name: String, registry: SocketRegistry) {
        super.init(id: id, transport: .tcp, bufferSize: bufferSize, name: name, registry: registry)
    }

    /// On the queue. Blocks the queue for at most the timeout, so calls made meanwhile wait for the connection.
    func connect(address: String, port: Int, timeoutMs: Int) throws {
        guard (1...65535).contains(port) else { throw SocketError(SocketErrorCode.invalidArgument, "port must be 1...65535") }
        guard timeoutMs > 0 else { throw SocketError(SocketErrorCode.invalidArgument, "timeout must be positive") }
        guard !closed else { throw SocketError(SocketErrorCode.invalidSocket, "socket \(id) is closed") }
        guard fd < 0 else { throw SocketError(SocketErrorCode.invalidArgument, "socket \(id) is already connected") }

        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let addresses = try resolve(address, port: port, type: SOCK_STREAM, family: AF_UNSPEC)
        var lastError = SocketError(SocketErrorCode.unreachable, "no address for \(address)")
        for target in addresses {
            let remaining = Int((Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)) / 1_000_000)
            if remaining <= 0 {
                throw SocketError(SocketErrorCode.timedOut, "connect to \(address):\(port) timed out")
            }
            do {
                let socket = try openConnected(to: target, timeoutMs: remaining, address: address, port: port)
                start(socket)
                return
            } catch let error as SocketError {
                lastError = error
                if error.code == SocketErrorCode.timedOut { throw error }
            }
        }
        throw lastError
    }

    private func openConnected(to target: SocketAddress, timeoutMs: Int, address: String, port: Int) throws -> Int32 {
        let socket = Darwin.socket(target.family, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw SocketError.posix(errno, "socket") }
        do {
            try prepare(socket)
            let result = target.withSockaddr { Darwin.connect(socket, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw SocketError.posix(errno, "connect to \(address):\(port)") }
                var poller = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&poller, 1, Int32(timeoutMs))
                if ready == 0 { throw SocketError(SocketErrorCode.timedOut, "connect to \(address):\(port) timed out") }
                if ready < 0 { throw SocketError.posix(errno, "connect to \(address):\(port)") }
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(socket, SOL_SOCKET, SO_ERROR, &failure, &length)
                if failure != 0 { throw SocketError.posix(failure, "connect to \(address):\(port)") }
            }
            return socket
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    private func start(_ socket: Int32) {
        fd = socket
        let reader = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable(socket) }
        reader.setCancelHandler { Darwin.close(socket) }
        source = reader
        reader.resume()
    }

    private func readAvailable(_ socket: Int32) {
        guard socket == fd else { return }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, bufferSize) }
        if count > 0 {
            let peer = peerName(socket)
            registry?.received(id, .tcp, Data(buffer[0..<count]), peer.address ?? "", peer.port ?? 0)
        } else if count == 0 {
            dropConnection(report: SocketError(SocketErrorCode.closedByPeer, "the peer closed the connection"))
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            dropConnection(report: SocketError.posix(errno, "read"))
        }
    }

    /// On the queue. Closes the connection; reports `report` when the connection ended on its own.
    func dropConnection(report: SocketError?) {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
        if let report = report {
            registry?.failed(id, .tcp, report)
        }
    }

    /// On the queue.
    func send(_ data: Data) throws -> Int {
        guard fd >= 0 else { throw SocketError(SocketErrorCode.notConnected, "socket \(id) is not connected") }
        let socket = fd
        var sent = 0
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            while sent < bytes.count {
                let n = Darwin.write(socket, bytes.baseAddress! + sent, bytes.count - sent)
                if n >= 0 {
                    sent += n
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var poller = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                    if poll(&poller, 1, SocketRegistry.sendTimeoutMs) <= 0 {
                        throw SocketError(SocketErrorCode.timedOut, "the peer took no data for \(SocketRegistry.sendTimeoutMs) ms")
                    }
                    continue
                }
                throw SocketError.posix(errno, "send")
            }
        }
        return sent
    }

    override func info() -> SocketInfo {
        let connected = fd >= 0
        let local: (address: String?, port: Int?) = connected ? socketName(fd) : (nil, nil)
        let peer: (address: String?, port: Int?) = connected ? peerName(fd) : (nil, nil)
        return SocketInfo(socketId: id, transport: .tcp, name: name, bufferSize: bufferSize, connected: connected,
                          localAddress: local.address, localPort: local.port,
                          peerAddress: peer.address, peerPort: peer.port)
    }

    override func close() {
        queue.sync {
            closed = true
            dropConnection(report: nil)
        }
    }
}

private final class UdpEntry: Entry {
    private let fd: Int32
    private let source: DispatchSourceRead
    private var bound = false
    private var closed = false

    init(id: Int, bufferSize: Int, name: String, registry: SocketRegistry) throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw SocketError.posix(errno, "socket") }
        do {
            try prepare(socket)
            var on: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw SocketError.posix(errno, "SO_REUSEADDR")
            }
        } catch {
            Darwin.close(socket)
            throw error
        }
        fd = socket
        let label = "sockets.udp.\(id)"
        source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: DispatchQueue(label: label + ".read"))
        super.init(id: id, transport: .udp, bufferSize: bufferSize, name: name, registry: registry)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(socket) }
        source.resume()
    }

    /// Drains every datagram waiting on the socket.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bufferSize, 0, $0, &length)
                    }
                }
            }
            if count >= 0 {
                let sender = describe(&from)
                registry?.received(id, .udp, Data(buffer[0..<count]), sender.address ?? "", sender.port ?? 0)
                continue
            }
            let failure = errno
            if failure == EAGAIN || failure == EWOULDBLOCK { return }
            if failure == EINTR || failure == ECONNREFUSED { continue }
            if !queue.sync(execute: { closed }) {
                registry?.failed(id, .udp, SocketError.posix(failure, "receive"))
            }
            return
        }
    }

    /// On the queue.
    func bind(address: String?, port: Int) throws {
        guard (0...65535).contains(port) else { throw SocketError(SocketErrorCode.invalidArgument, "port must be 0...65535") }
        guard !bound else { throw SocketError(SocketErrorCode.invalidArgument, "socket \(id) is already bound") }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(UInt16(port).bigEndian)
        let host = (address?.isEmpty == false) ? address! : "0.0.0.0"
        guard inet_pton(AF_INET, host, &local.sin_addr) == 1 else {
            throw SocketError(SocketErrorCode.invalidArgument, "\(host) is not an IPv4 address")
        }
        let result = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw SocketError.posix(errno, "bind \(host):\(port)") }
        bound = true
    }

    /// On the queue.
    func setBroadcast(_ enabled: Bool) throws {
        var value: Int32 = enabled ? 1 : 0
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.posix(errno, "SO_BROADCAST")
        }
    }

    /// On the queue.
    func send(_ data: Data, address: String, port: Int) throws -> Int {
        guard (1...65535).contains(port) else { throw SocketError(SocketErrorCode.invalidArgument, "port must be 1...65535") }
        guard let target = try resolve(address, port: port, type: SOCK_DGRAM, family: AF_INET).first else {
            throw SocketError(SocketErrorCode.unreachable, "no IPv4 address for \(address)")
        }
        while true {
            let n = data.withUnsafeBytes { bytes in
                target.withSockaddr { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, $1) }
            }
            if n >= 0 {
                bound = true
                return n
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, SocketRegistry.sendTimeoutMs) <= 0 {
                    throw SocketError(SocketErrorCode.timedOut, "the socket took no data for \(SocketRegistry.sendTimeoutMs) ms")
                }
                continue
            }
            throw SocketError.posix(errno, "send to \(address):\(port)")
        }
    }

    override func info() -> SocketInfo {
        let local = socketName(fd)
        let isBound = (local.port ?? 0) != 0
        return SocketInfo(socketId: id, transport: .udp, name: name, bufferSize: bufferSize, connected: isBound,
                          localAddress: isBound ? local.address : nil, localPort: isBound ? local.port : nil,
                          peerAddress: nil, peerPort: nil)
    }

    override func close() {
        queue.sync { closed = true }
        source.cancel()
    }
}

// MARK: - helpers

private struct SocketAddress {
    let family: Int32
    let storage: sockaddr_storage
    let length: socklen_t

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = storage
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// Resolves a host name or an address literal. IPv4 first, the way the readers this was written for answer.
private func resolve(_ host: String, port: Int, type: Int32, family: Int32) throws -> [SocketAddress] {
    var hints = addrinfo()
    hints.ai_family = family
    hints.ai_socktype = type
    var list: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &list)
    guard status == 0, let first = list else {
        let reason = status == 0 ? "no address" : String(cString: gai_strerror(status))
        throw SocketError(SocketErrorCode.unreachable, "cannot resolve \(host): \(reason)")
    }
    defer { freeaddrinfo(list) }
    var result: [SocketAddress] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
        if let address = info.pointee.ai_addr {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { target in
                target.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(info.pointee.ai_addrlen)))
            }
            result.append(SocketAddress(family: info.pointee.ai_family, storage: storage, length: info.pointee.ai_addrlen))
        }
        cursor = info.pointee.ai_next
    }
    return result.sorted { $0.family == AF_INET && $1.family != AF_INET }
}

/// Non-blocking, and no SIGPIPE when the peer has gone: the error comes back as EPIPE instead of ending the process.
private func prepare(_ socket: Int32) throws {
    var on: Int32 = 1
    guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw SocketError.posix(errno, "SO_NOSIGPIPE")
    }
    let flags = fcntl(socket, F_GETFL, 0)
    guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw SocketError.posix(errno, "O_NONBLOCK")
    }
}

/// An address in the form the API reports: dotted IPv4, an IPv4-mapped IPv6 address unmapped, or IPv6 text.
private func describe(_ storage: inout sockaddr_storage) -> (address: String?, port: Int?) {
    switch Int32(storage.ss_family) {
    case AF_INET:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
                return (String(cString: text), Int(UInt16(bigEndian: pointer.pointee.sin_port)))
            }
        }
    case AF_INET6:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin6_addr
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN))
                var string = String(cString: text)
                if string.hasPrefix("::ffff:"), string.contains(".") {
                    string.removeFirst("::ffff:".count)
                }
                return (string, Int(UInt16(bigEndian: pointer.pointee.sin6_port)))
            }
        }
    default:
        return (nil, nil)
    }
}

private func socketName(_ socket: Int32) -> (address: String?, port: Int?) {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    return result == 0 ? describe(&storage) : (nil, nil)
}

private func peerName(_ socket: Int32) -> (address: String?, port: Int?) {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(socket, $0, &length) }
    }
    return result == 0 ? describe(&storage) : (nil, nil)
}

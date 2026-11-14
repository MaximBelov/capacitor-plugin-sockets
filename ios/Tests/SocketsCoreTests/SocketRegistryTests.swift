import Foundation
import XCTest
@testable import SocketsCore

/// The registry against real sockets on 127.0.0.1: a TCP echo server made here, and UDP peers that are registry sockets
/// themselves. Runs on a Mac with `SOCKETS_CORE_ONLY=1 swift test`, and on an iOS simulator with the plugin tests.
final class SocketRegistryTests: XCTestCase {
    private struct Received: Equatable {
        let socketId: Int
        let transport: SocketTransport
        let data: Data
        let address: String
        let port: Int
    }

    private var registry: SocketRegistry!
    private var received: [Received] = []
    private var failures: [(Int, SocketTransport, String)] = []
    private let lock = NSRecursiveLock()
    private var servers: [EchoServer] = []

    override func setUp() {
        super.setUp()
        registry = SocketRegistry()
        received = []
        failures = []
        registry.onReceive = { [unowned self] id, transport, data, address, port in
            lock.lock()
            received.append(Received(socketId: id, transport: transport, data: data, address: address, port: port))
            lock.unlock()
        }
        registry.onReceiveError = { [unowned self] id, transport, code, _ in
            lock.lock()
            failures.append((id, transport, code))
            lock.unlock()
        }
    }

    override func tearDown() {
        registry.closeAll()
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    // MARK: - helpers

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = condition()
            lock.unlock()
            if done { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func bytes(from id: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return received.filter { $0.socketId == id }.reduce(into: Data()) { $0.append($1.data) }
    }

    private func connect(_ id: Int, port: Int, timeoutMs: Int = 2000) -> Result<Void, SocketError> {
        let done = expectation(description: "connect")
        var outcome: Result<Void, SocketError>!
        registry.connect(socketId: id, address: "127.0.0.1", port: port, timeoutMs: timeoutMs) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    private func send(_ id: Int, _ data: Data, address: String? = nil, port: Int? = nil) -> Result<Int, SocketError> {
        let done = expectation(description: "send")
        var outcome: Result<Int, SocketError>!
        registry.send(socketId: id, data: data, address: address, port: port) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome
    }

    private func echoServer(echo: Bool = true) throws -> EchoServer {
        let server = try EchoServer(echo: echo)
        servers.append(server)
        return server
    }

    // MARK: - TCP

    func testTcpSendsAndReceivesThroughAnEchoServer() throws {
        let server = try echoServer()
        let id = try registry.create(transport: .tcp, bufferSize: nil, name: "reader")
        XCTAssertNoThrow(try connect(id, port: server.port).get())
        XCTAssertEqual(try send(id, Data("[!]\r\n".utf8)).get(), 5)
        XCTAssertTrue(wait { bytes(from: id).count == 5 })
        XCTAssertEqual(bytes(from: id), Data("[!]\r\n".utf8))

        let info = try registry.info(socketId: id)
        XCTAssertTrue(info.connected)
        XCTAssertEqual(info.transport, .tcp)
        XCTAssertEqual(info.name, "reader")
        XCTAssertEqual(info.peerAddress, "127.0.0.1")
        XCTAssertEqual(info.peerPort, server.port)
        XCTAssertEqual(received.first?.address, "127.0.0.1")
    }

    func testTcpKeepsSendsInOrder() throws {
        let server = try echoServer()
        let id = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        XCTAssertNoThrow(try connect(id, port: server.port).get())
        let all = expectation(description: "all sent")
        all.expectedFulfillmentCount = 50
        for i in 0..<50 {
            registry.send(socketId: id, data: Data([UInt8(i)]), address: nil, port: nil) { _ in all.fulfill() }
        }
        wait(for: [all], timeout: 10)
        XCTAssertTrue(wait { bytes(from: id).count == 50 })
        XCTAssertEqual(bytes(from: id), Data((0..<50).map { UInt8($0) }))
    }

    func testAPeerThatClosesIsReportedAndTheSocketCanConnectAgain() throws {
        let server = try echoServer(echo: false)
        let id = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        XCTAssertNoThrow(try connect(id, port: server.port).get())
        XCTAssertTrue(server.waitForClient())
        server.dropClients()

        XCTAssertTrue(wait { failures.contains { $0.0 == id && $0.2 == SocketErrorCode.closedByPeer } })
        XCTAssertFalse(try registry.info(socketId: id).connected)
        if case .failure(let error) = send(id, Data([1])) {
            XCTAssertEqual(error.code, SocketErrorCode.notConnected)
        } else {
            XCTFail("a send on a dropped connection succeeded")
        }

        XCTAssertNoThrow(try connect(id, port: server.port).get())
        XCTAssertTrue(try registry.info(socketId: id).connected)
    }

    func testDisconnectIsNotReportedAsAnError() throws {
        let server = try echoServer()
        let id = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        XCTAssertNoThrow(try connect(id, port: server.port).get())
        try registry.disconnect(socketId: id)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(try registry.info(socketId: id).connected)
    }

    func testAConnectToAClosedPortIsRefused() throws {
        let server = try echoServer()
        let port = server.port
        server.stop()
        let id = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        if case .failure(let error) = connect(id, port: port) {
            XCTAssertEqual(error.code, SocketErrorCode.refused)
        } else {
            XCTFail("connected to a closed port")
        }
    }

    // MARK: - UDP

    func testUdpReceivesADatagramWithItsSender() throws {
        let listener = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: listener, address: "0.0.0.0", port: 0)
        let port = try XCTUnwrap(registry.info(socketId: listener).localPort)
        let peer = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: peer, address: "127.0.0.1", port: 0)
        let peerPort = try XCTUnwrap(registry.info(socketId: peer).localPort)

        XCTAssertEqual(try send(peer, Data("P".utf8), address: "127.0.0.1", port: port).get(), 1)
        XCTAssertTrue(wait { received.contains { $0.socketId == listener } })
        let datagram = try XCTUnwrap(received.first { $0.socketId == listener })
        XCTAssertEqual(datagram, Received(socketId: listener, transport: .udp, data: Data("P".utf8), address: "127.0.0.1", port: peerPort))
    }

    /// The keepalive of a Gallagher HR5 reader: it sends `P` and wants the single byte `p` back, to the port it pinged from.
    func testUdpAnswersAPingFromTheSameSocket() throws {
        let app = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: app, address: nil, port: 0)
        let appPort = try XCTUnwrap(registry.info(socketId: app).localPort)
        let reader = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: reader, address: "127.0.0.1", port: 0)

        _ = try send(reader, Data("P".utf8), address: "127.0.0.1", port: appPort).get()
        XCTAssertTrue(wait { received.contains { $0.socketId == app } })
        let ping = try XCTUnwrap(received.first { $0.socketId == app })
        XCTAssertEqual(try send(app, Data("p".utf8), address: ping.address, port: ping.port).get(), 1)
        XCTAssertTrue(wait { received.contains { $0.socketId == reader } })
        let reply = try XCTUnwrap(received.first { $0.socketId == reader })
        XCTAssertEqual(reply.data, Data("p".utf8))
        XCTAssertEqual(reply.port, appPort)
    }

    func testUdpSendWithoutBindPicksAPortAndStillReceives() throws {
        let echo = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: echo, address: "127.0.0.1", port: 0)
        let echoPort = try XCTUnwrap(registry.info(socketId: echo).localPort)
        let unbound = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        XCTAssertFalse(try registry.info(socketId: unbound).connected)

        _ = try send(unbound, Data("hi".utf8), address: "127.0.0.1", port: echoPort).get()
        XCTAssertTrue(wait { received.contains { $0.socketId == echo } })
        let request = try XCTUnwrap(received.first { $0.socketId == echo })
        _ = try send(echo, request.data, address: request.address, port: request.port).get()
        XCTAssertTrue(wait { received.contains { $0.socketId == unbound } })
        XCTAssertTrue(try registry.info(socketId: unbound).connected)
    }

    func testUdpSendNeedsAnAddress() throws {
        let id = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        if case .failure(let error) = send(id, Data([1])) {
            XCTAssertEqual(error.code, SocketErrorCode.invalidArgument)
        } else {
            XCTFail("a UDP send without an address succeeded")
        }
    }

    func testABroadcastNeedsSetBroadcast() throws {
        let id = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: id, address: nil, port: 0)
        if case .failure(let error) = send(id, Data([1]), address: "255.255.255.255", port: 9) {
            XCTAssertTrue([SocketErrorCode.io, SocketErrorCode.unreachable].contains(error.code), error.message)
        }
        try registry.setBroadcast(socketId: id, enabled: true)
        try registry.setBroadcast(socketId: id, enabled: false)
    }

    // MARK: - registry

    func testTheWrongTransportIsAnInvalidArgument() throws {
        let tcp = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        let udp = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        XCTAssertThrowsError(try registry.bind(socketId: tcp, address: nil, port: 0)) {
            XCTAssertEqual(($0 as? SocketError)?.code, SocketErrorCode.invalidArgument)
        }
        if case .failure(let error) = connect(udp, port: 1) {
            XCTAssertEqual(error.code, SocketErrorCode.invalidArgument)
        } else {
            XCTFail("a UDP socket connected")
        }
        XCTAssertThrowsError(try registry.create(transport: .udp, bufferSize: 0, name: nil))
    }

    func testCloseForgetsTheIdAndCloseAllEmptiesTheRegistry() throws {
        let a = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        let b = try registry.create(transport: .udp, bufferSize: nil, name: nil)
        try registry.bind(socketId: b, address: nil, port: 0)
        XCTAssertEqual(registry.list().map(\.socketId), [a, b])
        registry.close(socketId: a)
        registry.close(socketId: a)
        XCTAssertThrowsError(try registry.info(socketId: a)) {
            XCTAssertEqual(($0 as? SocketError)?.code, SocketErrorCode.invalidSocket)
        }
        registry.closeAll()
        XCTAssertTrue(registry.list().isEmpty)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(failures.isEmpty)
    }

    func testIdsAreNeverReused() throws {
        let a = try registry.create(transport: .tcp, bufferSize: nil, name: nil)
        registry.close(socketId: a)
        XCTAssertGreaterThan(try registry.create(transport: .tcp, bufferSize: nil, name: nil), a)
    }

    func testErrnoMapsOntoTheCodesOfTheApi() {
        XCTAssertEqual(SocketError.posix(ECONNREFUSED, "x").code, SocketErrorCode.refused)
        XCTAssertEqual(SocketError.posix(ENETUNREACH, "x").code, SocketErrorCode.unreachable)
        XCTAssertEqual(SocketError.posix(EPIPE, "x").code, SocketErrorCode.closedByPeer)
        XCTAssertEqual(SocketError.posix(ETIMEDOUT, "x").code, SocketErrorCode.timedOut)
        XCTAssertEqual(SocketError.posix(EIO, "x").code, SocketErrorCode.io)
    }
}

/// A TCP server on 127.0.0.1 with blocking BSD sockets: it echoes what it reads, or only accepts.
final class EchoServer {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var stopped = false
    private let echo: Bool

    init(echo: Bool) throws {
        self.echo = echo
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw SocketError.posix(errno, "listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread { [self] in acceptLoop() }.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            clients.append(client)
            lock.unlock()
            if echo {
                Thread { Self.echoLoop(client) }.start()
            }
        }
    }

    private static func echoLoop(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, 1024) }
            if n <= 0 { return }
            _ = buffer.withUnsafeBytes { write(client, $0.baseAddress, n) }
        }
    }

    func waitForClient() -> Bool {
        for _ in 0..<500 {
            lock.lock()
            let any = !clients.isEmpty
            lock.unlock()
            if any { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    func dropClients() {
        lock.lock()
        let all = clients
        clients = []
        lock.unlock()
        all.forEach { close($0) }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if already { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        dropClients()
    }
}

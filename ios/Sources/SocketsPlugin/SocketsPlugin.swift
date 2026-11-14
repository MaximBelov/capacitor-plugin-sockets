import Foundation
import Capacitor
#if canImport(SocketsCore)
import SocketsCore
#endif

/// TCP client and UDP sockets for Capacitor. The sockets themselves are in `SocketRegistry`; this class reads the calls,
/// turns base64 into bytes and back, and closes every socket when the page that opened them goes away.
@objc(SocketsPlugin)
public class SocketsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SocketsPlugin"
    public let jsName = "Sockets"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "create", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bind", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBroadcast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "closeAll", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSockets", returnType: CAPPluginReturnPromise)
    ]

    let registry = SocketRegistry()

    override public func load() {
        registry.onReceive = { [weak self] socketId, transport, data, address, port in
            self?.notifyListeners("receive", data: [
                "socketId": socketId,
                "protocol": transport.rawValue,
                "data": data.base64EncodedString(),
                "remoteAddress": address,
                "remotePort": port
            ])
        }
        registry.onReceiveError = { [weak self] socketId, transport, code, message in
            self?.notifyListeners("receiveError", data: [
                "socketId": socketId,
                "protocol": transport.rawValue,
                "code": code,
                "message": message
            ])
        }
    }

    deinit {
        registry.closeAll()
    }

    /// The bridge calls this with no call (nil, whatever the header says) when the web view starts a navigation: a
    /// reload, a live update, a new page. A socket of the old page would stay open with nobody able to see it, so every
    /// socket is closed. A `removeAllListeners()` from JavaScript arrives with a call and closes nothing.
    override public func removeAllListeners(_ call: CAPPluginCall) {
        let fromBridgeReset = unsafeBitCast(call, to: UnsafeRawPointer?.self) == nil
        super.removeAllListeners(call)
        if fromBridgeReset {
            registry.closeAll()
        }
    }

    @objc func create(_ call: CAPPluginCall) {
        guarded(call) {
            guard let name = call.getString("protocol"), let transport = SocketTransport(rawValue: name) else {
                throw SocketError(SocketErrorCode.invalidArgument, "protocol must be tcp or udp")
            }
            let id = try registry.create(transport: transport, bufferSize: call.getInt("bufferSize"), name: call.getString("name"))
            call.resolve(["socketId": id])
        }
    }

    @objc func connect(_ call: CAPPluginCall) {
        guarded(call) {
            let id = try socketId(call)
            guard let address = call.getString("address") else { throw SocketError(SocketErrorCode.invalidArgument, "address is required") }
            guard let port = call.getInt("port") else { throw SocketError(SocketErrorCode.invalidArgument, "port is required") }
            let timeout = call.getInt("timeout") ?? SocketRegistry.defaultConnectTimeoutMs
            registry.connect(socketId: id, address: address, port: port, timeoutMs: timeout) { [weak self] result in
                switch result {
                case .success:
                    call.resolve()
                case .failure(let error):
                    self?.reject(call, error)
                }
            }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        guarded(call) {
            try registry.disconnect(socketId: try socketId(call))
            call.resolve()
        }
    }

    @objc func bind(_ call: CAPPluginCall) {
        guarded(call) {
            guard let port = call.getInt("port") else { throw SocketError(SocketErrorCode.invalidArgument, "port is required") }
            try registry.bind(socketId: try socketId(call), address: call.getString("address"), port: port)
            call.resolve()
        }
    }

    @objc func send(_ call: CAPPluginCall) {
        guarded(call) {
            let id = try socketId(call)
            guard let encoded = call.getString("data") else { throw SocketError(SocketErrorCode.invalidArgument, "data is required") }
            guard let data = Data(base64Encoded: encoded) else { throw SocketError(SocketErrorCode.invalidArgument, "data is not base64") }
            registry.send(socketId: id, data: data, address: call.getString("address"), port: call.getInt("port")) { [weak self] result in
                switch result {
                case .success(let bytes):
                    call.resolve(["bytesSent": bytes])
                case .failure(let error):
                    self?.reject(call, error)
                }
            }
        }
    }

    @objc func setBroadcast(_ call: CAPPluginCall) {
        guarded(call) {
            guard let enabled = call.getBool("enabled") else { throw SocketError(SocketErrorCode.invalidArgument, "enabled is required") }
            try registry.setBroadcast(socketId: try socketId(call), enabled: enabled)
            call.resolve()
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        guarded(call) {
            registry.close(socketId: try socketId(call))
            call.resolve()
        }
    }

    @objc func closeAll(_ call: CAPPluginCall) {
        registry.closeAll()
        call.resolve()
    }

    @objc func getInfo(_ call: CAPPluginCall) {
        guarded(call) {
            call.resolve(SocketsPlugin.toJS(try registry.info(socketId: try socketId(call))))
        }
    }

    @objc func getSockets(_ call: CAPPluginCall) {
        call.resolve(["sockets": registry.list().map(SocketsPlugin.toJS)])
    }

    // MARK: - helpers

    private func socketId(_ call: CAPPluginCall) throws -> Int {
        guard let id = call.getInt("socketId") else { throw SocketError(SocketErrorCode.invalidArgument, "socketId is required") }
        return id
    }

    private func guarded(_ call: CAPPluginCall, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            reject(call, error)
        }
    }

    private func reject(_ call: CAPPluginCall, _ error: Error) {
        let failure = (error as? SocketError) ?? SocketError(SocketErrorCode.io, "\(error)")
        call.reject(failure.message, failure.code)
    }

    static func toJS(_ info: SocketInfo) -> [String: Any] {
        var result: [String: Any] = [
            "socketId": info.socketId,
            "protocol": info.transport.rawValue,
            "name": info.name,
            "bufferSize": info.bufferSize,
            "connected": info.connected
        ]
        if let value = info.localAddress { result["localAddress"] = value }
        if let value = info.localPort { result["localPort"] = value }
        if let value = info.peerAddress { result["peerAddress"] = value }
        if let value = info.peerPort { result["peerPort"] = value }
        return result
    }
}

import XCTest
import Capacitor
import SocketsCore
@testable import SocketsPlugin

/// The JavaScript reaches the plugin by `jsName` and each method by its name: a rename on either side fails only at run
/// time on a phone, so both are pinned here.
final class SocketsPluginTests: XCTestCase {
    func testIsRegisteredUnderTheNameTheJavaScriptUses() {
        let plugin = SocketsPlugin()
        XCTAssertEqual(plugin.jsName, "Sockets")
        XCTAssertEqual(plugin.identifier, "SocketsPlugin")
    }

    func testRegistersExactlyTheMethodsOfTheApi() {
        let names = SocketsPlugin().pluginMethods.map(\.name).sorted()
        XCTAssertEqual(names, ["bind", "close", "closeAll", "connect", "create", "disconnect", "getInfo", "getSockets", "send", "setBroadcast"])
        for name in names {
            XCTAssertTrue(SocketsPlugin().responds(to: NSSelectorFromString("\(name):")), "no @objc \(name)(_:)")
        }
    }

    /// The bridge resets with a nil call when a page starts loading; that, and only that, closes every socket.
    func testABridgeResetClosesEverySocketAndAJavaScriptCallDoesNot() throws {
        let plugin = SocketsPlugin()
        _ = try plugin.registry.create(transport: .udp, bufferSize: nil, name: nil)
        _ = try plugin.registry.create(transport: .tcp, bufferSize: nil, name: nil)

        let fromJavaScript = CAPPluginCall(callbackId: "1", methodName: "removeAllListeners", options: [:], success: { _, _ in }, error: { _ in })
        plugin.removeAllListeners(try XCTUnwrap(fromJavaScript))
        XCTAssertEqual(plugin.registry.list().count, 2)

        plugin.perform(#selector(CAPPlugin.removeAllListeners(_:)), with: nil)
        XCTAssertTrue(plugin.registry.list().isEmpty)
    }

    func testSocketInfoReachesJavaScriptUnderTheNamesOfTheApi() {
        let info = SocketInfo(socketId: 3, transport: .tcp, name: "n", bufferSize: 10, connected: true,
                              localAddress: "10.0.0.2", localPort: 5, peerAddress: "10.0.0.1", peerPort: 15001)
        let js = SocketsPlugin.toJS(info)
        XCTAssertEqual(js["socketId"] as? Int, 3)
        XCTAssertEqual(js["protocol"] as? String, "tcp")
        XCTAssertEqual(js["peerPort"] as? Int, 15001)
        XCTAssertEqual(js["connected"] as? Bool, true)
    }
}

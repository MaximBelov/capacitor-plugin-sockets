package io.github.maximbelov.sockets

import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import java.util.Base64
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

@CapacitorPlugin(name = "Sockets")
class SocketsPlugin : Plugin() {
    private lateinit var registry: SocketRegistry

    /** Connects block until they finish, so they run here and never on the bridge's thread. */
    private val connects: ExecutorService = Executors.newCachedThreadPool { r -> Thread(r, "sockets-connect").apply { isDaemon = true } }

    override fun load() {
        registry = SocketRegistry(
            object : SocketEvents {
                override fun onReceive(socketId: Int, protocol: String, data: ByteArray, remoteAddress: String, remotePort: Int) {
                    notifyListeners(
                        "receive",
                        JSObject()
                            .put("socketId", socketId)
                            .put("protocol", protocol)
                            .put("data", Base64.getEncoder().encodeToString(data))
                            .put("remoteAddress", remoteAddress)
                            .put("remotePort", remotePort),
                    )
                }

                override fun onReceiveError(socketId: Int, protocol: String, code: String, message: String) {
                    notifyListeners(
                        "receiveError",
                        JSObject().put("socketId", socketId).put("protocol", protocol).put("code", code).put("message", message),
                    )
                }
            },
            ProcessNetworkBinder(context),
        )
    }

    /**
     * The bridge calls this, and only this overload, when the web view starts loading a page. A socket of the old page
     * would stay open with nobody able to see it, so every socket is closed. A `removeAllListeners()` from JavaScript
     * goes to the overload that takes a call and closes nothing.
     */
    override fun removeAllListeners() {
        super.removeAllListeners()
        if (::registry.isInitialized) registry.closeAll()
    }

    override fun handleOnDestroy() {
        if (::registry.isInitialized) registry.closeAll()
        connects.shutdownNow()
        super.handleOnDestroy()
    }

    @PluginMethod
    fun create(call: PluginCall) = guarded(call) {
        val protocol = call.getString("protocol") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "protocol is required")
        val id = registry.create(protocol, call.getInt("bufferSize"), call.getString("name"))
        call.resolve(JSObject().put("socketId", id))
    }

    @PluginMethod
    fun connect(call: PluginCall) = guarded(call) {
        val id = socketId(call)
        val address = call.getString("address") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "address is required")
        val port = call.getInt("port") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "port is required")
        val timeout = call.getInt("timeout") ?: SocketRegistry.DEFAULT_CONNECT_TIMEOUT_MS
        connects.execute {
            guarded(call) {
                registry.connect(id, address, port, timeout)
                call.resolve()
            }
        }
    }

    @PluginMethod
    fun disconnect(call: PluginCall) = guarded(call) {
        registry.disconnect(socketId(call))
        call.resolve()
    }

    @PluginMethod
    fun bind(call: PluginCall) = guarded(call) {
        val port = call.getInt("port") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "port is required")
        registry.bind(socketId(call), call.getString("address"), port)
        call.resolve()
    }

    @PluginMethod
    fun send(call: PluginCall) = guarded(call) {
        val id = socketId(call)
        val encoded = call.getString("data") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "data is required")
        val data = try {
            Base64.getDecoder().decode(encoded)
        } catch (e: IllegalArgumentException) {
            throw SocketError(ErrorCode.INVALID_ARGUMENT, "data is not base64")
        }
        registry.send(id, data, call.getString("address"), call.getInt("port")) { result ->
            result.fold(
                { bytes -> call.resolve(JSObject().put("bytesSent", bytes)) },
                { error -> reject(call, error) },
            )
        }
    }

    @PluginMethod
    fun setBroadcast(call: PluginCall) = guarded(call) {
        val enabled = call.getBoolean("enabled") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "enabled is required")
        registry.setBroadcast(socketId(call), enabled)
        call.resolve()
    }

    @PluginMethod
    fun close(call: PluginCall) = guarded(call) {
        registry.close(socketId(call))
        call.resolve()
    }

    @PluginMethod
    fun closeAll(call: PluginCall) = guarded(call) {
        registry.closeAll()
        call.resolve()
    }

    @PluginMethod
    fun getInfo(call: PluginCall) = guarded(call) {
        call.resolve(toJs(registry.info(socketId(call))))
    }

    @PluginMethod
    fun getSockets(call: PluginCall) = guarded(call) {
        val list = JSArray()
        registry.list().forEach { list.put(toJs(it)) }
        call.resolve(JSObject().put("sockets", list))
    }

    private fun socketId(call: PluginCall): Int =
        call.getInt("socketId") ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "socketId is required")

    private inline fun guarded(call: PluginCall, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            reject(call, e)
        }
    }

    private fun reject(call: PluginCall, e: Throwable) {
        val error = SocketRegistry.translate(e)
        call.reject(error.message, error.code)
    }

    private fun toJs(info: SocketInfo): JSObject {
        val js = JSObject()
            .put("socketId", info.socketId)
            .put("protocol", info.protocol)
            .put("name", info.name)
            .put("bufferSize", info.bufferSize)
            .put("connected", info.connected)
        info.localAddress?.let { js.put("localAddress", it) }
        info.localPort?.let { js.put("localPort", it) }
        info.peerAddress?.let { js.put("peerAddress", it) }
        info.peerPort?.let { js.put("peerPort", it) }
        return js
    }
}

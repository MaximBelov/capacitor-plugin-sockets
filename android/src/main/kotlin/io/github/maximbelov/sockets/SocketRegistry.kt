package io.github.maximbelov.sockets

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** The error codes of the TypeScript API (`SocketErrorCode`). */
object ErrorCode {
    const val CLOSED_BY_PEER = "CLOSED_BY_PEER"
    const val TIMED_OUT = "TIMED_OUT"
    const val REFUSED = "REFUSED"
    const val UNREACHABLE = "UNREACHABLE"
    const val NOT_CONNECTED = "NOT_CONNECTED"
    const val INVALID_SOCKET = "INVALID_SOCKET"
    const val INVALID_ARGUMENT = "INVALID_ARGUMENT"
    const val IO = "IO"
}

class SocketError(val code: String, message: String) : Exception(message)

/**
 * Binds a socket to the network the process is bound to. On Android `ConnectivityManager.bindProcessToNetwork` reaches
 * only the sockets made after it, so a socket that outlives a network change stays on the network it was made on and
 * every send fails with "Network is unreachable". Kept out of [SocketRegistry] so that the registry runs on a plain JVM.
 */
interface NetworkBinder {
    /** Binds a TCP socket before it connects. Returns a description of the network, or null when nothing is bound. */
    fun bind(socket: Socket): String?

    /**
     * Binds a UDP socket to the process network if that network is not [current]. Returns the network now bound (or
     * [current] when nothing changed).
     */
    fun bind(socket: DatagramSocket, current: String?): String?

    object None : NetworkBinder {
        override fun bind(socket: Socket): String? = null

        override fun bind(socket: DatagramSocket, current: String?): String? = current
    }
}

interface SocketEvents {
    fun onReceive(socketId: Int, protocol: String, data: ByteArray, remoteAddress: String, remotePort: Int)

    fun onReceiveError(socketId: Int, protocol: String, code: String, message: String)
}

data class SocketInfo(
    val socketId: Int,
    val protocol: String,
    val name: String,
    val bufferSize: Int,
    val connected: Boolean,
    val localAddress: String?,
    val localPort: Int?,
    val peerAddress: String?,
    val peerPort: Int?,
)

/**
 * Every socket of the plugin, by id. Blocking java.net sockets: each one reads on a thread of its own and writes on a
 * single thread of its own, so sends on a socket keep their order and a slow peer cannot hold up another socket.
 */
class SocketRegistry(
    private val events: SocketEvents,
    private val binder: NetworkBinder = NetworkBinder.None,
) {
    private val nextId = AtomicInteger(1)
    private val sockets = ConcurrentHashMap<Int, Entry>()

    fun create(protocol: String, bufferSize: Int?, name: String?): Int {
        val size = bufferSize ?: if (protocol == TCP) DEFAULT_TCP_BUFFER else DEFAULT_UDP_BUFFER
        if (size <= 0 || size > MAX_BUFFER) throw SocketError(ErrorCode.INVALID_ARGUMENT, "bufferSize must be 1..$MAX_BUFFER")
        val id = nextId.getAndIncrement()
        sockets[id] = when (protocol) {
            TCP -> TcpEntry(id, size, name ?: "")
            UDP -> UdpEntry(id, size, name ?: "")
            else -> throw SocketError(ErrorCode.INVALID_ARGUMENT, "protocol must be tcp or udp")
        }
        return id
    }

    /** Blocks until connected; call it off the main thread. */
    fun connect(socketId: Int, address: String, port: Int, timeoutMs: Int) = tcp(socketId).connect(address, port, timeoutMs)

    fun disconnect(socketId: Int) = tcp(socketId).disconnect()

    fun bind(socketId: Int, address: String?, port: Int) = udp(socketId).bind(address, port)

    fun setBroadcast(socketId: Int, enabled: Boolean) = udp(socketId).setBroadcast(enabled)

    /** Queues a send behind the earlier ones on that socket; [done] gets the byte count or the failure. */
    fun send(socketId: Int, data: ByteArray, address: String?, port: Int?, done: (Result<Int>) -> Unit) {
        val entry = entry(socketId)
        entry.writer.execute {
            done(
                runCatching {
                    when (entry) {
                        is TcpEntry -> entry.send(data)
                        is UdpEntry -> {
                            if (address.isNullOrEmpty() || port == null) {
                                throw SocketError(ErrorCode.INVALID_ARGUMENT, "a UDP send needs an address and a port")
                            }
                            entry.send(data, address, port)
                        }
                        else -> throw SocketError(ErrorCode.INVALID_SOCKET, "socket $socketId has no transport")
                    }
                }.recoverCatching { throw translate(it) },
            )
        }
    }

    fun close(socketId: Int) {
        sockets.remove(socketId)?.close()
    }

    fun closeAll() {
        val ids = sockets.keys.toList()
        ids.forEach { close(it) }
    }

    fun info(socketId: Int): SocketInfo = entry(socketId).info()

    fun list(): List<SocketInfo> = sockets.values.sortedBy { it.id }.map { it.info() }

    private fun entry(socketId: Int): Entry =
        sockets[socketId] ?: throw SocketError(ErrorCode.INVALID_SOCKET, "no socket has the id $socketId")

    private fun tcp(socketId: Int): TcpEntry =
        entry(socketId) as? TcpEntry ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "socket $socketId is not a TCP socket")

    private fun udp(socketId: Int): UdpEntry =
        entry(socketId) as? UdpEntry ?: throw SocketError(ErrorCode.INVALID_ARGUMENT, "socket $socketId is not a UDP socket")

    private abstract inner class Entry(val id: Int, val protocol: String, val bufferSize: Int, val name: String) {
        val writer: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "sockets-$protocol-$id-write").apply { isDaemon = true } }

        @Volatile
        var closed = false

        abstract fun info(): SocketInfo

        open fun close() {
            closed = true
            writer.shutdownNow()
        }
    }

    private inner class TcpEntry(id: Int, bufferSize: Int, name: String) : Entry(id, TCP, bufferSize, name) {
        @Volatile
        private var socket: Socket? = null

        @Volatile
        private var output: OutputStream? = null

        fun connect(address: String, port: Int, timeoutMs: Int) {
            if (port !in 1..65535) throw SocketError(ErrorCode.INVALID_ARGUMENT, "port must be 1..65535")
            if (timeoutMs <= 0) throw SocketError(ErrorCode.INVALID_ARGUMENT, "timeout must be positive")
            if (socket?.isConnected == true && socket?.isClosed == false) {
                throw SocketError(ErrorCode.INVALID_ARGUMENT, "socket $id is already connected")
            }
            val next = Socket()
            try {
                binder.bind(next)
                next.connect(InetSocketAddress(address, port), timeoutMs)
            } catch (e: Throwable) {
                runCatching { next.close() }
                throw translate(e)
            }
            if (closed) {
                next.close()
                throw SocketError(ErrorCode.INVALID_SOCKET, "socket $id was closed while it connected")
            }
            socket = next
            output = next.getOutputStream()
            val input = next.getInputStream()
            Thread({ read(next, input) }, "sockets-tcp-$id-read").apply { isDaemon = true }.start()
        }

        private fun read(current: Socket, input: InputStream) {
            val buffer = ByteArray(bufferSize)
            try {
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) {
                        if (socket === current) {
                            dropConnection(current)
                            events.onReceiveError(id, TCP, ErrorCode.CLOSED_BY_PEER, "the peer closed the connection")
                        }
                        return
                    }
                    if (count > 0) {
                        val peer = current.inetAddress?.hostAddress ?: ""
                        events.onReceive(id, TCP, buffer.copyOf(count), peer, current.port)
                    }
                }
            } catch (e: IOException) {
                // A close or disconnect of ours ends the read with an exception: that is not an error to report.
                if (socket === current && !current.isClosed) {
                    dropConnection(current)
                    val error = translate(e)
                    events.onReceiveError(id, TCP, error.code, error.message ?: "")
                }
            }
        }

        private fun dropConnection(current: Socket) {
            if (socket === current) {
                socket = null
                output = null
            }
            runCatching { current.close() }
        }

        fun send(data: ByteArray): Int {
            val out = output ?: throw SocketError(ErrorCode.NOT_CONNECTED, "socket $id is not connected")
            out.write(data)
            out.flush()
            return data.size
        }

        fun disconnect() {
            socket?.let { dropConnection(it) }
        }

        override fun close() {
            super.close()
            disconnect()
        }

        override fun info(): SocketInfo {
            val s = socket
            val connected = s != null && s.isConnected && !s.isClosed
            return SocketInfo(
                id,
                TCP,
                name,
                bufferSize,
                connected,
                if (connected) s?.localAddress?.hostAddress else null,
                if (connected) s?.localPort else null,
                if (connected) s?.inetAddress?.hostAddress else null,
                if (connected) s?.port else null,
            )
        }
    }

    private inner class UdpEntry(id: Int, bufferSize: Int, name: String) : Entry(id, UDP, bufferSize, name) {
        private val socket = DatagramSocket(null as java.net.SocketAddress?).apply { reuseAddress = true }

        @Volatile
        private var reading = false

        @Volatile
        private var network: String? = null

        @Synchronized
        fun bind(address: String?, port: Int) {
            if (port !in 0..65535) throw SocketError(ErrorCode.INVALID_ARGUMENT, "port must be 0..65535")
            if (socket.isBound) throw SocketError(ErrorCode.INVALID_ARGUMENT, "socket $id is already bound")
            try {
                val local = if (address.isNullOrEmpty()) InetAddress.getByName("0.0.0.0") else InetAddress.getByName(address)
                socket.bind(InetSocketAddress(local, port))
                network = binder.bind(socket, network)
            } catch (e: Throwable) {
                throw translate(e)
            }
            startReading()
        }

        @Synchronized
        private fun startReading() {
            if (reading) return
            reading = true
            Thread({ read() }, "sockets-udp-$id-read").apply { isDaemon = true }.start()
        }

        private fun read() {
            val buffer = ByteArray(bufferSize)
            val packet = DatagramPacket(buffer, buffer.size)
            while (!closed) {
                try {
                    packet.setData(buffer, 0, buffer.size)
                    socket.receive(packet)
                    val from = packet.address?.hostAddress ?: ""
                    events.onReceive(id, UDP, buffer.copyOf(packet.length), from, packet.port)
                } catch (e: IOException) {
                    if (closed || socket.isClosed) return
                    // An ICMP port unreachable for an earlier send surfaces on the next receive; the socket is still usable.
                    if (e is PortUnreachableException) continue
                    val error = translate(e)
                    events.onReceiveError(id, UDP, error.code, error.message ?: "")
                    return
                }
            }
        }

        fun setBroadcast(enabled: Boolean) {
            try {
                socket.broadcast = enabled
            } catch (e: SocketException) {
                throw translate(e)
            }
        }

        fun send(data: ByteArray, address: String, port: Int): Int {
            if (port !in 1..65535) throw SocketError(ErrorCode.INVALID_ARGUMENT, "port must be 1..65535")
            if (!socket.isBound) {
                bind(null, 0)
            }
            // The process may have been bound to another network since the socket was made: send on that one.
            network = binder.bind(socket, network)
            socket.send(DatagramPacket(data, data.size, InetAddress.getByName(address), port))
            return data.size
        }

        override fun close() {
            super.close()
            socket.close()
        }

        override fun info(): SocketInfo {
            val bound = socket.isBound && !socket.isClosed
            return SocketInfo(
                id,
                UDP,
                name,
                bufferSize,
                bound,
                if (bound) socket.localAddress?.hostAddress else null,
                if (bound) socket.localPort else null,
                null,
                null,
            )
        }
    }

    companion object {
        const val TCP = "tcp"
        const val UDP = "udp"
        const val DEFAULT_TCP_BUFFER = 32768
        const val DEFAULT_UDP_BUFFER = 65535
        const val MAX_BUFFER = 1 shl 20
        const val DEFAULT_CONNECT_TIMEOUT_MS = 5000

        /** Maps what java.net throws onto the codes of the API. */
        fun translate(e: Throwable): SocketError {
            if (e is SocketError) return e
            val message = e.message ?: e.javaClass.simpleName
            val lower = message.lowercase()
            val code = when {
                e is SocketTimeoutException -> ErrorCode.TIMED_OUT
                e is UnknownHostException -> ErrorCode.UNREACHABLE
                e is NoRouteToHostException -> ErrorCode.UNREACHABLE
                e is ConnectException && ("refused" in lower) -> ErrorCode.REFUSED
                "network is unreachable" in lower || "enetunreach" in lower || "ehostunreach" in lower -> ErrorCode.UNREACHABLE
                "connection reset" in lower || "broken pipe" in lower || "epipe" in lower -> ErrorCode.CLOSED_BY_PEER
                e is IllegalArgumentException -> ErrorCode.INVALID_ARGUMENT
                else -> ErrorCode.IO
            }
            return SocketError(code, message)
        }
    }
}

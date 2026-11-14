package io.github.maximbelov.sockets

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

// The registry against real sockets on 127.0.0.1: a TCP echo server and UDP peers made in the test.
class SocketRegistryTest {
    private data class Received(val socketId: Int, val protocol: String, val data: ByteArray, val address: String, val port: Int)

    private data class Failed(val socketId: Int, val protocol: String, val code: String)

    private val received = LinkedBlockingQueue<Received>()
    private val failed = LinkedBlockingQueue<Failed>()
    private val events = object : SocketEvents {
        override fun onReceive(socketId: Int, protocol: String, data: ByteArray, remoteAddress: String, remotePort: Int) {
            received += Received(socketId, protocol, data, remoteAddress, remotePort)
        }

        override fun onReceiveError(socketId: Int, protocol: String, code: String, message: String) {
            failed += Failed(socketId, protocol, code)
        }
    }

    private val binds = mutableListOf<String>()
    private var processNetwork: String? = null
    private val binder = object : NetworkBinder {
        override fun bind(socket: Socket): String? {
            synchronized(binds) { binds += "tcp:${processNetwork}:${socket.isConnected}" }
            return processNetwork
        }

        override fun bind(socket: DatagramSocket, current: String?): String? {
            val network = processNetwork ?: return current
            if (network == current) return current
            synchronized(binds) { binds += "udp:$network" }
            return network
        }
    }

    private val registry = SocketRegistry(events, binder)
    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() {
        registry.closeAll()
        closeables.forEach { runCatching { it.close() } }
    }

    private fun echoServer(): ServerSocket {
        val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        closeables += server
        Thread {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: return@Thread
                closeables += client
                Thread {
                    val buffer = ByteArray(1024)
                    runCatching {
                        while (true) {
                            val n = client.getInputStream().read(buffer)
                            if (n < 0) break
                            client.getOutputStream().write(buffer, 0, n)
                        }
                    }
                }.start()
            }
        }.start()
        return server
    }

    private fun send(id: Int, data: ByteArray, address: String? = null, port: Int? = null): Result<Int> {
        val future = CompletableFuture<Result<Int>>()
        registry.send(id, data, address, port) { future.complete(it) }
        return future.get(5, TimeUnit.SECONDS)
    }

    private fun next(): Received = received.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("nothing received")

    private fun readTcp(id: Int, length: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        while (out.size() < length) {
            val r = next()
            assertEquals(id, r.socketId)
            out.write(r.data)
        }
        return out.toByteArray()
    }

    @Test
    fun tcpSendsAndReceivesThroughAnEchoServer() {
        val server = echoServer()
        val id = registry.create("tcp", null, "reader")
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        assertEquals(5, send(id, "[!]\r\n".toByteArray()).getOrThrow())
        assertArrayEquals("[!]\r\n".toByteArray(), readTcp(id, 5))

        val info = registry.info(id)
        assertTrue(info.connected)
        assertEquals("tcp", info.protocol)
        assertEquals("reader", info.name)
        assertEquals(server.localPort, info.peerPort)
        assertEquals("127.0.0.1", info.peerAddress)
    }

    @Test
    fun tcpBindsToTheProcessNetworkBeforeItConnects() {
        val server = echoServer()
        processNetwork = "wifi-1"
        val id = registry.create("tcp", null, null)
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        assertEquals(listOf("tcp:wifi-1:false"), binds)
    }

    @Test
    fun tcpKeepsSendsInOrder() {
        val server = echoServer()
        val id = registry.create("tcp", null, null)
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        val futures = (0 until 50).map { i ->
            CompletableFuture<Result<Int>>().also { f -> registry.send(id, byteArrayOf(i.toByte()), null, null) { f.complete(it) } }
        }
        futures.forEach { it.get(5, TimeUnit.SECONDS).getOrThrow() }
        assertArrayEquals(ByteArray(50) { it.toByte() }, readTcp(id, 50))
    }

    @Test
    fun aPeerThatClosesIsReportedAndTheSocketCanConnectAgain() {
        val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        closeables += server
        val id = registry.create("tcp", null, null)
        val accepted = CompletableFuture.supplyAsync { server.accept() }
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        accepted.get(5, TimeUnit.SECONDS).close()

        val failure = failed.poll(5, TimeUnit.SECONDS)
        assertEquals(Failed(id, "tcp", ErrorCode.CLOSED_BY_PEER), failure)
        assertFalse(registry.info(id).connected)
        assertEquals(ErrorCode.NOT_CONNECTED, (send(id, byteArrayOf(1)).exceptionOrNull() as SocketError).code)

        val again = CompletableFuture.supplyAsync { server.accept() }
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        assertNotNull(again.get(5, TimeUnit.SECONDS))
        assertTrue(registry.info(id).connected)
    }

    @Test
    fun disconnectIsNotReportedAsAnError() {
        val server = echoServer()
        val id = registry.create("tcp", null, null)
        registry.connect(id, "127.0.0.1", server.localPort, 2000)
        registry.disconnect(id)
        assertNull(failed.poll(500, TimeUnit.MILLISECONDS))
        assertFalse(registry.info(id).connected)
    }

    @Test
    fun aConnectToAClosedPortIsRefused() {
        val port = ServerSocket(0, 50, InetAddress.getLoopbackAddress()).use { it.localPort }
        val id = registry.create("tcp", null, null)
        try {
            registry.connect(id, "127.0.0.1", port, 2000)
            fail("connected to a closed port")
        } catch (e: SocketError) {
            assertEquals(ErrorCode.REFUSED, e.code)
        }
    }

    @Test
    fun udpReceivesADatagramWithItsSender() {
        val id = registry.create("udp", null, null)
        registry.bind(id, "0.0.0.0", 0)
        val port = registry.info(id).localPort!!
        val peer = DatagramSocket(0, InetAddress.getLoopbackAddress()).also { closeables += it }
        peer.send(DatagramPacket(byteArrayOf('P'.code.toByte()), 1, InetAddress.getLoopbackAddress(), port))

        val r = next()
        assertEquals(id, r.socketId)
        assertEquals("udp", r.protocol)
        assertArrayEquals(byteArrayOf('P'.code.toByte()), r.data)
        assertEquals("127.0.0.1", r.address)
        assertEquals(peer.localPort, r.port)
    }

    // The keepalive of a Gallagher HR5 reader: it sends `P` and wants the single byte `p` back, from the port it pings.
    @Test
    fun udpAnswersAPingFromTheSameSocket() {
        val id = registry.create("udp", null, null)
        registry.bind(id, null, 0)
        val port = registry.info(id).localPort!!
        val reader = DatagramSocket(0, InetAddress.getLoopbackAddress()).also { closeables += it }
        reader.soTimeout = 5000
        reader.send(DatagramPacket(byteArrayOf('P'.code.toByte()), 1, InetAddress.getLoopbackAddress(), port))
        val ping = next()

        assertEquals(1, send(id, byteArrayOf('p'.code.toByte()), ping.address, ping.port).getOrThrow())
        val reply = DatagramPacket(ByteArray(16), 16)
        reader.receive(reply)
        assertEquals(1, reply.length)
        assertEquals('p'.code.toByte(), reply.data[0])
        assertEquals(port, reply.port)
    }

    @Test
    fun udpRebindsBeforeASendWhenTheProcessNetworkChanged() {
        processNetwork = "mobile"
        val id = registry.create("udp", null, null)
        registry.bind(id, null, 0)
        val sink = DatagramSocket(0, InetAddress.getLoopbackAddress()).also { closeables += it }
        send(id, byteArrayOf(1), "127.0.0.1", sink.localPort).getOrThrow()
        processNetwork = "device-wifi"
        send(id, byteArrayOf(2), "127.0.0.1", sink.localPort).getOrThrow()
        send(id, byteArrayOf(3), "127.0.0.1", sink.localPort).getOrThrow()
        assertEquals(listOf("udp:mobile", "udp:device-wifi"), binds)
    }

    @Test
    fun udpSendWithoutBindPicksAPortAndStillReceives() {
        val id = registry.create("udp", null, null)
        val echo = DatagramSocket(0, InetAddress.getLoopbackAddress()).also { closeables += it }
        echo.soTimeout = 5000
        send(id, "hi".toByteArray(), "127.0.0.1", echo.localPort).getOrThrow()
        val packet = DatagramPacket(ByteArray(16), 16)
        echo.receive(packet)
        echo.send(DatagramPacket(packet.data, packet.length, packet.socketAddress as InetSocketAddress))
        assertArrayEquals("hi".toByteArray(), next().data)
        assertTrue(registry.info(id).connected)
    }

    @Test
    fun udpSendNeedsAnAddress() {
        val id = registry.create("udp", null, null)
        assertEquals(ErrorCode.INVALID_ARGUMENT, (send(id, byteArrayOf(1)).exceptionOrNull() as SocketError).code)
    }

    @Test
    fun setBroadcastReachesTheSocket() {
        val id = registry.create("udp", null, null)
        registry.setBroadcast(id, true)
        registry.setBroadcast(id, false)
    }

    @Test
    fun theWrongTransportIsAnInvalidArgument() {
        val tcp = registry.create("tcp", null, null)
        val udp = registry.create("udp", null, null)
        assertCode(ErrorCode.INVALID_ARGUMENT) { registry.bind(tcp, null, 0) }
        assertCode(ErrorCode.INVALID_ARGUMENT) { registry.connect(udp, "127.0.0.1", 1, 1000) }
        assertCode(ErrorCode.INVALID_ARGUMENT) { registry.create("sctp", null, null) }
        assertCode(ErrorCode.INVALID_ARGUMENT) { registry.create("udp", 0, null) }
    }

    @Test
    fun closeForgetsTheIdAndCloseAllEmptiesTheRegistry() {
        val a = registry.create("tcp", null, null)
        val b = registry.create("udp", null, null)
        registry.bind(b, null, 0)
        assertEquals(listOf(a, b), registry.list().map { it.socketId })
        registry.close(a)
        registry.close(a)
        assertCode(ErrorCode.INVALID_SOCKET) { registry.info(a) }
        registry.closeAll()
        assertTrue(registry.list().isEmpty())
        assertCode(ErrorCode.INVALID_SOCKET) { send(b, byteArrayOf(1), "127.0.0.1", 9) }
        assertNull(failed.poll(300, TimeUnit.MILLISECONDS))
    }

    @Test
    fun idsAreNeverReused() {
        val a = registry.create("tcp", null, null)
        registry.close(a)
        assertTrue(registry.create("tcp", null, null) > a)
    }

    @Test
    fun translateMapsTheOperatingSystemErrors() {
        assertEquals(ErrorCode.TIMED_OUT, SocketRegistry.translate(java.net.SocketTimeoutException("x")).code)
        assertEquals(ErrorCode.UNREACHABLE, SocketRegistry.translate(java.net.SocketException("Network is unreachable")).code)
        assertEquals(ErrorCode.REFUSED, SocketRegistry.translate(java.net.ConnectException("Connection refused")).code)
        assertEquals(ErrorCode.CLOSED_BY_PEER, SocketRegistry.translate(java.net.SocketException("Connection reset")).code)
        assertEquals(ErrorCode.IO, SocketRegistry.translate(java.io.IOException("other")).code)
    }

    private fun assertCode(code: String, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (e: SocketError) {
            assertEquals(code, e.code)
        }
    }
}

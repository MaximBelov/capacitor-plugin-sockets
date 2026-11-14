package io.github.maximbelov.sockets

import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import java.net.DatagramSocket
import java.net.Socket

/**
 * Binds sockets to `ConnectivityManager.getBoundNetworkForProcess()`. An app that joins a device's own Wi-Fi (one with
 * no internet behind it) binds the process to that network so that traffic goes there and not to mobile data; that
 * binding reaches only sockets made after it, so the plugin binds each socket itself.
 */
class ProcessNetworkBinder(context: Context) : NetworkBinder {
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)

    override fun bind(socket: Socket): String? {
        val network = connectivity?.boundNetworkForProcess ?: return null
        return try {
            network.bindSocket(socket)
            network.toString()
        } catch (e: Exception) {
            Log.w(TAG, "could not bind a TCP socket to the process network $network: $e")
            null
        }
    }

    override fun bind(socket: DatagramSocket, current: String?): String? {
        val network = connectivity?.boundNetworkForProcess ?: return current
        if (network.toString() == current) return current
        return try {
            network.bindSocket(socket)
            network.toString()
        } catch (e: Exception) {
            Log.w(TAG, "could not bind a UDP socket to the process network $network: $e")
            current
        }
    }

    private companion object {
        const val TAG = "Sockets"
    }
}

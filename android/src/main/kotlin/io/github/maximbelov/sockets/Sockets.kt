package io.github.maximbelov.sockets

import com.getcapacitor.Logger

class Sockets {

    fun echo(value: String): String {
        Logger.info("Echo", value)

        return value
    }
}

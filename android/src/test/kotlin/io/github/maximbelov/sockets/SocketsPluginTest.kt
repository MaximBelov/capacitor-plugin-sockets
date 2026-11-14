package io.github.maximbelov.sockets

import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

// The JavaScript reaches the plugin by the name in @CapacitorPlugin and each method by its name; a rename on either side
// fails only at run time on a phone, so both are pinned here.
class SocketsPluginTest {
    @Test
    fun isRegisteredUnderTheNameTheJavaScriptUses() {
        val annotation = SocketsPlugin::class.java.getAnnotation(CapacitorPlugin::class.java)
        assertNotNull(annotation)
        assertEquals("Sockets", annotation!!.name)
    }

    @Test
    fun exposesExactlyTheMethodsOfTheApi() {
        val methods = SocketsPlugin::class.java.declaredMethods
            .filter { it.isAnnotationPresent(PluginMethod::class.java) }
            .map { it.name }
            .sorted()
        assertEquals(
            listOf("bind", "close", "closeAll", "connect", "create", "disconnect", "getInfo", "getSockets", "send", "setBroadcast"),
            methods,
        )
        methods.forEach { SocketsPlugin::class.java.getMethod(it, PluginCall::class.java) }
    }

    // The bridge calls removeAllListeners() with no argument when a page starts loading; that is where every socket is closed.
    @Test
    fun overridesTheResetHookOfTheBridge() {
        val method = SocketsPlugin::class.java.getMethod("removeAllListeners")
        assertEquals(SocketsPlugin::class.java, method.declaringClass)
        assertEquals(Plugin::class.java, SocketsPlugin::class.java.getMethod("removeAllListeners", PluginCall::class.java).declaringClass)
    }
}

package com.sobhan.term.my_terminal

import android.net.LocalSocket
import android.net.LocalSocketAddress
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sobhan.term/x11_display"
    private var touchSocket: LocalSocket? = null
    private var touchOut: OutputStream? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "connectTouch" -> {
                    thread {
                        try {
                            touchSocket = LocalSocket()
                            touchSocket?.connect(LocalSocketAddress("/tmp/sobhan_x11_touch", LocalSocketAddress.Namespace.FILESYSTEM))
                            touchOut = touchSocket?.outputStream
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SOCKET_ERR", e.message, null) }
                        }
                    }
                }
                "sendTouchEvent" -> {
                    val type = call.argument<Int>("type") ?: 0
                    val x = call.argument<Int>("x") ?: 0
                    val y = call.argument<Int>("y") ?: 0
                    sendPacket(type, x, y)
                    result.success(true)
                }
                "sendKeyEvent" -> {
                    val type = call.argument<Int>("type") ?: 3 // 3: Press, 4: Release
                    val keysym = call.argument<Int>("keysym") ?: 0
                    sendPacket(type, keysym, 0)
                    result.success(true)
                }
                "disconnectTouch" -> {
                    try {
                        touchOut?.close()
                        touchSocket?.close()
                    } catch (_: Exception) {}
                    touchOut = null
                    touchSocket = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun sendPacket(type: Int, d1: Int, d2: Int) {
        touchOut?.let { out ->
            thread {
                try {
                    val buffer = ByteBuffer.allocate(9)
                    buffer.order(ByteOrder.BIG_ENDIAN)
                    buffer.put(type.toByte())
                    buffer.putInt(d1)
                    buffer.putInt(d2)
                    synchronized(out) {
                        out.write(buffer.array())
                        out.flush()
                    }
                } catch (_: Exception) {}
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            touchOut?.close()
            touchSocket?.close()
        } catch (_: Exception) {}
    }
}

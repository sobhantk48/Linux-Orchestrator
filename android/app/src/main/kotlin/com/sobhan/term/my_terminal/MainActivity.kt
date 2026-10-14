package com.sobhan.term.my_terminal

import android.net.LocalSocket
import android.net.LocalSocketAddress
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "com.sobhan.term/x11_display"
    private val FRAME_CHANNEL  = "com.sobhan.term/x11_frames"

    // touch
    private var touchSocket: LocalSocket? = null
    private var touchOut: OutputStream? = null

    // frame stream
    @Volatile private var frameRunning = false
    private var frameSocket: LocalSocket? = null
    private var frameThread: Thread? = null
    private var frameSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connectTouch" -> thread {
                        try {
                            touchSocket = LocalSocket().apply {
                                connect(LocalSocketAddress(
                                    "/tmp/sobhan_x11_touch",
                                    LocalSocketAddress.Namespace.FILESYSTEM
                                ))
                            }
                            touchOut = touchSocket!!.outputStream
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SOCKET_ERR", e.message, null) }
                        }
                    }
                    "sendTouchEvent" -> {
                        sendPacket(
                            call.argument<Int>("type") ?: 0,
                            call.argument<Int>("x")    ?: 0,
                            call.argument<Int>("y")    ?: 0
                        )
                        result.success(true)
                    }
                    "sendKeyEvent" -> {
                        sendPacket(
                            call.argument<Int>("type")   ?: 3,
                            call.argument<Int>("keysym") ?: 0,
                            0
                        )
                        result.success(true)
                    }
                    "disconnectTouch" -> {
                        runCatching { touchOut?.close(); touchSocket?.close() }
                        touchOut = null; touchSocket = null
                        result.success(true)
                    }
                    "deployDesktopAssets" -> thread {
                        try {
                            deployDesktopAssets()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DEPLOY_ERR", e.message, null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, FRAME_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    frameSink = sink
                    startFrameStream()
                }
                override fun onCancel(args: Any?) {
                    stopFrameStream()
                    frameSink = null
                }
            })
    }

    // ─── Frame streaming ─────────────────────────────────────────

    private fun startFrameStream() {
        frameRunning = true
        frameThread = thread(name = "x11-frame-reader") {
            while (frameRunning) {
                try {
                    val sock = LocalSocket()
                    sock.connect(LocalSocketAddress(
                        "sobhan_x11_frame",
                        LocalSocketAddress.Namespace.ABSTRACT
                    ))
                    frameSocket = sock
                    val input: InputStream = sock.inputStream

                    // header: 2 × int32 (little-endian, C native)
                    val hdr = ByteArray(8)
                    if (!readFully(input, hdr, 8)) { sock.close(); continue }
                    val bb = ByteBuffer.wrap(hdr).order(ByteOrder.LITTLE_ENDIAN)
                    val w = bb.int
                    val h = bb.int
                    val frameSize = w * h * 4

                    val buf = ByteArray(frameSize)
                    var lastFrameTime = 0L

                    while (frameRunning) {
                        if (!readFully(input, buf, frameSize)) break

                        // throttle to ~30 fps to ease bridge pressure
                        val now = System.currentTimeMillis()
                        if (now - lastFrameTime < 33) continue
                        lastFrameTime = now

                        val copy = buf.copyOf()
                        runOnUiThread {
                            frameSink?.success(mapOf(
                                "width"  to w,
                                "height" to h,
                                "bytes"  to copy
                            ))
                        }
                    }
                    sock.close()
                } catch (_: Exception) {
                    runCatching { frameSocket?.close() }
                    frameSocket = null
                    if (frameRunning) Thread.sleep(1500)
                }
            }
        }
    }

    private fun stopFrameStream() {
        frameRunning = false
        runCatching { frameSocket?.close() }
        frameSocket = null
        frameThread?.interrupt()
        frameThread = null
    }

    private fun readFully(input: InputStream, buf: ByteArray, size: Int): Boolean {
        var read = 0
        while (read < size) {
            val n = input.read(buf, read, size - read)
            if (n < 0) return false
            read += n
        }
        return true
    }

    // ─── Touch packet ─────────────────────────────────────────────

    private fun sendPacket(type: Int, d1: Int, d2: Int) {
        val out = touchOut ?: return
        thread {
            try {
                val buf = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
                buf.put(type.toByte()).putInt(d1).putInt(d2)
                synchronized(out) { out.write(buf.array()); out.flush() }
            } catch (_: Exception) {}
        }
    }

    // ─── Asset deployment ─────────────────────────────────────────

    private fun copyAsset(src: String, dest: File) {
        dest.parentFile?.mkdirs()
        assets.open(src).use { i -> FileOutputStream(dest).use { o -> i.copyTo(o) } }
    }

    private fun deployDesktopAssets() {
        val root = File("/data/ubuntu"); if (!root.exists()) return
        val bin  = File(root, "usr/local/bin").also { it.mkdirs() }
        runCatching { copyAsset("scripts/start_desktop",    File(bin,  "start_desktop")) }
        runCatching { copyAsset("scripts/setup_desktop.sh", File(bin,  "setup_desktop.sh")) }
        runCatching { copyAsset("x11_bridge/touch_server.c", File(root, "tmp/touch_server.c")) }
        Runtime.getRuntime().exec(arrayOf("su", "-c",
            "chmod +x /data/ubuntu/usr/local/bin/start_desktop " +
            "/data/ubuntu/usr/local/bin/setup_desktop.sh 2>/dev/null; true"
        )).waitFor()
    }

    // ─── Lifecycle ────────────────────────────────────────────────

    override fun onDestroy() {
        super.onDestroy()
        stopFrameStream()
        runCatching { touchOut?.close(); touchSocket?.close() }
    }
}

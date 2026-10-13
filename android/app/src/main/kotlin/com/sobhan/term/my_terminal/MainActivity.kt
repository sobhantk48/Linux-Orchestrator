package com.sobhan.term.my_terminal

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sobhan.term/x11_display"
    private var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var renderThread: Thread? = null
    @Volatile
    private var isRunning = false
    private val mainHandler = Handler(Looper.getMainLooper())

    // مدیریت سوکت تاچ
    private var touchSocket: LocalSocket? = null
    private var touchOutputStream: OutputStream? = null
    private val touchLock = Any()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startDisplay" -> {
                    val socketName = call.argument<String>("socketName") 
                        ?: call.argument<String>("socketPath") 
                        ?: "sobhan_x11_frame"
                    val cleanSocketName = if (socketName.contains("/")) {
                        socketName.substringAfterLast("/").removeSuffix(".sock")
                    } else {
                        socketName
                    }
                    startDisplayPipeline(cleanSocketName, result)
                    connectTouchSocket()
                }
                "stopDisplay" -> {
                    stopDisplayPipeline()
                    disconnectTouchSocket()
                    result.success(true)
                }
                "sendTouchEvent" -> {
                    val type = call.argument<Int>("type") ?: 0
                    val x = call.argument<Int>("x") ?: 0
                    val y = call.argument<Int>("y") ?: 0
                    sendTouchEvent(type, x, y)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun connectTouchSocket() {
        Thread {
            try {
                synchronized(touchLock) {
                    touchSocket?.close()
                    val sock = LocalSocket()
                    sock.connect(LocalSocketAddress("sobhan_x11_touch", LocalSocketAddress.Namespace.ABSTRACT))
                    touchSocket = sock
                    touchOutputStream = sock.outputStream
                }
            } catch (_: Exception) {}
        }.start()
    }

    private fun disconnectTouchSocket() {
        synchronized(touchLock) {
            try { touchOutputStream?.close() } catch (_: Exception) {}
            try { touchSocket?.close() } catch (_: Exception) {}
            touchOutputStream = null
            touchSocket = null
        }
    }

    private fun sendTouchEvent(type: Int, x: Int, y: Int) {
        val stream = touchOutputStream ?: return
        try {
            // پکت ۹ بایتی: type (1 byte) + x (4 bytes) + y (4 bytes)
            val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
            buffer.put(type.toByte())
            buffer.putInt(x)
            buffer.putInt(y)
            synchronized(touchLock) {
                stream.write(buffer.array())
                stream.flush()
            }
        } catch (_: Exception) {
            disconnectTouchSocket()
            connectTouchSocket()
        }
    }

    private fun startDisplayPipeline(socketName: String, result: MethodChannel.Result) {
        stopDisplayPipeline()

        val entry = flutterEngine?.renderer?.createSurfaceTexture()
        if (entry == null) {
            result.error("TEXTURE_ERROR", "Failed to create SurfaceTexture", null)
            return
        }

        surfaceTextureEntry = entry
        surface = Surface(entry.surfaceTexture())
        isRunning = true

        renderThread = Thread {
            var socket: LocalSocket? = null
            var inputStream: InputStream? = null
            var bitmap: Bitmap? = null
            val paint = Paint()

            try {
                socket = LocalSocket()
                val targetName = if (socketName.isEmpty()) "sobhan_x11_frame" else socketName
                socket.connect(LocalSocketAddress(targetName, LocalSocketAddress.Namespace.ABSTRACT))
                inputStream = socket.inputStream

                val headerBuf = ByteArray(8)
                readFully(inputStream, headerBuf, 8)
                val byteBuffer = ByteBuffer.wrap(headerBuf).order(ByteOrder.LITTLE_ENDIAN)
                val width = byteBuffer.int
                val height = byteBuffer.int

                if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
                    throw IllegalStateException("Invalid dimensions received: ${width}x${height}")
                }

                entry.surfaceTexture().setDefaultBufferSize(width, height)
                bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

                mainHandler.post {
                    result.success(mapOf(
                        "textureId" to entry.id(),
                        "width" to width,
                        "height" to height
                    ))
                }

                val frameSize = width * height * 4
                val frameBytes = ByteArray(frameSize)
                val pixelBuffer = ByteBuffer.wrap(frameBytes)

                while (isRunning) {
                    readFully(inputStream, frameBytes, frameSize)
                    pixelBuffer.rewind()
                    bitmap.copyPixelsFromBuffer(pixelBuffer)

                    val canvas: Canvas? = surface?.lockCanvas(null)
                    if (canvas != null) {
                        canvas.drawBitmap(bitmap, 0f, 0f, paint)
                        surface?.unlockCanvasAndPost(canvas)
                    }
                }
            } catch (e: Exception) {
                if (isRunning) {
                    mainHandler.post {
                        try {
                            result.error("SOCKET_ERROR", e.localizedMessage ?: "Connection error", null)
                        } catch (_: Exception) {}
                    }
                }
            } finally {
                try { inputStream?.close() } catch (_: Exception) {}
                try { socket?.close() } catch (_: Exception) {}
                bitmap?.recycle()
            }
        }.apply {
            name = "X11FrameReaderThread"
            start()
        }
    }

    private fun readFully(stream: InputStream, buffer: ByteArray, length: Int) {
        var totalRead = 0
        while (totalRead < length && isRunning) {
            val bytesRead = stream.read(buffer, totalRead, length - totalRead)
            if (bytesRead == -1) {
                throw IllegalStateException("End of stream reached prematurely")
            }
            totalRead += bytesRead
        }
    }

    private fun stopDisplayPipeline() {
        isRunning = false
        renderThread?.interrupt()
        renderThread = null

        surface?.release()
        surface = null

        surfaceTextureEntry?.release()
        surfaceTextureEntry = null
    }

    override fun onDestroy() {
        stopDisplayPipeline()
        disconnectTouchSocket()
        super.onDestroy()
    }
}

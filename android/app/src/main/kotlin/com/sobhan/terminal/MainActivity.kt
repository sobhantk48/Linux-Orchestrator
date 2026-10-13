package com.sobhan.terminal

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.Socket
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sobhan.terminal/x11"
    private var touchSocket: Socket? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "initRootfsAssets" -> {
                    thread {
                        try {
                            deployDesktopAssets()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DEPLOY_ERROR", e.message, null)
                        }
                    }
                }
                "sendTouchEvent" -> {
                    val type = call.argument<Int>("type") ?: 0
                    val x = call.argument<Int>("x") ?: 0
                    val y = call.argument<Int>("y") ?: 0
                    sendTouchPacket(type, x, y)
                    result.success(true)
                }
                "sendKeyEvent" -> {
                    val type = call.argument<Int>("type") ?: 3
                    val keysym = call.argument<Int>("keysym") ?: 0
                    sendKeyPacket(type, keysym)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun copyAssetToFile(assetPath: String, destFile: File) {
        destFile.parentFile?.mkdirs()
        assets.open(assetPath).use { input ->
            FileOutputStream(destFile).use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun deployDesktopAssets() {
        try {
            val rootfsDir = File("/data/ubuntu")
            if (!rootfsDir.exists()) return

            val localBin = File(rootfsDir, "usr/local/bin")
            localBin.mkdirs()

            // کپی اسکریپت استارت و تنظیم دسکتاپ
            val startDest = File(localBin, "start_desktop")
            copyAssetToFile("scripts/start_desktop", startDest)

            val setupDest = File(localBin, "setup_desktop.sh")
            copyAssetToFile("scripts/setup_desktop.sh", setupDest)

            // کپی سرورهای ورودی و تصویر
            val touchSrc = File(rootfsDir, "tmp/touch_server.c")
            copyAssetToFile("x11_bridge/touch_server.c", touchSrc)

            Runtime.getRuntime().exec(arrayOf("su", "-c", "chmod +x /data/ubuntu/usr/local/bin/start_desktop /data/ubuntu/usr/local/bin/setup_desktop.sh")).waitFor()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun connectTouchSocketIfNeeded() {
        if (touchSocket == null || touchSocket!!.isClosed || !touchSocket!!.isConnected) {
            try {
                touchSocket = Socket("127.0.0.1", 6001)
            } catch (e: Exception) {
                touchSocket = null
            }
        }
    }

    private fun sendTouchPacket(type: Int, x: Int, y: Int) {
        thread {
            try {
                connectTouchSocketIfNeeded()
                touchSocket?.let { sock ->
                    val out = sock.getOutputStream()
                    val packet = ByteArray(9)
                    packet[0] = type.toByte()
                    packet[1] = (x shr 24).toByte()
                    packet[2] = (x shr 16).toByte()
                    packet[3] = (x shr 8).toByte()
                    packet[4] = x.toByte()
                    packet[5] = (y shr 24).toByte()
                    packet[6] = (y shr 16).toByte()
                    packet[7] = (y shr 8).toByte()
                    packet[8] = y.toByte()
                    out.write(packet)
                    out.flush()
                }
            } catch (e: Exception) {
                touchSocket = null
            }
        }
    }

    private fun sendKeyPacket(type: Int, keysym: Int) {
        thread {
            try {
                connectTouchSocketIfNeeded()
                touchSocket?.let { sock ->
                    val out = sock.getOutputStream()
                    val packet = ByteArray(9)
                    packet[0] = type.toByte()
                    packet[1] = (keysym shr 24).toByte()
                    packet[2] = (keysym shr 16).toByte()
                    packet[3] = (keysym shr 8).toByte()
                    packet[4] = keysym.toByte()
                    // فیلد y برای کلیدها صفر پر می‌شود
                    packet[5] = 0
                    packet[6] = 0
                    packet[7] = 0
                    packet[8] = 0
                    out.write(packet)
                    out.flush()
                }
            } catch (e: Exception) {
                touchSocket = null
            }
        }
    }

    override fun onDestroy() {
        try {
            touchSocket?.close()
        } catch (e: Exception) {
            // ignore
        }
        super.onDestroy()
    }
}

package com.example.linuxorchestrator.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

object RootChecker {

    fun isDirectRoot(): Boolean {
        return try {
            NativeBridge.isDirectRoot()
        } catch (e: Throwable) {
            false
        }
    }

    fun getSELinuxStatus(): String {
        return try {
            NativeBridge.getSELinuxMode()
        } catch (e: Throwable) {
            "Unknown (${e.localizedMessage})"
        }
    }

    suspend fun hasSuBinary(): Boolean = withContext(Dispatchers.IO) {
        val paths = arrayOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/data/local/su"
        )
        paths.any { File(it).exists() } || canExecuteSu()
    }

    private suspend fun canExecuteSu(): Boolean = withContext(Dispatchers.IO) {
        try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val exitCode = process.waitFor()
            exitCode == 0
        } catch (e: Exception) {
            false
        }
    }
}

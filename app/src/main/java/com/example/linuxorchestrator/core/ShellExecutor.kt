package com.example.linuxorchestrator.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader

object ShellExecutor {
    suspend fun runNative(command: String): String =
        withContext(Dispatchers.IO) {
            try {
                NativeBridge.runCommandNative(command)
            } catch (e: Throwable) {
                "Error executing native command: ${e.localizedMessage}"
            }
        }

    suspend fun runAsRoot(command: String): String =
        withContext(Dispatchers.IO) {
            try {
                val process = Runtime.getRuntime().exec("su")
                val output = StringBuilder()

                val os = process.outputStream.bufferedWriter()
                val reader = BufferedReader(InputStreamReader(process.inputStream))
                val errorReader = BufferedReader(InputStreamReader(process.errorStream))

                os.write(command + "\n")
                os.write("exit\n")
                os.flush()

                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    output.append(line).append("\n")
                }
                while (errorReader.readLine().also { line = it } != null) {
                    output.append("[ERR] ").append(line).append("\n")
                }

                process.waitFor()
                output.toString().trim()
            } catch (e: Exception) {
                "Root Execution Failed: ${e.localizedMessage}"
            }
        }
}

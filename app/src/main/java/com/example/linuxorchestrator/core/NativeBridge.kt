package com.example.linuxorchestrator.core

object NativeBridge {
    init {
        System.loadLibrary("linuxorchestrator")
    }

    external fun isDirectRoot(): Boolean

    external fun getSELinuxMode(): String

    external fun runCommandNative(command: String): String
}

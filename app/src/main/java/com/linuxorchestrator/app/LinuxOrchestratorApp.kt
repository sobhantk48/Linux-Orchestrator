package com.linuxorchestrator.app

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class LinuxOrchestratorApp : Application() {
    override fun onCreate() {
        super.onCreate()
    }
}

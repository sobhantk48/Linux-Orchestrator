package com.example.linuxorchestrator.presentation

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.linuxorchestrator.core.RootChecker
import com.example.linuxorchestrator.core.ShellExecutor
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(
                colorScheme =
                    darkColorScheme(
                        primary = Color(0xFF4CAF50),
                        background = Color(0xFF121212),
                        surface = Color(0xFF1E1E1E),
                    ),
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    DashboardScreen()
                }
            }
        }
    }
}

@Composable
fun DashboardScreen() {
    val coroutineScope = rememberCoroutineScope()
    var directRoot by remember { mutableStateOf(false) }
    var selinuxStatus by remember { mutableStateOf("Checking...") }
    var suAvailable by remember { mutableStateOf<Boolean?>(null) }
    var commandInput by remember { mutableStateOf("uname -a") }
    var commandOutput by remember { mutableStateOf("Ready to execute commands...") }
    var isExecuting by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        directRoot = RootChecker.isDirectRoot()
        selinuxStatus = RootChecker.getSELinuxStatus()
        suAvailable = RootChecker.hasSuBinary()
    }

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = "Linux Orchestrator",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.primary,
        )

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(text = "System Diagnostics (Phase 0)", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                HorizontalDivider(color = Color.DarkGray)
                Text(text = "• Native UID == 0: ${if (directRoot) "YES (Root)" else "NO (App UID)"}")
                Text(text = "• SELinux Mode: $selinuxStatus")
                Text(text = "• SU Binary Detected: ${suAvailable?.let { if (it) "YES" else "NO" } ?: "Checking..."}")
            }
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        ) {
            Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(text = "Terminal Test Box", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)

                OutlinedTextField(
                    value = commandInput,
                    onValueChange = { commandInput = it },
                    label = { Text("Command") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(
                        onClick = {
                            coroutineScope.launch {
                                isExecuting = true
                                commandOutput = ShellExecutor.runNative(commandInput)
                                isExecuting = false
                            }
                        },
                        modifier = Modifier.weight(1f),
                        enabled = !isExecuting,
                    ) {
                        Text("Native Shell")
                    }

                    Button(
                        onClick = {
                            coroutineScope.launch {
                                isExecuting = true
                                commandOutput = ShellExecutor.runAsRoot(commandInput)
                                isExecuting = false
                            }
                        },
                        modifier = Modifier.weight(1f),
                        enabled = !isExecuting,
                    ) {
                        Text("Root (SU)")
                    }
                }
            }
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = Color.Black),
            shape = RoundedCornerShape(8.dp),
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                Text(
                    text = "Console Output:",
                    fontSize = 12.sp,
                    color = Color.Gray,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = if (isExecuting) "Executing..." else commandOutput,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    color = Color(0xFF00FF66),
                )
            }
        }
    }
}

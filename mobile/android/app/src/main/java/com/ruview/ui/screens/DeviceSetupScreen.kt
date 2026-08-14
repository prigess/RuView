package com.ruview.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ruview.ui.viewmodel.SensingViewModel
import com.ruview.ui.viewmodel.UiState
import kotlinx.coroutines.launch

@Composable
fun DeviceSetupScreen(
    viewModel: SensingViewModel,
    onConnected: () -> Unit
) {
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    val savedHost by viewModel.deviceHost.collectAsState()
    val healthState by viewModel.healthState.collectAsState()

    var ipInput by remember { mutableStateOf(savedHost) }
    var isCheckingHealth by remember { mutableStateOf(false) }

    LaunchedEffect(healthState) {
        when (val state = healthState) {
            is UiState.Success -> {
                isCheckingHealth = false
                if (state.data.status == "ok") {
                    viewModel.connect(ipInput)
                    onConnected()
                } else {
                    scope.launch {
                        snackbarHostState.showSnackbar("Server returned unexpected status: ${state.data.status}")
                    }
                }
            }
            is UiState.Error -> {
                isCheckingHealth = false
                scope.launch {
                    snackbarHostState.showSnackbar("Connection failed: ${state.message}")
                }
            }
            is UiState.Loading -> {
                isCheckingHealth = true
            }
            else -> {
                isCheckingHealth = false
            }
        }
    }

    Scaffold(
        snackbarHost = {
            SnackbarHost(snackbarHostState) { data ->
                Snackbar(
                    snackbarData = data,
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            }
        }
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            contentAlignment = Alignment.Center
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Wifi,
                    contentDescription = "RuView Logo",
                    modifier = Modifier.size(72.dp),
                    tint = MaterialTheme.colorScheme.primary
                )

                Text(
                    text = "RuView",
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )

                Text(
                    text = "WiFi Sensing System",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(modifier = Modifier.height(16.dp))

                Text(
                    text = "Enter the IP address of your Orange Pi sensing server",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                OutlinedTextField(
                    value = ipInput,
                    onValueChange = { ipInput = it },
                    label = { Text("Server IP Address") },
                    placeholder = { Text("e.g. 192.168.1.100") },
                    singleLine = true,
                    enabled = !isCheckingHealth,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Done
                    ),
                    keyboardActions = KeyboardActions(
                        onDone = {
                            if (ipInput.isNotBlank() && !isCheckingHealth) {
                                viewModel.checkHealth(ipInput.trim())
                            }
                        }
                    ),
                    modifier = Modifier.fillMaxWidth()
                )

                AnimatedVisibility(visible = isCheckingHealth) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(36.dp))
                        Text(
                            text = "Checking connection...",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                AnimatedVisibility(visible = !isCheckingHealth) {
                    Button(
                        onClick = {
                            if (ipInput.isNotBlank()) {
                                viewModel.checkHealth(ipInput.trim())
                            }
                        },
                        enabled = ipInput.isNotBlank(),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Connect")
                    }
                }

                Text(
                    text = "Server runs on port 3022 (HTTP) and 3023 (WebSocket)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

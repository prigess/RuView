package com.ruview.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.SignalWifiOff
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.ruview.data.VitalSigns
import com.ruview.ui.viewmodel.SensingViewModel
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

private const val MEASURING_DURATION_MS = 30_000L

@Composable
fun VitalSignsScreen(viewModel: SensingViewModel) {
    val snapshot by viewModel.latestSnapshot.collectAsState()
    val isConnected by viewModel.isConnected.collectAsState()
    val isSimulation by viewModel.isSimulation.collectAsState()
    val isStale by viewModel.isStale.collectAsState()

    var isMeasuring by remember { mutableStateOf(true) }

    LaunchedEffect(isConnected) {
        if (isConnected) {
            isMeasuring = true
            delay(MEASURING_DURATION_MS)
            isMeasuring = false
        } else {
            isMeasuring = false
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            AnimatedVisibility(visible = isSimulation) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = Color(0xFFFFF3CD),
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Text(
                        text = "DEMO MODE — Simulated Data",
                        modifier = Modifier.padding(8.dp),
                        style = MaterialTheme.typography.labelLarge,
                        color = Color(0xFF856404),
                        textAlign = TextAlign.Center
                    )
                }
            }

            AnimatedVisibility(visible = isStale && isConnected) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Filled.SignalWifiOff,
                            contentDescription = "Signal Lost",
                            tint = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.size(20.dp)
                        )
                        Text(
                            text = "Signal Lost",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onErrorContainer
                        )
                    }
                }
            }

            if (!isConnected) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.SignalWifiOff,
                            contentDescription = "Disconnected",
                            modifier = Modifier.size(48.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "Not connected",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                return@Column
            }

            if (isMeasuring) {
                MeasuringCard()
            }

            val vitals = snapshot?.vitalSigns

            VitalCard(
                title = "Heart Rate",
                icon = Icons.Filled.Favorite,
                value = vitals?.heartRateBpm,
                confidence = vitals?.heartbeatConfidence ?: 0.0,
                unit = "bpm",
                iconTint = Color(0xFFF44336),
                isMeasuring = isMeasuring
            )

            VitalCard(
                title = "Breathing Rate",
                icon = Icons.Filled.Air,
                value = vitals?.breathingRateBpm,
                confidence = vitals?.breathingConfidence ?: 0.0,
                unit = "bpm",
                iconTint = Color(0xFF2196F3),
                isMeasuring = isMeasuring
            )

            if (vitals != null) {
                SignalQualityCard(signalQuality = vitals.signalQuality)
            }
        }
    }
}

@Composable
private fun MeasuringCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 3.dp,
                color = MaterialTheme.colorScheme.secondary
            )
            Column {
                Text(
                    text = "Measuring...",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
                Text(
                    text = "Please remain still for accurate readings (30s warm-up)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
        }
    }
}

@Composable
private fun VitalCard(
    title: String,
    icon: ImageVector,
    value: Double?,
    confidence: Double,
    unit: String,
    iconTint: Color,
    isMeasuring: Boolean
) {
    val displayValue = formatVitalValue(value, confidence, unit, isMeasuring)
    val confidencePercent = (confidence * 100).roundToInt()

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = title,
                    tint = iconTint,
                    modifier = Modifier.size(24.dp)
                )
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }

            Text(
                text = displayValue,
                style = MaterialTheme.typography.displayMedium,
                fontWeight = FontWeight.Bold,
                color = when {
                    confidence < 0.3 -> MaterialTheme.colorScheme.onSurfaceVariant
                    confidence < 0.6 -> Color(0xFFFFC107)
                    else -> MaterialTheme.colorScheme.primary
                }
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Confidence: $confidencePercent%",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = when {
                        confidence < 0.3 -> "Low"
                        confidence < 0.6 -> "Fair"
                        else -> "Good"
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = when {
                        confidence < 0.3 -> MaterialTheme.colorScheme.error
                        confidence < 0.6 -> Color(0xFFFFC107)
                        else -> Color(0xFF4CAF50)
                    }
                )
            }

            LinearProgressIndicator(
                progress = { confidence.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
                color = when {
                    confidence < 0.3 -> MaterialTheme.colorScheme.error
                    confidence < 0.6 -> Color(0xFFFFC107)
                    else -> Color(0xFF4CAF50)
                },
                trackColor = MaterialTheme.colorScheme.surfaceVariant
            )
        }
    }
}

private fun formatVitalValue(
    value: Double?,
    confidence: Double,
    unit: String,
    isMeasuring: Boolean
): String {
    if (value == null || isMeasuring) return "–"
    return when {
        confidence < 0.3 -> "–"
        confidence < 0.6 -> "~${value.roundToInt()} $unit"
        else -> "${value.roundToInt()} $unit"
    }
}

@Composable
private fun SignalQualityCard(signalQuality: Double) {
    val qualityPercent = (signalQuality * 100).roundToInt()
    val qualityLabel = when {
        signalQuality < 0.3 -> "Poor"
        signalQuality < 0.6 -> "Fair"
        signalQuality < 0.8 -> "Good"
        else -> "Excellent"
    }
    val qualityColor = when {
        signalQuality < 0.3 -> MaterialTheme.colorScheme.error
        signalQuality < 0.6 -> Color(0xFFFFC107)
        signalQuality < 0.8 -> Color(0xFF4CAF50)
        else -> Color(0xFF2196F3)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "Signal Quality",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = "$qualityLabel ($qualityPercent%)",
                    style = MaterialTheme.typography.labelMedium,
                    color = qualityColor,
                    fontWeight = FontWeight.SemiBold
                )
            }
            LinearProgressIndicator(
                progress = { signalQuality.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
                color = qualityColor,
                trackColor = MaterialTheme.colorScheme.surface
            )
            Spacer(modifier = Modifier.height(0.dp))
        }
    }
}

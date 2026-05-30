package com.ruview.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SignalWifiOff
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ruview.data.SensingSnapshot
import com.ruview.ui.viewmodel.SensingViewModel
import kotlin.math.roundToInt

private fun motionLevelLabel(motionLevel: String): String = when (motionLevel) {
    "absent" -> "Empty"
    "present_still" -> "Someone here"
    "present_moving" -> "Movement detected"
    "active" -> "High activity"
    else -> motionLevel.replace("_", " ").replaceFirstChar { it.uppercase() }
}

private fun motionLevelColor(motionLevel: String): Color = when (motionLevel) {
    "absent" -> Color(0xFF9E9E9E)
    "present_still" -> Color(0xFF2196F3)
    "present_moving" -> Color(0xFFFFC107)
    "active" -> Color(0xFFF44336)
    else -> Color(0xFF9E9E9E)
}

@Composable
fun OccupancyScreen(viewModel: SensingViewModel) {
    val snapshot by viewModel.latestSnapshot.collectAsState()
    val isConnected by viewModel.isConnected.collectAsState()
    val isStale by viewModel.isStale.collectAsState()
    val isSimulation by viewModel.isSimulation.collectAsState()

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Demo mode banner
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

            if (snapshot != null) {
                OccupancyContent(
                    snapshot = snapshot!!,
                    isStale = isStale
                )
            } else if (isConnected) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "Waiting for data...",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
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
            }
        }

        // Signal Lost overlay
        AnimatedVisibility(
            visible = isStale && isConnected,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 72.dp)
        ) {
            Surface(
                color = MaterialTheme.colorScheme.errorContainer,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.padding(horizontal = 16.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
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
    }
}

@Composable
private fun OccupancyContent(snapshot: SensingSnapshot, isStale: Boolean) {
    val classification = snapshot.classification
    val motionColor = motionLevelColor(classification.motionLevel)
    val contentAlpha = if (isStale) 0.5f else 1f

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp),
        modifier = Modifier.alpha(contentAlpha)
    ) {
        // Large person count
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer
            )
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "${snapshot.estimatedPersons}",
                    fontSize = 96.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    lineHeight = 96.sp
                )
                Text(
                    text = if (snapshot.estimatedPersons == 1) "Person Detected" else "People Detected",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
        }

        // Motion level chip
        AssistChip(
            onClick = {},
            label = {
                Text(
                    text = motionLevelLabel(classification.motionLevel),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold
                )
            },
            colors = AssistChipDefaults.assistChipColors(
                containerColor = motionColor.copy(alpha = 0.15f),
                labelColor = motionColor
            ),
            border = AssistChipDefaults.assistChipBorder(
                enabled = true,
                borderColor = motionColor.copy(alpha = 0.5f)
            )
        )

        // Confidence subtitle
        Text(
            text = "Confidence: ${(classification.confidence * 100).roundToInt()}%",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Tick freshness indicator
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(
                        color = if (isStale) Color(0xFFF44336) else Color(0xFF4CAF50),
                        shape = CircleShape
                    )
            )
            Text(
                text = if (isStale) "Tick frozen at ${snapshot.tick}" else "Tick: ${snapshot.tick}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        // Persons info
        if (snapshot.persons.isNotEmpty()) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Active tracking: ${snapshot.persons.size} person(s)",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.secondary
            )
        }

        // Node count
        if (snapshot.nodes.isNotEmpty()) {
            Text(
                text = "${snapshot.nodes.size} sensing node(s) active",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

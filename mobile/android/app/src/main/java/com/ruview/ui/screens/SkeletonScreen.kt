package com.ruview.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SignalWifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ruview.data.COCO17_SKELETON_EDGES
import com.ruview.data.Person
import com.ruview.ui.viewmodel.SensingViewModel

private val PERSON_COLORS = listOf(
    Color(0xFF4CAF50),  // Green
    Color(0xFF2196F3),  // Blue
    Color(0xFFF44336),  // Red
    Color(0xFFFF9800),  // Orange
    Color(0xFF9C27B0),  // Purple
    Color(0xFF00BCD4),  // Cyan
    Color(0xFFFFEB3B),  // Yellow
    Color(0xFFE91E63)   // Pink
)

private const val POSE_SPACE_WIDTH = 640.0f
private const val POSE_SPACE_HEIGHT = 480.0f

@Composable
fun SkeletonScreen(viewModel: SensingViewModel) {
    val snapshot by viewModel.latestSnapshot.collectAsState()
    val isConnected by viewModel.isConnected.collectAsState()
    val isSimulation by viewModel.isSimulation.collectAsState()
    val isStale by viewModel.isStale.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (isSimulation) {
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

        if (isStale && isConnected) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.errorContainer,
                shape = RoundedCornerShape(8.dp)
            ) {
                Text(
                    text = "Signal Lost",
                    modifier = Modifier.padding(8.dp),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    textAlign = TextAlign.Center
                )
            }
        }

        val persons = snapshot?.persons ?: emptyList()

        Text(
            text = if (persons.isEmpty()) "No persons tracked" else "${persons.size} person(s) tracked",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )

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
                        modifier = Modifier.padding(8.dp),
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

        if (persons.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        MaterialTheme.colorScheme.surfaceVariant,
                        RoundedCornerShape(12.dp)
                    ),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "No skeletons to display\nWaiting for person detection...",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )
            }
            return@Column
        }

        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF0D1117), RoundedCornerShape(12.dp))
        ) {
            val canvasWidth = size.width
            val canvasHeight = size.height

            val scaleX = canvasWidth / POSE_SPACE_WIDTH
            val scaleY = canvasHeight / POSE_SPACE_HEIGHT

            persons.forEachIndexed { personIndex, person ->
                val color = PERSON_COLORS[personIndex % PERSON_COLORS.size]
                val keypointMap = person.keypoints.associateBy { it.name }

                // Draw skeleton bones
                for ((startName, endName) in COCO17_SKELETON_EDGES) {
                    val startKp = keypointMap[startName]
                    val endKp = keypointMap[endName]
                    if (startKp != null && endKp != null) {
                        drawLine(
                            color = color.copy(alpha = 0.7f),
                            start = Offset(
                                x = startKp.x.toFloat() * scaleX,
                                y = startKp.y.toFloat() * scaleY
                            ),
                            end = Offset(
                                x = endKp.x.toFloat() * scaleX,
                                y = endKp.y.toFloat() * scaleY
                            ),
                            strokeWidth = 3f,
                            cap = StrokeCap.Round
                        )
                    }
                }

                // Draw keypoint circles
                for (keypoint in person.keypoints) {
                    val cx = keypoint.x.toFloat() * scaleX
                    val cy = keypoint.y.toFloat() * scaleY
                    drawCircle(
                        color = color,
                        radius = 6f,
                        center = Offset(cx, cy)
                    )
                    drawCircle(
                        color = Color.White,
                        radius = 3f,
                        center = Offset(cx, cy)
                    )
                }

                // Draw person ID label near the first keypoint or bbox center
                val labelX = if (person.keypoints.isNotEmpty()) {
                    person.keypoints.first().x.toFloat() * scaleX
                } else {
                    person.bbox.x.toFloat() * scaleX
                }
                val labelY = if (person.keypoints.isNotEmpty()) {
                    (person.keypoints.first().y.toFloat() * scaleY) - 20f
                } else {
                    person.bbox.y.toFloat() * scaleY - 20f
                }

                // Draw person ID background circle
                drawCircle(
                    color = color,
                    radius = 16f,
                    center = Offset(labelX, labelY)
                )
            }
        }

        // Person legend
        persons.forEachIndexed { index, person ->
            val color = PERSON_COLORS[index % PERSON_COLORS.size]
            PersonLegendRow(person = person, color = color, index = index)
        }
    }
}

@Composable
private fun PersonLegendRow(person: Person, color: Color, index: Int) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = color.copy(alpha = 0.1f),
        shape = RoundedCornerShape(6.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Person ${index + 1} (ID: ${person.id})",
                style = MaterialTheme.typography.bodySmall,
                color = color,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = "${person.pose} • ${(person.confidence * 100).toInt()}% conf",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 11.sp
            )
        }
    }
}

package com.ruview.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.School
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ruview.ui.viewmodel.SensingViewModel
import com.ruview.ui.viewmodel.UiState
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

private data class RecordingLabel(
    val key: String,
    val displayName: String,
    val instruction: String,
    val countdownSeconds: Int = 30
)

private val RECORDING_LABELS = listOf(
    RecordingLabel(
        key = "absent",
        displayName = "Empty Room",
        instruction = "Leave the room completely empty. Ensure no people or large moving objects are present. The system will record background WiFi patterns.",
        countdownSeconds = 30
    ),
    RecordingLabel(
        key = "present_still",
        displayName = "Person Still",
        instruction = "Have one person stand or sit completely still in the center of the sensing area. No movement for the duration of the recording.",
        countdownSeconds = 30
    ),
    RecordingLabel(
        key = "present_moving",
        displayName = "Person Moving",
        instruction = "Have one person move naturally around the sensing area — walking, gesturing, and changing positions at a normal pace.",
        countdownSeconds = 30
    ),
    RecordingLabel(
        key = "active",
        displayName = "High Activity",
        instruction = "Have multiple people move actively in the sensing area — walking quickly, raising arms, multiple simultaneous movements.",
        countdownSeconds = 30
    )
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrainingWizardScreen(
    viewModel: SensingViewModel,
    onClose: () -> Unit
) {
    var currentStep by remember { mutableIntStateOf(0) }

    val calibrationState by viewModel.calibrationState.collectAsState()
    val trainState by viewModel.trainState.collectAsState()
    val groundTruthState by viewModel.groundTruthState.collectAsState()
    val adaptiveState by viewModel.adaptiveState.collectAsState()

    LaunchedEffect(Unit) {
        viewModel.fetchAdaptiveStatus()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("Training Wizard — Step ${currentStep + 1} of 6")
                },
                navigationIcon = {
                    if (currentStep > 0) {
                        IconButton(onClick = { currentStep-- }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    } else {
                        IconButton(onClick = onClose) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Close")
                        }
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // Step progress indicator
            LinearProgressIndicator(
                progress = { (currentStep + 1) / 6f },
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.primary
            )

            AnimatedContent(
                targetState = currentStep,
                transitionSpec = {
                    if (targetState > initialState) {
                        slideInHorizontally { it } togetherWith slideOutHorizontally { -it }
                    } else {
                        slideInHorizontally { -it } togetherWith slideOutHorizontally { it }
                    }
                },
                label = "wizard_step"
            ) { step ->
                when (step) {
                    0 -> WelcomeStep(onNext = { currentStep = 1 })
                    1 -> CalibrationStep(
                        viewModel = viewModel,
                        calibrationState = calibrationState,
                        onNext = { currentStep = 2 },
                        onCancel = { viewModel.stopCalibration(); currentStep = 0 }
                    )
                    2 -> RecordingStep(
                        viewModel = viewModel,
                        onNext = { currentStep = 3 }
                    )
                    3 -> TrainingStep(
                        viewModel = viewModel,
                        trainState = trainState,
                        onNext = { currentStep = 4 },
                        onRetry = { viewModel.retrainClassifier() }
                    )
                    4 -> GroundTruthStep(
                        viewModel = viewModel,
                        groundTruthState = groundTruthState,
                        onNext = { currentStep = 5 }
                    )
                    5 -> SummaryStep(
                        adaptiveState = adaptiveState,
                        trainState = trainState,
                        onClose = onClose
                    )
                }
            }
        }
    }
}

@Composable
private fun WelcomeStep(onNext: () -> Unit) {
    val prerequisites = listOf(
        "Orange Pi sensing server is running and connected",
        "At least 1 ESP32 node is active and sending data",
        "You have access to the sensing area for ~5 minutes",
        "Multiple people are available to help record training labels"
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.School,
            contentDescription = "Training",
            modifier = Modifier
                .size(64.dp)
                .align(Alignment.CenterHorizontally),
            tint = MaterialTheme.colorScheme.primary
        )
        Text(
            text = "Classifier Training Wizard",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = "This wizard will guide you through calibrating and training the adaptive presence classifier. A well-trained model improves detection accuracy for your specific environment.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = "Prerequisites",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
                prerequisites.forEach { prereq ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Check,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(18.dp)
                        )
                        Text(
                            text = prereq,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                }
            }
        }

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.secondaryContainer
            )
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = "Steps Overview",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
                Spacer(modifier = Modifier.height(8.dp))
                listOf(
                    "1. Calibration — Establish background baseline",
                    "2. Recording — Capture labeled training examples",
                    "3. Training — Train the adaptive classifier",
                    "4. Ground Truth — Set reference person count",
                    "5. Summary — Review results"
                ).forEach { step ->
                    Text(
                        text = step,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.padding(vertical = 2.dp)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        Button(
            onClick = onNext,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Begin Training")
        }
    }
}

@Composable
private fun CalibrationStep(
    viewModel: SensingViewModel,
    calibrationState: UiState<com.ruview.data.CalibrationStatus>,
    onNext: () -> Unit,
    onCancel: () -> Unit
) {
    var pollingActive by remember { mutableStateOf(false) }

    LaunchedEffect(pollingActive) {
        if (pollingActive) {
            while (pollingActive) {
                viewModel.pollCalibrationStatus()
                delay(5_000L)
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Step 1: Calibration",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold
        )

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer
            )
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = "Keep the room empty",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = "During calibration, ensure there are no people in the sensing area. The system is establishing a baseline WiFi fingerprint for the empty environment. This takes approximately 60 seconds.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
        }

        when (val state = calibrationState) {
            is UiState.Loading -> {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            is UiState.Success -> {
                val status = state.data
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = "Status: ${status.status}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (status.frames != null && status.target != null && status.target > 0) {
                            val progress = status.frames.toFloat() / status.target.toFloat()
                            Text(
                                text = "Progress: ${status.frames} / ${status.target} frames",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            LinearProgressIndicator(
                                progress = { progress.coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        if (!status.active && (status.frames ?: 0) > 0) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.CheckCircle,
                                    contentDescription = null,
                                    tint = Color(0xFF4CAF50),
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    text = "Calibration complete",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = Color(0xFF4CAF50),
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                        }
                    }
                }
            }
            is UiState.Error -> {
                Text(
                    text = "Error: ${state.message}",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            else -> {}
        }

        Spacer(modifier = Modifier.weight(1f))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutlinedButton(
                onClick = {
                    pollingActive = false
                    onCancel()
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                )
            ) {
                Text("Cancel")
            }

            if (calibrationState is UiState.Idle || calibrationState is UiState.Error) {
                Button(
                    onClick = {
                        pollingActive = true
                        viewModel.startCalibration()
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Start Calibration")
                }
            } else {
                Button(
                    onClick = {
                        pollingActive = false
                        viewModel.stopCalibration()
                        onNext()
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Done")
                }
            }
        }
    }
}

@Composable
private fun RecordingStep(
    viewModel: SensingViewModel,
    onNext: () -> Unit
) {
    var currentLabelIndex by remember { mutableIntStateOf(0) }
    var isRecording by remember { mutableStateOf(false) }
    var countdown by remember { mutableIntStateOf(0) }
    var labelsDone by remember { mutableStateOf(setOf<Int>()) }

    val recordingState by viewModel.recordingState.collectAsState()

    LaunchedEffect(isRecording) {
        if (isRecording) {
            val label = RECORDING_LABELS[currentLabelIndex]
            countdown = label.countdownSeconds
            while (countdown > 0) {
                delay(1_000L)
                countdown--
            }
            viewModel.stopRecording()
            isRecording = false
            labelsDone = labelsDone + currentLabelIndex
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Step 2: Record Training Labels",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold
        )
        Text(
            text = "Record examples for each occupancy state. You can record them in any order.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        RECORDING_LABELS.forEachIndexed { index, label ->
            val isDone = index in labelsDone
            val isCurrent = index == currentLabelIndex

            Card(
                onClick = { if (!isRecording && !isDone) currentLabelIndex = index },
                colors = CardDefaults.cardColors(
                    containerColor = when {
                        isDone -> Color(0xFF4CAF50).copy(alpha = 0.15f)
                        isCurrent -> MaterialTheme.colorScheme.primaryContainer
                        else -> MaterialTheme.colorScheme.surfaceVariant
                    }
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (isDone) {
                        Icon(
                            imageVector = Icons.Filled.CheckCircle,
                            contentDescription = "Done",
                            tint = Color(0xFF4CAF50),
                            modifier = Modifier.size(24.dp)
                        )
                    } else {
                        Text(
                            text = "${index + 1}",
                            style = MaterialTheme.typography.titleMedium,
                            color = if (isCurrent) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.width(24.dp)
                        )
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = label.displayName,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold
                        )
                        if (isCurrent && !isDone) {
                            Text(
                                text = label.instruction,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }

        if (currentLabelIndex < RECORDING_LABELS.size && currentLabelIndex !in labelsDone) {
            val label = RECORDING_LABELS[currentLabelIndex]

            if (isRecording) {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer
                    )
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = "Recording: ${label.displayName}",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = "${countdown}s remaining",
                            style = MaterialTheme.typography.displaySmall,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            fontWeight = FontWeight.Bold
                        )
                        LinearProgressIndicator(
                            progress = { countdown.toFloat() / label.countdownSeconds.toFloat() },
                            modifier = Modifier.fillMaxWidth(),
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                }
            } else {
                Button(
                    onClick = {
                        isRecording = true
                        viewModel.startRecording(label.key)
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Record \"${label.displayName}\" (${label.countdownSeconds}s)")
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        Button(
            onClick = onNext,
            enabled = labelsDone.size >= RECORDING_LABELS.size,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                if (labelsDone.size >= RECORDING_LABELS.size) "Proceed to Training"
                else "Record all ${RECORDING_LABELS.size} labels to continue"
            )
        }
    }
}

@Composable
private fun TrainingStep(
    viewModel: SensingViewModel,
    trainState: UiState<com.ruview.data.TrainResponse>,
    onNext: () -> Unit,
    onRetry: () -> Unit
) {
    LaunchedEffect(Unit) {
        viewModel.retrainClassifier()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "Step 3: Train Classifier",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(16.dp))

        when (val state = trainState) {
            is UiState.Loading -> {
                CircularProgressIndicator(modifier = Modifier.size(64.dp))
                Text(
                    text = "Training in progress...",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = "This may take 30-60 seconds depending on the number of recorded samples.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }
            is UiState.Success -> {
                val result = state.data
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = "Success",
                    tint = Color(0xFF4CAF50),
                    modifier = Modifier.size(64.dp)
                )
                if (result.success) {
                    Text(
                        text = "Training Complete!",
                        style = MaterialTheme.typography.headlineSmall,
                        color = Color(0xFF4CAF50),
                        fontWeight = FontWeight.Bold
                    )
                    result.accuracy?.let { acc ->
                        Text(
                            text = "Accuracy: ${(acc * 100).roundToInt()}%",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                } else {
                    Text(
                        text = "Training failed",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                    result.error?.let { err ->
                        Text(
                            text = err,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                }

                Spacer(modifier = Modifier.weight(1f))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedButton(
                        onClick = onRetry,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Retry")
                    }
                    Button(
                        onClick = onNext,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Next")
                    }
                }
            }
            is UiState.Error -> {
                Text(
                    text = "Error: ${state.message}",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium
                )
                Spacer(modifier = Modifier.weight(1f))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedButton(onClick = onRetry, modifier = Modifier.weight(1f)) {
                        Text("Retry")
                    }
                    Button(onClick = onNext, modifier = Modifier.weight(1f)) {
                        Text("Skip")
                    }
                }
            }
            else -> {}
        }
    }
}

@Composable
private fun GroundTruthStep(
    viewModel: SensingViewModel,
    groundTruthState: UiState<com.ruview.data.GroundTruthResponse>,
    onNext: () -> Unit
) {
    var groundTruthCount by remember { mutableFloatStateOf(1f) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Step 4: Set Ground Truth",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold
        )

        Text(
            text = "Set the actual number of people currently in the sensing area. This helps the system calibrate its person count deduplication factor.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer
            )
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = "${groundTruthCount.roundToInt()}",
                    style = MaterialTheme.typography.displayLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
                Text(
                    text = if (groundTruthCount.roundToInt() == 1) "person in the area" else "people in the area",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
                Slider(
                    value = groundTruthCount,
                    onValueChange = { groundTruthCount = it },
                    valueRange = 0f..10f,
                    steps = 9,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("0", style = MaterialTheme.typography.labelSmall)
                    Text("10", style = MaterialTheme.typography.labelSmall)
                }
            }
        }

        when (val state = groundTruthState) {
            is UiState.Loading -> {
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            is UiState.Success -> {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = Color(0xFF4CAF50).copy(alpha = 0.15f)
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "Ground truth applied successfully",
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color(0xFF4CAF50),
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Computed dedup factor: ${String.format("%.3f", state.data.computedDedupFactor)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            is UiState.Error -> {
                Text(
                    text = "Error: ${state.message}",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            else -> {}
        }

        Spacer(modifier = Modifier.weight(1f))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutlinedButton(
                onClick = {
                    viewModel.setGroundTruth(groundTruthCount.roundToInt())
                },
                modifier = Modifier.weight(1f)
            ) {
                Text("Apply")
            }
            Button(
                onClick = onNext,
                modifier = Modifier.weight(1f)
            ) {
                Text("Next")
            }
        }
    }
}

@Composable
private fun SummaryStep(
    adaptiveState: UiState<com.ruview.data.AdaptiveStatus>,
    trainState: UiState<com.ruview.data.TrainResponse>,
    onClose: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = Icons.Filled.CheckCircle,
            contentDescription = "Complete",
            tint = Color(0xFF4CAF50),
            modifier = Modifier.size(72.dp)
        )

        Text(
            text = "Training Complete!",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            color = Color(0xFF4CAF50)
        )

        Text(
            text = "The adaptive classifier has been trained for your environment. Detection accuracy should improve over the next few minutes as the model warms up.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )

        val trainSuccess = trainState as? UiState.Success
        val adaptSuccess = adaptiveState as? UiState.Success

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant
            ),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = "Training Results",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )

                trainSuccess?.data?.accuracy?.let { acc ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Training Accuracy",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = "${(acc * 100).roundToInt()}%",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (acc > 0.8) Color(0xFF4CAF50)
                            else if (acc > 0.6) Color(0xFFFFC107)
                            else MaterialTheme.colorScheme.error
                        )
                    }
                }

                adaptSuccess?.data?.trainedFrames?.let { frames ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Trained Frames",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = "$frames",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }

                adaptSuccess?.data?.loaded?.let { loaded ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Model Status",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = if (loaded) "Loaded and Active" else "Not loaded",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (loaded) Color(0xFF4CAF50)
                            else MaterialTheme.colorScheme.error
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        Button(
            onClick = onClose,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Done — Return to Dashboard")
        }
    }
}

package com.ruview.ui.viewmodel

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ruview.data.AdaptiveStatus
import com.ruview.data.CalibrationStatus
import com.ruview.data.GroundTruthResponse
import com.ruview.data.HealthResponse
import com.ruview.data.NodeStatus
import com.ruview.data.RuViewRepository
import com.ruview.data.SensingSnapshot
import com.ruview.data.StartRecordingResponse
import com.ruview.data.StopCalibrationResponse
import com.ruview.data.TrainResponse
import com.ruview.data.ZoneSummary
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

sealed class UiState<out T> {
    object Idle : UiState<Nothing>()
    object Loading : UiState<Nothing>()
    data class Success<T>(val data: T) : UiState<T>()
    data class Error(val message: String) : UiState<Nothing>()
}

class SensingViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = application.getSharedPreferences("ruview_prefs", Context.MODE_PRIVATE)
    private val repository = RuViewRepository.getInstance()

    companion object {
        private const val PREF_HOST = "device_host"
        private const val STALE_THRESHOLD = 5
        private const val NODES_POLL_INTERVAL_MS = 5_000L
        private const val ZONES_POLL_INTERVAL_MS = 2_000L
    }

    private val _deviceHost = MutableStateFlow(prefs.getString(PREF_HOST, "") ?: "")
    val deviceHost: StateFlow<String> = _deviceHost.asStateFlow()

    val latestSnapshot: StateFlow<SensingSnapshot?> = repository.latestSnapshot
    val isConnected: StateFlow<Boolean> = repository.isConnected
    val connectionError: StateFlow<String?> = repository.connectionError

    private val _isStale = MutableStateFlow(false)
    val isStale: StateFlow<Boolean> = _isStale.asStateFlow()

    val isSimulation: StateFlow<Boolean> = repository.latestSnapshot.map { snapshot ->
        snapshot?.source == "simulate"
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    private val _healthState = MutableStateFlow<UiState<HealthResponse>>(UiState.Idle)
    val healthState: StateFlow<UiState<HealthResponse>> = _healthState.asStateFlow()

    private val _nodesState = MutableStateFlow<UiState<List<NodeStatus>>>(UiState.Idle)
    val nodesState: StateFlow<UiState<List<NodeStatus>>> = _nodesState.asStateFlow()

    private val _zonesState = MutableStateFlow<UiState<ZoneSummary>>(UiState.Idle)
    val zonesState: StateFlow<UiState<ZoneSummary>> = _zonesState.asStateFlow()

    private val _calibrationState = MutableStateFlow<UiState<CalibrationStatus>>(UiState.Idle)
    val calibrationState: StateFlow<UiState<CalibrationStatus>> = _calibrationState.asStateFlow()

    private val _adaptiveState = MutableStateFlow<UiState<AdaptiveStatus>>(UiState.Idle)
    val adaptiveState: StateFlow<UiState<AdaptiveStatus>> = _adaptiveState.asStateFlow()

    private val _trainState = MutableStateFlow<UiState<TrainResponse>>(UiState.Idle)
    val trainState: StateFlow<UiState<TrainResponse>> = _trainState.asStateFlow()

    private val _groundTruthState = MutableStateFlow<UiState<GroundTruthResponse>>(UiState.Idle)
    val groundTruthState: StateFlow<UiState<GroundTruthResponse>> = _groundTruthState.asStateFlow()

    private val _recordingState = MutableStateFlow<UiState<StartRecordingResponse>>(UiState.Idle)
    val recordingState: StateFlow<UiState<StartRecordingResponse>> = _recordingState.asStateFlow()

    private var nodesPollJob: Job? = null
    private var zonesPollJob: Job? = null
    private var staleCheckJob: Job? = null

    private val recentTicks = ArrayDeque<Long>(STALE_THRESHOLD + 1)

    init {
        viewModelScope.launch {
            isConnected.collect { connected ->
                if (connected) {
                    startPolling()
                } else {
                    stopPolling()
                }
            }
        }
        viewModelScope.launch {
            latestSnapshot.collect { snapshot ->
                snapshot?.let { trackStaleness(it.tick) }
            }
        }
    }

    private fun trackStaleness(tick: Long) {
        recentTicks.addLast(tick)
        if (recentTicks.size > STALE_THRESHOLD) {
            recentTicks.removeFirst()
        }
        if (recentTicks.size == STALE_THRESHOLD) {
            val allSame = recentTicks.all { it == recentTicks.first() }
            _isStale.value = allSame
        }
    }

    private fun startPolling() {
        nodesPollJob?.cancel()
        nodesPollJob = viewModelScope.launch {
            while (isActive) {
                refreshNodes()
                delay(NODES_POLL_INTERVAL_MS)
            }
        }
        zonesPollJob?.cancel()
        zonesPollJob = viewModelScope.launch {
            while (isActive) {
                refreshZones()
                delay(ZONES_POLL_INTERVAL_MS)
            }
        }
    }

    private fun stopPolling() {
        nodesPollJob?.cancel()
        nodesPollJob = null
        zonesPollJob?.cancel()
        zonesPollJob = null
        recentTicks.clear()
        _isStale.value = false
    }

    fun connect(host: String) {
        val trimmedHost = host.trim()
        if (trimmedHost.isEmpty()) return
        _deviceHost.value = trimmedHost
        prefs.edit().putString(PREF_HOST, trimmedHost).apply()
        repository.connect(trimmedHost)
    }

    fun disconnect() {
        repository.disconnect()
        stopPolling()
    }

    fun checkHealth(host: String) {
        viewModelScope.launch {
            _healthState.value = UiState.Loading
            try {
                val result = repository.fetchHealth(host)
                _healthState.value = UiState.Success(result)
            } catch (e: Exception) {
                _healthState.value = UiState.Error(e.message ?: "Health check failed")
            }
        }
    }

    fun refreshNodes() {
        viewModelScope.launch {
            try {
                val result = repository.fetchNodes()
                _nodesState.value = UiState.Success(result.nodes)
            } catch (e: Exception) {
                if (_nodesState.value !is UiState.Success) {
                    _nodesState.value = UiState.Error(e.message ?: "Failed to fetch nodes")
                }
            }
        }
    }

    fun refreshZones() {
        viewModelScope.launch {
            try {
                val result = repository.fetchZones()
                _zonesState.value = UiState.Success(result)
            } catch (e: Exception) {
                if (_zonesState.value !is UiState.Success) {
                    _zonesState.value = UiState.Error(e.message ?: "Failed to fetch zones")
                }
            }
        }
    }

    fun pollCalibrationStatus() {
        viewModelScope.launch {
            _calibrationState.value = UiState.Loading
            try {
                val result = repository.fetchCalibrationStatus()
                _calibrationState.value = UiState.Success(result)
            } catch (e: Exception) {
                _calibrationState.value = UiState.Error(e.message ?: "Failed to fetch calibration status")
            }
        }
    }

    fun startCalibration() {
        viewModelScope.launch {
            try {
                repository.startCalibration()
                pollCalibrationStatus()
            } catch (e: Exception) {
                _calibrationState.value = UiState.Error(e.message ?: "Failed to start calibration")
            }
        }
    }

    fun stopCalibration() {
        viewModelScope.launch {
            try {
                repository.stopCalibration()
                _calibrationState.value = UiState.Idle
            } catch (e: Exception) {
                _calibrationState.value = UiState.Error(e.message ?: "Failed to stop calibration")
            }
        }
    }

    fun startRecording(name: String) {
        viewModelScope.launch {
            _recordingState.value = UiState.Loading
            try {
                val result = repository.startRecording(name)
                _recordingState.value = UiState.Success(result)
            } catch (e: Exception) {
                _recordingState.value = UiState.Error(e.message ?: "Failed to start recording")
            }
        }
    }

    fun stopRecording() {
        viewModelScope.launch {
            try {
                repository.stopRecording()
                _recordingState.value = UiState.Idle
            } catch (e: Exception) {
                _recordingState.value = UiState.Error(e.message ?: "Failed to stop recording")
            }
        }
    }

    fun retrainClassifier() {
        viewModelScope.launch {
            _trainState.value = UiState.Loading
            try {
                val result = repository.retrainClassifier()
                _trainState.value = UiState.Success(result)
            } catch (e: Exception) {
                _trainState.value = UiState.Error(e.message ?: "Training failed")
            }
        }
    }

    fun setGroundTruth(count: Int) {
        viewModelScope.launch {
            _groundTruthState.value = UiState.Loading
            try {
                val result = repository.setGroundTruth(count)
                _groundTruthState.value = UiState.Success(result)
            } catch (e: Exception) {
                _groundTruthState.value = UiState.Error(e.message ?: "Failed to set ground truth")
            }
        }
    }

    fun fetchAdaptiveStatus() {
        viewModelScope.launch {
            _adaptiveState.value = UiState.Loading
            try {
                val result = repository.fetchAdaptiveStatus()
                _adaptiveState.value = UiState.Success(result)
            } catch (e: Exception) {
                _adaptiveState.value = UiState.Error(e.message ?: "Failed to fetch adaptive status")
            }
        }
    }

    fun resetTrainState() {
        _trainState.value = UiState.Idle
    }

    fun resetGroundTruthState() {
        _groundTruthState.value = UiState.Idle
    }
}

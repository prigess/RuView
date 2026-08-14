package com.ruview.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

class RuViewRepository private constructor() {

    companion object {
        @Volatile
        private var instance: RuViewRepository? = null

        fun getInstance(): RuViewRepository =
            instance ?: synchronized(this) {
                instance ?: RuViewRepository().also { instance = it }
            }

        private const val WS_PORT = 3023
        private const val HTTP_PORT = 3022
        private const val MAX_BACKOFF_MS = 30_000L
        private const val INITIAL_BACKOFF_MS = 1_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    private val _latestSnapshot = MutableStateFlow<SensingSnapshot?>(null)
    val latestSnapshot: StateFlow<SensingSnapshot?> = _latestSnapshot.asStateFlow()

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected.asStateFlow()

    private val _connectionError = MutableStateFlow<String?>(null)
    val connectionError: StateFlow<String?> = _connectionError.asStateFlow()

    private var currentHost: String? = null
    private var webSocket: WebSocket? = null
    private var reconnectJob: kotlinx.coroutines.Job? = null
    private var backoffMs = INITIAL_BACKOFF_MS
    private var shouldReconnect = false

    fun connect(host: String) {
        if (currentHost == host && _isConnected.value) return
        disconnect()
        currentHost = host
        shouldReconnect = true
        backoffMs = INITIAL_BACKOFF_MS
        openWebSocket(host)
    }

    fun disconnect() {
        shouldReconnect = false
        reconnectJob?.cancel()
        reconnectJob = null
        webSocket?.close(1000, "User disconnected")
        webSocket = null
        _isConnected.value = false
        _latestSnapshot.value = null
        currentHost = null
    }

    private fun openWebSocket(host: String) {
        val url = "ws://$host:$WS_PORT/ws/sensing"
        val request = Request.Builder().url(url).build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                _isConnected.value = true
                _connectionError.value = null
                backoffMs = INITIAL_BACKOFF_MS
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val snapshot = json.decodeFromString<SensingSnapshot>(text)
                    _latestSnapshot.value = snapshot
                } catch (e: Exception) {
                    // Silently ignore parse errors for individual frames
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                _isConnected.value = false
                if (shouldReconnect && currentHost != null) {
                    scheduleReconnect(currentHost!!)
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                _isConnected.value = false
                _connectionError.value = t.message ?: "Connection failed"
                if (shouldReconnect && currentHost != null) {
                    scheduleReconnect(currentHost!!)
                }
            }
        })
    }

    private fun scheduleReconnect(host: String) {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(backoffMs)
            backoffMs = minOf(backoffMs * 2, MAX_BACKOFF_MS)
            if (shouldReconnect && currentHost == host) {
                openWebSocket(host)
            }
        }
    }

    private fun baseUrl(): String {
        val host = currentHost ?: throw IllegalStateException("Not connected to any host")
        return "http://$host:$HTTP_PORT"
    }

    suspend fun fetchHealth(): HealthResponse {
        return getRequest("/health")
    }

    suspend fun fetchHealth(host: String): HealthResponse {
        val url = "http://$host:$HTTP_PORT/health"
        return getRequestFromUrl(url)
    }

    suspend fun fetchNodes(): NodesResponse {
        return getRequest("/api/v1/nodes")
    }

    suspend fun fetchZones(): ZoneSummary {
        return getRequest("/api/v1/pose/zones/summary")
    }

    suspend fun fetchAdaptiveStatus(): AdaptiveStatus {
        return getRequest("/api/v1/adaptive/status")
    }

    suspend fun fetchCalibrationStatus(): CalibrationStatus {
        return getRequest("/api/v1/calibration/status")
    }

    suspend fun startCalibration(): StartCalibrationResponse {
        return postRequest("/api/v1/calibration/start", "{}")
    }

    suspend fun stopCalibration(): StopCalibrationResponse {
        return postRequest("/api/v1/calibration/stop", "{}")
    }

    suspend fun startRecording(name: String): StartRecordingResponse {
        val body = json.encodeToString(StartRecordingRequest(name))
        return postRequest("/api/v1/recording/start", body)
    }

    suspend fun stopRecording(): StopRecordingResponse {
        return postRequest("/api/v1/recording/stop", "{}")
    }

    suspend fun retrainClassifier(): TrainResponse {
        return postRequest("/api/v1/adaptive/train", "{}")
    }

    suspend fun setGroundTruth(count: Int): GroundTruthResponse {
        val body = json.encodeToString(GroundTruthRequest(count))
        return postRequest("/api/v1/config/ground-truth", body)
    }

    private suspend inline fun <reified T> getRequest(path: String): T {
        val url = "${baseUrl()}$path"
        return getRequestFromUrl(url)
    }

    private suspend inline fun <reified T> getRequestFromUrl(url: String): T =
        suspendCoroutine { continuation ->
            val request = Request.Builder().url(url).get().build()
            client.newCall(request).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        val body = response.body?.string()
                            ?: throw IOException("Empty response body")
                        if (!response.isSuccessful) {
                            throw IOException("HTTP ${response.code}: $body")
                        }
                        val result = json.decodeFromString<T>(body)
                        continuation.resume(result)
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }
                }
            })
        }

    private suspend inline fun <reified T> postRequest(path: String, bodyJson: String): T =
        suspendCoroutine { continuation ->
            val mediaType = "application/json; charset=utf-8".toMediaType()
            val requestBody = bodyJson.toRequestBody(mediaType)
            val request = Request.Builder()
                .url("${baseUrl()}$path")
                .post(requestBody)
                .build()

            client.newCall(request).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        val body = response.body?.string()
                            ?: throw IOException("Empty response body")
                        if (!response.isSuccessful) {
                            throw IOException("HTTP ${response.code}: $body")
                        }
                        val result = json.decodeFromString<T>(body)
                        continuation.resume(result)
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }
                }
            })
        }
}

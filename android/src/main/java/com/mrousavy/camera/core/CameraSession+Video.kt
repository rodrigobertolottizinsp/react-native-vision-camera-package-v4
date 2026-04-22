package com.mrousavy.camera.core

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.util.Log
import android.util.Size
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.camera.video.ExperimentalPersistentRecording
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.VideoRecordEvent
import androidx.core.app.ActivityCompat
import com.mrousavy.camera.core.extensions.getCameraError
import com.mrousavy.camera.core.types.RecordVideoOptions
import com.mrousavy.camera.core.types.Video
import okhttp3.internal.and
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sqrt
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.StorageService

//private val accelerometerData = mutableListOf<FloatArray>() // Shared list for accelerometer data
private val accelerometerData = CopyOnWriteArrayList<FloatArray>()

//new
private var audioRecord: AudioRecord? = null
private var audioThread: Thread? = null
private var isAudioRecording = false
//end new

private var voskModel: Model? = null
private var voskRecognizer: Recognizer? = null


data class AudioChunkState(
        var audioChunkFile: File? = null,
        var audioChunkCounter: Int = 0,
        var muxer: MediaMuxer? = null,
        var aacCodec: MediaCodec? = null,
        var muxerStarted: Boolean = false,
        var trackIndex: Int = -1,
        var silence: Boolean = true,
        var lastSilence: Boolean = true,
        var silenceInterval: Int = 0
)

private fun safeStopAndRelease(audioState: AudioChunkState) {
    synchronized(audioState) {
        // Stop & release codec safely
        audioState.aacCodec?.let { codec ->
            try {
                codec.stop()
            } catch (e: IllegalStateException) {
                Log.w("AudioState", "Codec already stopped: ${e.message}")
            } catch (e: Exception) {
                Log.w("AudioState", "Codec stop error: ${e.message}")
            } finally {
                try {
                    codec.release()
                } catch (e: Exception) {
                    Log.w("AudioState", "Codec release error: ${e.message}")
                }
                audioState.aacCodec = null
            }
        }

        // Stop & release muxer safely
        audioState.muxer?.let { muxer ->
            if (audioState.muxerStarted) {
                try {
                    muxer.stop()
                } catch (e: IllegalStateException) {
                    Log.w("AudioState", "Muxer already stopped: ${e.message}")
                } catch (e: Exception) {
                    Log.w("AudioState", "Muxer stop error: ${e.message}")
                } finally {
                    audioState.muxerStarted = false
                }
            }
            try {
                muxer.release()
            } catch (e: Exception) {
                Log.w("AudioState", "Muxer release error: ${e.message}")
            } finally {
                audioState.muxer = null
                audioState.trackIndex = -1
            }
        }
    }
}


@OptIn(ExperimentalPersistentRecording::class)
@SuppressLint("MissingPermission", "RestrictedApi")
fun CameraSession.startRecording(
        enableAudio: Boolean,
        options: RecordVideoOptions,
        callback: (video: Video) -> Unit,
        onError: (error: CameraError) -> Unit,
        enableMotionAware: Boolean,
        onLoudness: ((String, Int, Int) -> Unit)? = null,
        onMotionChanged: ((String) -> Unit)? = null,
        onSteadyMovementChanged: ((Number) -> Unit)? = null,
        onTranscribedTextChanged: ((String) -> Unit)? = null,
) {
    if (camera == null) throw CameraNotReadyError()
    if (recording != null) throw RecordingInProgressError()
    val videoOutput = videoOutput ?: throw VideoNotEnabledError()
    val uniqueId = UUID.randomUUID().toString()

    val audioChunkState = AudioChunkState()

    if (options.zAssistMotionEnabled) {
        synchronized(accelerometerData) {
            accelerometerData.clear() // Clear previous session data
        }
    }
    // Create output video file
    val outputOptions = FileOutputOptions.Builder(options.file.file).also { outputOptions ->
        metadataProvider.location?.let { location ->
            Log.i(CameraSession.TAG, "Setting Video Location to ${location.latitude}, ${location.longitude}...")
            outputOptions.setLocation(location)
        }
    }.build()
    // TODO: Move this to JS so users can prepare recordings earlier
    // Prepare recording
    var pendingRecording = videoOutput.output.prepareRecording(context, outputOptions)
    if (enableAudio) {
        checkMicrophonePermission()
        pendingRecording = pendingRecording.withAudioEnabled()
    }
    pendingRecording = pendingRecording.asPersistentRecording()

    isRecordingCanceled = false
    recording = pendingRecording.start(CameraQueues.cameraExecutor) { event ->
        when (event) {
            is VideoRecordEvent.Start -> {
                Log.i(CameraSession.TAG, "Recording started!")
                if (options.zAssistMotionEnabled) {
                    startAccelerometerListener(context, onMotionChanged, onSteadyMovementChanged)
                }
                if (enableMotionAware) {
                    val dir = File(context.filesDir, "chunks")
                    if (!dir.exists()) dir.mkdirs()

                    audioChunkState.audioChunkFile = File(dir, "${uniqueId}-chunk-${audioChunkState.audioChunkCounter++}.m4a")
                    audioChunkState.muxer = MediaMuxer(audioChunkState.audioChunkFile!!.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                    audioChunkState.muxerStarted = false
                    audioChunkState.trackIndex = -1

                    audioChunkState.aacCodec = MediaCodec.createEncoderByType("audio/mp4a-latm")
                    val format = MediaFormat.createAudioFormat("audio/mp4a-latm", 16000, 1)
                    format.setInteger(MediaFormat.KEY_BIT_RATE, 64000)
                    format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
                    audioChunkState.aacCodec?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    audioChunkState.aacCodec?.start()
                    startAudioLoudnessDetection(
                            context,
                            uniqueId,
                            audioChunkState,
                            { path, chunkCount, totalChunks ->
                                onLoudness?.invoke(path, chunkCount, totalChunks)
                            },
                            { text ->
                                if (onTranscribedTextChanged != null) {
                                    onTranscribedTextChanged?.invoke(text)
                                }
                            }
                    )
                }
            }

            is VideoRecordEvent.Resume -> Log.i(CameraSession.TAG, "Recording resumed!")

            is VideoRecordEvent.Pause -> Log.i(CameraSession.TAG, "Recording paused!")

            is VideoRecordEvent.Status -> Log.i(CameraSession.TAG, "Status update! Recorded ${event.recordingStats.numBytesRecorded} bytes.")

            is VideoRecordEvent.Finalize -> {
                if (enableMotionAware) {
                    if (audioChunkState.aacCodec != null) {
                        audioChunkState.aacCodec?.stop()
                        audioChunkState.aacCodec?.release()
                        audioChunkState.aacCodec = null

//                        if (audioChunkState.muxerStarted) {
//                            audioChunkState.muxer?.stop()
//                        }
                        safeStopAndRelease(audioChunkState)

                        audioChunkState.muxer?.release()
                        audioChunkState.muxer = null
                        audioChunkState.muxerStarted = false
                        audioChunkState.trackIndex = -1

                        val path = audioChunkState.audioChunkFile?.absolutePath

                        if (path != null) {
                            onLoudness?.invoke(path, audioChunkState.audioChunkCounter, audioChunkState.audioChunkCounter)
                        }
                        audioChunkState.audioChunkFile = null
                    }
                    stopAudioLoudnessDetection()
                    stopAccelerometerListener()

                }
                if (isRecordingCanceled) {
                    Log.i(CameraSession.TAG, "Recording was canceled, deleting file..")
                    onError(RecordingCanceledError())
                    try {
                        options.file.file.delete()
                    } catch (e: Throwable) {
                        this.callback.onError(FileIOError(e))
                    }
                    return@start
                }

                Log.i(CameraSession.TAG, "Recording stopped!")

                if (options.zAssistMotionEnabled) {
                    stopAccelerometerListener()
                }

                val error = event.getCameraError()
                if (error != null) {
                    if (error.wasVideoRecorded) {
                        Log.e(CameraSession.TAG, "Video Recorder encountered an error, but the video was recorded anyways.", error)
                    } else {
                        Log.e(CameraSession.TAG, "Video Recorder encountered a fatal error!", error)
                        onError(error)
                        return@start
                    }
                }

                // Prepare output result
                val durationMs = event.recordingStats.recordedDurationNanos / 1_000_000
                val path = event.outputResults.outputUri.path
                        ?: throw UnknownRecorderError(false, null)
                val size = videoOutput.attachedSurfaceResolution ?: Size(0, 0)

                val video = Video(path, durationMs, size, accelerometerData)
                callback(video)
            }
        }
    }
}

private var accelerometerListener: SensorEventListener? = null
private var sensorManager: SensorManager? = null
private var handler: Handler? = null
private var isRecording = false
private var startTime: Long = 0L

private val imuWindow = ArrayDeque<FloatArray>() // [xa, ya, za, xg, yg, zg]
private val windowSize = 5 * 5
private var lastMotionClassification: String? = null
private var movingTime: Double? = null
private var unsteadyTime: Double? = null
private var panningTime: Double? = null

private var accRotation = FloatArray(3) { 0f } // x, y, z
val accRotationThresholdDeg = 25f
val accRotationThresholdRad = Math.toRadians(accRotationThresholdDeg.toDouble()).toFloat()
private var lastSensorTimestamp: Long = 0L
private var onSteadyMovementChanged: ((Map<String, Any>) -> Unit)? = null
private var accRotationMagnitude = 0
private val sentWords = mutableSetOf<String>() // track sent words

private fun initializeVoskSafely(context: Context): Boolean {
    if (voskModel != null && voskRecognizer != null) return true

    try {
        // Unpack model (this can throw or fail silently on bad devices)
        StorageService.unpack(
                context,
                "vosk-model-small-en-us-0.15",
                "model",
                { unpackedModel ->
                    try {
                        voskModel = unpackedModel
                        // Final safety: try creating recognizer separately
                        voskRecognizer = Recognizer(voskModel, 16000.0f)
                        Log.i("VOSK", "Vosk initialized successfully")
                        true
                    } catch (e: Throwable) {  // Catch everything – UnsatisfiedLinkError, RuntimeException, etc.
                        Log.e("VOSK", "Failed to create Recognizer: ${e.message}", e)
                        voskModel = null
                        voskRecognizer = null
                        false
                    }
                },
                { error ->
                    Log.e("VOSK", "Model unpack failed: ${error.message}", error)
                    voskModel = null
                    voskRecognizer = null
                }
        )
        // Give a short grace period if unpack is async – but in practice just return success if no immediate crash
        return voskRecognizer != null
    } catch (e: Throwable) {
        Log.e("VOSK", "Critical Vosk init failure – disabling speech: ${e.message}", e)
        voskModel = null
        voskRecognizer = null
        return false
    }
}

private fun calculateLoudness(buffer: ShortArray, readSize: Int): Pair<Float, Boolean> {
    var sum = 0f
    for (i in 0 until readSize) {
        sum += buffer[i] * buffer[i]
    }

    val rms = kotlin.math.sqrt(sum / readSize)
    val reference = 2000.0f
    if (rms <= 0f) return -60f to false

    val db = 20f * kotlin.math.log10(rms / reference)
    val isTalking = db > -5f // You can adjust this threshold

    return db to isTalking
}

fun downsampleTo16kHz(input: ShortArray, inputRate: Int = 44100): ShortArray {
    val factor = inputRate / 16000
    return ShortArray(input.size / factor) { i ->
        input[i * factor]
    }
}

private fun startAudioLoudnessDetection(
        context: Context,
        fileUUID: String,
        audioState: AudioChunkState,
        onLoudnessDetected: (path: String, chunkCount: Int, totalChunks: Int) -> Unit,
        onTranscribedTextChanged: (text: String) -> Unit
) {
    // Step 1: Try to safely initialize Vosk (new helper function)
    val voskReady = initializeVoskSafely(context)

    if (!voskReady) {
        Log.w("VOSK", "Speech recognition disabled due to initialization failure on this device. " +
                "Loudness detection and audio chunking will continue normally.")
        // Optional: You could notify your UI/JS layer here if desired
        // onTranscribedTextChanged?.invoke("[Speech recognition unavailable]")
    }

    val sampleRate = 16000
    val bufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
    )

    if (ActivityCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
        Log.w("Audio", "RECORD_AUDIO permission not granted — skipping audio processing")
        return
    }

    audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
    )

    isAudioRecording = true
    audioRecord?.startRecording()

    audioThread = Thread {
        val buffer = ShortArray(bufferSize)
        while (isAudioRecording) {
            val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
            if (read > 0) {
                val (db, isTalking) = calculateLoudness(buffer, read)

                // Vosk recognition part (already guarded)
                try {
                    if (read > 0) {
                        val recognizer = voskRecognizer
                        if (recognizer == null) {
                            Log.w("VOSK", "Recognizer not initialized — skipping recognition frame.")
                        } else {
                            try {
                                val bytes = ByteArray(read * 2)
                                for (i in 0 until read) {
                                    bytes[i * 2] = (buffer[i].toInt() and 0xFF).toByte()
                                    bytes[i * 2 + 1] = ((buffer[i].toInt() shr 8) and 0xFF).toByte()
                                }

                                if (recognizer.acceptWaveForm(bytes, bytes.size)) {
                                    // Final result
                                    val finalResult = recognizer.result
                                    val text = JSONObject(finalResult).optString("text", "").trim()
                                    if (text.isNotEmpty()) {
                                        val filteredText = text.split("\\s+".toRegex())
                                                .filter { it !in sentWords }
                                                .joinToString(" ")

                                        if (filteredText.isNotEmpty()) {
                                            onTranscribedTextChanged(filteredText)
                                        }

                                        sentWords.clear()
                                    }
                                } else {
                                    // Partial result
                                    val partialText = JSONObject(recognizer.partialResult).optString("partial", "").trim()
                                    if (partialText.isNotEmpty()) {
                                        val partialWords = partialText.split("\\s+".toRegex())
                                        val newWords = partialWords.filter { it !in sentWords }

                                        if (newWords.isNotEmpty()) {
                                            sentWords.addAll(newWords)
                                            onTranscribedTextChanged(newWords.joinToString(" "))
                                        }
                                    }
                                }
                            } catch (e: Throwable) {
                                Log.e("VOSK", "Error during recognition: ${e.message}", e)
                                // Extra safety: disable Vosk for the rest of this session if it crashes here
                                voskRecognizer = null
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e("VOSK", "Unexpected error processing audio chunk: ${e.message}", e)
                }

                // Silence detection and chunk management (unchanged)
                if (!isTalking) {
                    audioState.silenceInterval++
                } else {
                    audioState.silenceInterval = 0
                    audioState.silence = false
                }
                if (audioState.silenceInterval > 30) {
                    audioState.silence = true
                }

                if (audioState.lastSilence != audioState.silence) {
                    if (audioState.silence) {
                        // Silence detected: finalize chunk
                        audioState.aacCodec?.let {
                            try { it.stop() } catch (_: Exception) {}
                            try { it.release() } catch (_: Exception) {}
                        }
                        audioState.aacCodec = null

                        safeStopAndRelease(audioState)

                        audioState.muxer?.release()
                        audioState.muxer = null
                        audioState.muxerStarted = false
                        audioState.trackIndex = -1

                        val path = audioState.audioChunkFile?.absolutePath
                        if (path != null) {
                            onLoudnessDetected(path, audioState.audioChunkCounter, -1)
                        } else {
                            Log.i("AudioChunk", "Error. Null path.")
                        }

                        audioState.audioChunkFile = null

                        // Start new audio chunk
                        val dir = File(context.filesDir, "chunks")
                        if (!dir.exists()) dir.mkdirs()

                        audioState.audioChunkFile = File(dir, "${fileUUID}-chunk-${audioState.audioChunkCounter++}.m4a")
                        audioState.muxer = MediaMuxer(audioState.audioChunkFile!!.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                        audioState.muxerStarted = false
                        audioState.trackIndex = -1

                        audioState.aacCodec = MediaCodec.createEncoderByType("audio/mp4a-latm")
                        val format = MediaFormat.createAudioFormat("audio/mp4a-latm", sampleRate, 1)
                        format.setInteger(MediaFormat.KEY_BIT_RATE, 64000)
                        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
                        audioState.aacCodec?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                        audioState.aacCodec?.start()
                    } else {
                        // Talking resumes
                        onLoudnessDetected("", -1, -1)
                    }
                    audioState.lastSilence = audioState.silence
                }

                // AAC encoding (unchanged, but already has try-catch in your original)
                if (audioState.aacCodec != null) {
                    try {
                        val byteBuffer = ByteArray(read * 2)
                        for (i in 0 until read) {
                            byteBuffer[i * 2] = (buffer[i].toInt() and 0xFF).toByte()
                            byteBuffer[i * 2 + 1] = ((buffer[i].toInt() shr 8) and 0xFF).toByte()
                        }

                        val inputIndex = audioState.aacCodec!!.dequeueInputBuffer(0)
                        if (inputIndex >= 0) {
                            val inputBuf = audioState.aacCodec!!.getInputBuffer(inputIndex)!!
                            inputBuf.clear()
                            inputBuf.put(byteBuffer)
                            audioState.aacCodec!!.queueInputBuffer(inputIndex, 0, byteBuffer.size, System.nanoTime() / 1000, 0)
                        }

                        val bufferInfo = MediaCodec.BufferInfo()
                        var outputIndex = audioState.aacCodec!!.dequeueOutputBuffer(bufferInfo, 0)
                        while (outputIndex >= 0) {
                            val outBuf = audioState.aacCodec!!.getOutputBuffer(outputIndex)!!
                            val encodedData = ByteBuffer.allocate(bufferInfo.size)
                            encodedData.put(outBuf)
                            encodedData.flip()

                            if (audioState.muxer == null || audioState.aacCodec == null) {
                                Log.w("AudioThread", "Skipping frame — muxer or codec already released")
                                break
                            }

                            if (!audioState.muxerStarted) {
                                val format = audioState.aacCodec!!.outputFormat
                                audioState.trackIndex = audioState.muxer!!.addTrack(format)
                                audioState.muxer!!.start()
                                audioState.muxerStarted = true
                            }

                            audioState.muxer!!.writeSampleData(audioState.trackIndex, encodedData, bufferInfo)
                            audioState.aacCodec!!.releaseOutputBuffer(outputIndex, false)
                            outputIndex = audioState.aacCodec!!.dequeueOutputBuffer(bufferInfo, 0)
                        }
                    } catch (e: IllegalStateException) {
                        Log.e("AudioThread", "Attempted to use released codec: ${e.message}")
                        break  // Exit loop if codec is dead
                    } catch (e: Exception) {
                        Log.e("AudioThread", "Unexpected encoding error: ${e.message}", e)
                    }
                }
            }
        }
    }
    audioThread?.start()
}

private fun stopAudioLoudnessDetection() {
    isAudioRecording = false
    audioThread?.join() //NEW!! Test
    audioRecord?.stop()
    audioRecord?.release()
    audioRecord = null
    audioThread = null
}

private fun startAccelerometerListener(context: Context, onMotionChanged: ((String) -> Unit)?, onSteadyMovementChanged: ((Number) -> Unit)?) {
    if (sensorManager == null) {
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    if (handler == null) {
        handler = Handler(Looper.getMainLooper())
    }

    synchronized(accelerometerData) {
        accelerometerData.clear()
    }

    val accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    val gyroscope = sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

    lastMotionClassification = null

    startTime = System.currentTimeMillis()
    var currentZoomLevel = 1f
    var gyroscopeValues = FloatArray(3) { 0f }

    val intentFilter = IntentFilter("com.mrousavy.camera.ZOOM_UPDATED")
    val zoomReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getFloatExtra("zoomLevel", 1f)?.let {
                currentZoomLevel = it
            }
        }
    }

    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
        context.registerReceiver(zoomReceiver, intentFilter, Context.RECEIVER_NOT_EXPORTED)
    } else {
        context.registerReceiver(zoomReceiver, intentFilter)
    }

    accelerometerListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent?) {
            if (event == null) return

            when (event.sensor.type) {
                Sensor.TYPE_ACCELEROMETER -> {
                    val elapsedSeconds = ((System.currentTimeMillis() - startTime) / 1000f)
                    val formattedElapsedSeconds = String.format(Locale.US, "%.3f", elapsedSeconds).toFloat()

                    var forceMotionChange = false

                    val xa = event.values[0] / 9.80665f
                    val ya = event.values[1] / 9.80665f
                    val za = event.values[2] / 9.80665f

                    val xg = gyroscopeValues[0]
                    val yg = gyroscopeValues[1]
                    val zg = gyroscopeValues[2]

                    onMotionChanged?.let {
                        val now = System.currentTimeMillis()
                        //new
                        val deltaTimeSec = if (lastSensorTimestamp == 0L) 0.033f else (now - lastSensorTimestamp) / 1000f
                        lastSensorTimestamp = now

                        // Only update if we have valid gyro data
                        val logZoom = ln(currentZoomLevel.toDouble()).toFloat() + 1f
                        val xgAccRot = if (abs(xg) < 0.01) 0f else xg
                        val ygAccRot = if (abs(yg) < 0.01) 0f else yg
                        val zgAccRot = if (abs(zg) < 0.01) 0f else zg

                        accRotation[0] += xgAccRot * deltaTimeSec * logZoom
                        accRotation[1] += ygAccRot * deltaTimeSec * logZoom
                        accRotation[2] += zgAccRot * deltaTimeSec * logZoom


                        //end new
                        // Update IMU window
                        val imuSample = floatArrayOf(xa, ya, za, xg, yg, zg)
                        if (imuWindow.size >= windowSize) imuWindow.removeFirst()
                        imuWindow.addLast(imuSample)

                        // Motion classification
                        if (imuWindow.size == windowSize) {
                            var sum = FloatArray(6) { 0f }
                            for (sample in imuWindow) {
                                for (i in 0..5) {
                                    sum[i] += sample[i]
                                }
                            }

                            val avg = sum.map { it / windowSize }
                            val netAcc = sqrt(avg[0] * avg[0] + avg[1] * avg[1] + avg[2] * avg[2])
                            val netGyro = sqrt(avg[3] * avg[3] + avg[4] * avg[4] + avg[5] * avg[5])
                            val netGyroSingle = sqrt(xg * xg + yg * yg + zg * zg)

                            val accDev = abs(netAcc - 1.0)


                            var motion = when {
                                netGyro <= 0.15 -> "Steady"
                                netGyro <= 1.0 -> "Panning"
                                else -> "Unsteady"
                            }

                            if (motion == "Unsteady") {
                                unsteadyTime = System.currentTimeMillis().toDouble()
                            }

                            if (motion == "Panning") {
                                panningTime = System.currentTimeMillis().toDouble()
                                if (lastMotionClassification == "Steady" && accRotationMagnitude > accRotationThresholdRad){
                                    motion = "Steady"
                                    forceMotionChange = true
                                }
                            }

                            if (motion == "Steady" && accDev > 0.03) {
                                if (accDev < 0.1) {
                                    motion = "Moving"
                                    movingTime = System.currentTimeMillis().toDouble()
                                } else {
                                    motion = "Unsteady"
                                    unsteadyTime = System.currentTimeMillis().toDouble()
                                }
                            }

                            //new
                            if (motion == "Steady") {
                                val magnitude = sqrt(accRotation[0].pow(2) + accRotation[1].pow(2) + accRotation[2].pow(2))
                                accRotationMagnitude = magnitude.toInt()
                                if (magnitude > accRotationThresholdRad) {
//                                    onSteadyMovementChanged?.invoke((now / 1000.0).toInt())
                                    forceMotionChange = true
                                    accRotation = FloatArray(3) { 0f }
                                    accRotationMagnitude = 0
                                }
                            }
                            //end new

                            var inertia = false

//                        if ((motion == "Steady" || motion == "Panning" || motion == "Moving") && (lastMotionClassification == "Moving" || lastMotionClassification == "Unsteady")) {
                            if (movingTime != null) {
                                val inertiaTime = System.currentTimeMillis() - movingTime!!
                                inertia = (lastMotionClassification == "Moving") && (inertiaTime < 1000.0)
                            }

                            if (unsteadyTime != null) {
                                val inertiaTime = System.currentTimeMillis() - unsteadyTime!!
                                inertia = inertia || ((lastMotionClassification == "Unsteady") && (inertiaTime < 1000.0))
                            }

                            if (panningTime != null) {
                                val inertiaTime = System.currentTimeMillis() - panningTime!!
                                inertia = inertia || ((lastMotionClassification == "Panning") && (inertiaTime < 1000.0))
                            }

//                        }

                            if ((motion == "Steady" || motion == "Panning" || motion == "Moving") && inertia) {
                                motion = lastMotionClassification.toString()
                            }

                            if (motion != lastMotionClassification || forceMotionChange) {
                                accRotation = FloatArray(3) { 0f }  // <--- Add this
                                lastMotionClassification = motion

                                onMotionChanged?.invoke(motion)
                            }
                        }
                    }
                    // Still store the raw data if needed
                    val valuesList = mutableListOf(formattedElapsedSeconds)
                    valuesList.addAll(listOf(xa, ya, za, xg, yg, zg, currentZoomLevel))

                    handler?.postDelayed({
                        synchronized(accelerometerData) {
                            accelerometerData.add(valuesList.toFloatArray())
                        }
                    }, 33)
                }

                Sensor.TYPE_GYROSCOPE -> {
                    gyroscopeValues = event.values.copyOf()
                }
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
            // no-op
        }
    }

    accelerometer?.let {
        sensorManager?.registerListener(accelerometerListener, it, SensorManager.SENSOR_DELAY_UI)
    }
    gyroscope?.let {
        sensorManager?.registerListener(accelerometerListener, it, SensorManager.SENSOR_DELAY_UI)
    }
}
private fun stopAccelerometerListener() {
    sensorManager?.unregisterListener(accelerometerListener)
    accelerometerListener = null
    sensorManager = null
    handler = null
}

fun CameraSession.stopRecording() {
    val recording = recording ?: throw NoRecordingInProgressError()
    recording.stop()
    this.recording = null
}

fun CameraSession.cancelRecording() {
    isRecordingCanceled = true
    stopRecording()
}

fun CameraSession.pauseRecording() {
    val recording = recording ?: throw NoRecordingInProgressError()
    recording.pause()
}

fun CameraSession.resumeRecording() {
    val recording = recording ?: throw NoRecordingInProgressError()
    recording.resume()
}


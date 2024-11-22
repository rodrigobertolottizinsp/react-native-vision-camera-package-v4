package com.mrousavy.camera.core

import android.annotation.SuppressLint
import android.util.Log
import android.util.Size
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.camera.video.ExperimentalPersistentRecording
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.VideoRecordEvent
import com.mrousavy.camera.core.extensions.getCameraError
import com.mrousavy.camera.core.types.RecordVideoOptions
import com.mrousavy.camera.core.types.Video

private val accelerometerData = mutableListOf<FloatArray>() // Shared list for accelerometer data

@OptIn(ExperimentalPersistentRecording::class)
@SuppressLint("MissingPermission", "RestrictedApi")
fun CameraSession.startRecording(
  enableAudio: Boolean,
  options: RecordVideoOptions,
  callback: (video: Video) -> Unit,
  onError: (error: CameraError) -> Unit
) {
  if (camera == null) throw CameraNotReadyError()
  if (recording != null) throw RecordingInProgressError()
  val videoOutput = videoOutput ?: throw VideoNotEnabledError()
    if (options.zAssistMotionEnabled){
    accelerometerData.clear() // Clear previous session data
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
              startAccelerometerListener(context)
          }
      }

      is VideoRecordEvent.Resume -> Log.i(CameraSession.TAG, "Recording resumed!")

      is VideoRecordEvent.Pause -> Log.i(CameraSession.TAG, "Recording paused!")

      is VideoRecordEvent.Status -> Log.i(CameraSession.TAG, "Status update! Recorded ${event.recordingStats.numBytesRecorded} bytes.")

      is VideoRecordEvent.Finalize -> {
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
        Log.i(CameraSession.TAG, "Successfully completed video recording! Captured ${durationMs.toDouble() / 1_000.0} seconds.")
        val path = event.outputResults.outputUri.path ?: throw UnknownRecorderError(false, null)
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

private fun startAccelerometerListener(context: Context) {
    // Initialize the sensor manager and handler
    if (sensorManager == null) {
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    if (handler == null) {
        handler = Handler(Looper.getMainLooper())
    }
    accelerometerData.clear()

    val accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    val gyroscope = sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    startTime = System.currentTimeMillis()

    var gyroscopeValues = FloatArray(3) { 0f }

    // The listener to handle accelerometer events
    accelerometerListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent?) {
            if (event != null) {
                when (event.sensor.type) {
                    Sensor.TYPE_ACCELEROMETER -> {
                        val elapsedSeconds = ((System.currentTimeMillis() - startTime) / 1000f)
                        val formattedElapsedSeconds = String.format("%.3f", elapsedSeconds).toFloat()
                        val valuesList = mutableListOf(formattedElapsedSeconds)

                        // Add converted accelerometer data
                        valuesList.addAll(event.values.map { it / 9.80665f })

                        // Add gyroscope data
                        valuesList.addAll(gyroscopeValues.map { it })

                        // Add a constant value (1f)
                        valuesList.add(1f)

                        handler?.postDelayed({
                            accelerometerData.add(valuesList.toFloatArray())
                        }, 33)
                    }
                    Sensor.TYPE_GYROSCOPE -> {
                        // Update gyroscopeValues with the latest data
                        gyroscopeValues = event.values.copyOf()
                    }
                }
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
            // Handle accuracy changes (if needed)
        }
    }

    // Register the listeners with a rate of 250ms
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

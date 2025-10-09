package com.mrousavy.camera.react

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.ReactContext
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.mrousavy.camera.core.CameraError
import com.mrousavy.camera.core.MicrophonePermissionError
import com.mrousavy.camera.core.MicrophoneUnavailableError
import com.mrousavy.camera.core.cancelRecording
import com.mrousavy.camera.core.pauseRecording
import com.mrousavy.camera.core.resumeRecording
import com.mrousavy.camera.core.startRecording
import com.mrousavy.camera.core.stopRecording
import com.mrousavy.camera.core.types.RecordVideoOptions
import com.mrousavy.camera.core.types.Video
import com.mrousavy.camera.react.utils.makeErrorMap
import java.util.concurrent.atomic.AtomicLong

fun CameraView.startRecording(options: RecordVideoOptions, onRecordCallback: Callback) {
  // check audio permission
  if (audio) {
    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      throw MicrophonePermissionError()
    }
  }

  // Check if the microphone is available
  if (!isMicrophoneAvailable(context)) {
    throw MicrophoneUnavailableError()
    return
  }

  // Throttle loudness events to every 100ms
  val lastLoudnessEvent = AtomicLong(0)
  val loudnessEventInterval = 100 // 100ms in milliseconds

  val loudnessCallback = loudnessCallback@{ loudness: Double ->
    val now = System.currentTimeMillis()
    if (now - lastLoudnessEvent.get() < loudnessEventInterval) {
      return@loudnessCallback // Skip if too soon
    }
    lastLoudnessEvent.set(now)

    // Emit event to JavaScript
    val reactContext = context as ReactContext
    val event = Arguments.createMap().apply {
      putDouble("db", loudness)
    }

    reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("onAudioLoudness", event)
  }

  val callback = { video: Video ->
    val map = Arguments.createMap()
    map.putString("path", video.path)
    map.putDouble("duration", video.durationMs.toDouble() / 1000.0)
    map.putInt("width", video.size.width)
    map.putInt("height", video.size.height)
    // Convert MutableList<FloatArray> to WritableArray
    val histogramArray = Arguments.createArray()
    video.accelerometer_histogram.forEach { floatArray ->
      val innerArray = Arguments.createArray()
      floatArray.forEach { value ->
        innerArray.pushDouble(value.toDouble()) // Convert Float to Double for React Native compatibility
      }
      histogramArray.pushArray(innerArray)
    }
    map.putArray("accelerometer_histogram", histogramArray) // Add the array to the map
    onRecordCallback(map, null)
  }
  val onError = { error: CameraError ->
    val errorMap = makeErrorMap(error.code, error.message)
    onRecordCallback(null, errorMap)
  }

  val onMicInput = { db: String, chunkCount: Int, totalChunks: Int  ->
    onMicInputChanged(db, chunkCount, totalChunks)
  }

  val onMotion = { motion: String ->
    onMotionChanged(motion)
  }

  val onSteadyMovement = { timestamp: Number ->
    onSteadyMovementChanged(timestamp)
  }

  val onTranscribedTextChanged = { text: String ->
    onTranscribedTextChanged(text)
  }

  cameraSession.startRecording(audio, options, callback, onError, enableMotionAware, onMicInput, onMotion, onSteadyMovement, onTranscribedTextChanged)
}

fun isMicrophoneAvailable(context: Context): Boolean {
  val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
    !audioManager.isMicrophoneMute
  } else {
    // For devices running versions lower than Marshmallow
    true // Assume microphone is available
  }
}

fun CameraView.pauseRecording() {
  cameraSession.pauseRecording()
}

fun CameraView.resumeRecording() {
  cameraSession.resumeRecording()
}

fun CameraView.stopRecording() {
  cameraSession.stopRecording()
}

fun CameraView.cancelRecording() {
  cameraSession.cancelRecording()
}

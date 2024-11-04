package com.mrousavy.camera.core.extensions

import android.annotation.SuppressLint
import android.media.MediaActionSound
import android.util.Log
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCapture.OutputFileOptions
import androidx.camera.core.ImageCaptureException
import androidx.exifinterface.media.ExifInterface
import com.mrousavy.camera.core.CameraSession
import com.mrousavy.camera.core.MetadataProvider
import com.mrousavy.camera.core.types.ShutterType
import java.io.File
import java.net.URI
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okio.IOException

data class PhotoFileInfo(val uri: URI, val metadata: ImageCapture.Metadata)

@SuppressLint("RestrictedApi")
suspend inline fun ImageCapture.takePicture(
  file: File,
  isMirrored: Boolean,
  enableShutterSound: Boolean,
  metadataProvider: MetadataProvider,
  callback: CameraSession.Callback,
  executor: Executor,
  userComments: String,
  deviceString: String,
  software: String,
  latitude: Number,
  longitude: Number
): PhotoFileInfo =
  suspendCancellableCoroutine { continuation ->
    // Shutter sound
    val shutterSound = if (enableShutterSound) MediaActionSound() else null
    shutterSound?.load(MediaActionSound.SHUTTER_CLICK)

    // Create output file
    val outputFileOptionsBuilder = OutputFileOptions.Builder(file).also { options ->
      val metadata = ImageCapture.Metadata()
      metadataProvider.location?.let { location ->
        Log.i("ImageCapture", "Setting Photo Location to ${location.latitude}, ${location.longitude}...")
        metadata.location = metadataProvider.location
      }
      metadata.isReversedHorizontal = isMirrored
      options.setMetadata(metadata)
    }
    val outputFileOptions = outputFileOptionsBuilder.build()

    // Take a photo with callbacks
    takePicture(
      outputFileOptions,
      executor,
      object : ImageCapture.OnImageSavedCallback {
        override fun onCaptureStarted() {
          super.onCaptureStarted()
          if (enableShutterSound) {
            shutterSound?.play(MediaActionSound.SHUTTER_CLICK)
          }

          callback.onShutter(ShutterType.PHOTO)
        }

        @SuppressLint("RestrictedApi")
        override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
          if (continuation.isActive) {
              try {
                  val exif = ExifInterface(file)
                  userComments.let { exif.setAttribute(ExifInterface.TAG_USER_COMMENT, it) }
                  deviceString.let { exif.setAttribute(ExifInterface.TAG_ARTIST, it) }
                  software.let { exif.setAttribute(ExifInterface.TAG_SOFTWARE, it) }
                  // Set GPS Latitude and Longitude
                  exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE, convertToDMS(latitude.toDouble()))
                  exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, if (latitude.toInt() >= 0) "N" else "S")
                  exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE, convertToDMS(longitude.toDouble()))
                  exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, if (longitude.toInt() >= 0) "E" else "W")
                  exif.saveAttributes()
              } catch (e: IOException) {
                  Log.e("ImageCapture", "Error writing Exif metadata", e)
              }
              val info = PhotoFileInfo(file.toURI(), outputFileOptions.metadata)
            continuation.resume(info)
          }
        }

          fun convertToDMS(coordinate: Double): String {
              val absolute = Math.abs(coordinate)
              val degrees = absolute.toInt()
              val minutes = ((absolute - degrees) * 60).toInt()
              val seconds = (((absolute - degrees) * 60 - minutes) * 60).toInt()
              return "$degrees/1,$minutes/1,$seconds/1"
          }

        override fun onError(exception: ImageCaptureException) {
          if (continuation.isActive) {
            continuation.resumeWithException(exception)
          }
        }
      }
    )
  }
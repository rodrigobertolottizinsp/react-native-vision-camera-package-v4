package com.mrousavy.camera.core.types

import android.content.Context
import com.facebook.react.bridge.ReadableMap
import com.mrousavy.camera.core.utils.FileUtils
import com.mrousavy.camera.core.utils.OutputFile

data class TakePhotoOptions(val file: OutputFile, val flash: Flash, val enableShutterSound: Boolean, val userComments: String, val artist: String, val software: String, val latitude: Number, val longitude: Number) {

  companion object {
    fun fromJS(context: Context, map: ReadableMap): TakePhotoOptions {
      val flash = if (map.hasKey("flash")) Flash.fromUnionValue(map.getString("flash")) else Flash.OFF
      val enableShutterSound = if (map.hasKey("enableShutterSound")) map.getBoolean("enableShutterSound") else false
      val directory = if (map.hasKey("path")) FileUtils.getDirectory(map.getString("path")) else context.cacheDir
      val userComments = if (map.hasKey("userComment")) map.getString("userComment") else ""
      val artist = if (map.hasKey("artist")) map.getString("artist") else ""
      val software = if (map.hasKey("software")) map.getString("software") else ""
      val latitude = if (map.hasKey("latitude")) map.getDouble("latitude") else 0
      val longitude = if (map.hasKey("longitude")) map.getDouble("longitude") else 0

      val outputFile = OutputFile(context, directory, ".jpg")
      return TakePhotoOptions(outputFile, flash, enableShutterSound, userComments!!, artist!!, software!!, latitude, longitude)
    }
  }
}
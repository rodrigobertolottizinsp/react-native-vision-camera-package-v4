package com.mrousavy.camera.core.utils

import android.content.Context
import android.graphics.Bitmap
import java.io.File
import java.io.FileOutputStream

class FileUtils {
    companion object {
        fun createFile(context: Context, filePath: String): File {
            val file = File(filePath)
            if (!file.parentFile.exists()) {
                file.parentFile.mkdirs() // Create directories if they don't exist
            }
            return file
        }

      fun createTempFile(context: Context, extension: String): File =
          File.createTempFile("mrousavy-", extension, context.cacheDir).also {
            it.deleteOnExit()
          }

      fun writeBitmapTofile(bitmap: Bitmap, file: File, quality: Int = 100) {
        FileOutputStream(file).use { stream ->
          bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        }
      }
    }
}

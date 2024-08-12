//
//  MetadataProvider.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 19.03.24.
//

import AVFoundation
import CoreLocation
import Foundation

/**
 A Provider for Photo (AVCapturePhoto) EXIF metadata, and Video (AVAssetWriter) metadata.
 */
class MetadataProvider: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
  /**
   Get or set the location provider to also set GPS tags for captured photos or videos.
   */
  var locationProvider: LocationProvider?

    private var artist: String?
    private var software: String?
    private var deviceString: String?
    private var userComment: String?

        func setMetadata(artist: String, software: String, deviceString: String, userComment: String) {
      self.artist = artist
      self.software = software
      self.deviceString = deviceString
      self.userComment = userComment
    }
    
  // MARK: - Photo Metadata

    /**
     Adds AVCapturePhoto's metadata dictionary
     */
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
      var properties = photo.metadata
      // Add branding info
      if var exifDictionary = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        exifDictionary[kCGImagePropertyExifUserComment as String] = userComment
        properties[kCGImagePropertyExifDictionary as String] = exifDictionary
      }
        
    // Add branding info to TIFF dictionary
    if var tiffDictionary = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiffDictionary[kCGImagePropertyTIFFArtist as String] = artist
        tiffDictionary[kCGImagePropertyTIFFSoftware as String] = software
        tiffDictionary[kCGImagePropertyTIFFMake as String] = deviceString // Use an existing key
        properties[kCGImagePropertyTIFFDictionary as String] = tiffDictionary
    } else {
        // If the TIFF dictionary does not exist, create it
        properties[kCGImagePropertyTIFFDictionary as String] = [
            kCGImagePropertyTIFFArtist as String: artist,
            kCGImagePropertyTIFFSoftware as String: software,
            kCGImagePropertyTIFFMake as String: deviceString
        ]
    }

      // Add GPS Location EXIF info
      if let locationProvider,
         let location = locationProvider.location {
        let locationExif = location.toEXIF(heading: locationProvider.heading)
        properties[kCGImagePropertyGPSDictionary as String] = locationExif
      }

      return properties
    }

  // MARK: - Video Metadata

  func createVideoMetadata() -> [AVMetadataItem] {
    var metadata: [AVMetadataItem] = []

    // Add branding metadata
    let brandingMetadata = createBrandingMetadaItem()
    metadata.append(brandingMetadata)

    if let location = locationProvider?.location {
      // Add GPS Location metadata
      let locationMetadata = createLocationMetadataItem(location: location)
      metadata.append(locationMetadata)
    }

    return metadata
  }

  private func createBrandingMetadaItem() -> AVMetadataItem {
    let metadataItem = AVMutableMetadataItem()
    metadataItem.keySpace = .quickTimeMetadata
    metadataItem.key = AVMetadataKey.quickTimeMetadataKeyInformation as NSString
    metadataItem.identifier = .quickTimeMetadataInformation
    metadataItem.value = "Captured with VisionCamera by mrousavy" as NSString
    metadataItem.dataType = kCMMetadataBaseDataType_UTF8 as String
    return metadataItem
  }

  private func createLocationMetadataItem(location: CLLocation) -> AVMetadataItem {
    let metadataItem = AVMutableMetadataItem()
    metadataItem.keySpace = .quickTimeMetadata
    metadataItem.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
    metadataItem.identifier = .quickTimeMetadataLocationISO6709
    metadataItem.value = location.iso6709String as NSString
    metadataItem.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
    return metadataItem
  }
}

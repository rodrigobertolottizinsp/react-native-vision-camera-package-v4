//
//  RecordVideoOptions.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 12.10.23.
//  Copyright © 2023 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation

struct RecordVideoOptions {
  var fileType: AVFileType = .mov
  var flash: Torch = .off
  var codec: AVVideoCodecType?
  var path: URL
  /**
   * Full Bit-Rate override for the Video Encoder, in Megabits per second (Mbps)
   */
  var bitRateOverride: Double?
  /**
   * A multiplier applied to whatever the currently set bit-rate is, whether it's automatically computed by the OS Encoder,
   * or set via bitRate, in Megabits per second (Mbps)
   */
  var bitRateMultiplier: Double?
  var zAssistMotionEnabled: Bool = false

  init(fromJSValue dictionary: NSDictionary) throws {
    // File Type (.mov or .mp4)
    if let fileTypeOption = dictionary["fileType"] as? String {
      fileType = try AVFileType(withString: fileTypeOption)
    }
    // Flash
    if let flashOption = dictionary["flash"] as? String {
      flash = try Torch(jsValue: flashOption)
    }
    // Codec
    if let codecOption = dictionary["videoCodec"] as? String {
      codec = try AVVideoCodecType(withString: codecOption)
    }
    // BitRate Override
    if let parsed = dictionary["videoBitRateOverride"] as? Double {
      bitRateOverride = parsed
    }
    // BitRate Multiplier
    if let parsed = dictionary["videoBitRateMultiplier"] as? Double {
      bitRateMultiplier = parsed
    }
    if let parsed = dictionary["zAssistMotionEnabled"] as? Bool {
       zAssistMotionEnabled = parsed
    }
    // Custom Path
    let fileExtension = fileType.descriptor ?? "mov"
    if let customPath = dictionary["path"] as? String {
      path = try FileUtils.getFilePath(customDirectory: customPath, fileExtension: fileExtension)
    } else {
      path = try FileUtils.getFilePath(fileExtension: fileExtension)
    }
  }
}

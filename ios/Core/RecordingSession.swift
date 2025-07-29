//
//  RecordingSession.swift
//  VisionCamera
//
//  Created by Marc Rousavy on 01.05.21.
//  Copyright © 2021 mrousavy. All rights reserved.
//

import AVFoundation
import CoreLocation
import Foundation

// MARK: - RecordingSession

/**
 A [RecordingSession] class that can record video and audio [CMSampleBuffers] from [AVCaptureVideoDataOutput] and
 [AVCaptureAudioDataOutput] into a .mov/.mp4 file using [AVAssetWriter].

 It also synchronizes buffers to the CMTime by the CaptureSession so that late frames are removed from the beginning and added
 towards the end (useful e.g. for videoStabilization).
 */
final class RecordingSession {
  private let clock: CMClock
  private let assetWriter: AVAssetWriter
  private var videoTrack: Track?
  private var audioTrack: Track?
  private let completionHandler: (RecordingSession, AVAssetWriter.Status, Error?) -> Void
  private var isFinishing = false
  private let maxDuration: TimeInterval = 3 * 60 // 3 minutes
  private var recordingTimer: DispatchSourceTimer?
  private var audioFrameCount: Int = 0
  private var minSilenceDuration = 120 //90 frames
  private var silence = true
  private var lastSilence = true
  private var silenceInterval = 0
  var onLoudnessDetected: ((String, Int, Int) -> Void)?

  private var duplicateAudioWriter: AVAssetWriter?
  private var duplicateAudioInput: AVAssetWriterInput?
  private var duplicateAudioURL: URL?
  private var audioChunkCounter: Int = 1

  private let lock = DispatchSemaphore(value: 1)
  /**
   Gets the file URL of the recorded video.
   */
  var url: URL {
    return assetWriter.outputURL
  }

  /**
   Gets the size of the recorded video, in pixels.
   */
  var size: CGSize {
    return videoTrack?.size ?? CGSize.zero
  }

  /**
   Get the duration (in seconds) of the recorded video.
   */
  var duration: Double {
    return videoTrack?.duration.seconds ?? 0.0
  }

  /**
   Returns whether all tracks are marked as finished, or not.
   */
  var isFinished: Bool {
    let isVideoTrackFinished = videoTrack?.isFinished ?? true
    let isAudioTrackFinished = audioTrack?.isFinished ?? true
    return isVideoTrackFinished && isAudioTrackFinished
  }

  /**
   Get the presentation orientation of the video.
   */
  let videoOrientation: Orientation

  init(url: URL,
       fileType: AVFileType,
       metadataProvider: MetadataProvider,
       clock: CMClock,
       orientation: Orientation,
       completion: @escaping (RecordingSession, AVAssetWriter.Status, Error?) -> Void) throws {
       completionHandler = completion
       self.clock = clock

    videoOrientation = orientation
    VisionLogger.log(level: .info, message: "Creating RecordingSession... (orientation: \(orientation))")
    VisionLogger.log(level: .info, message: "url \(url.absoluteString)")
    do {
      assetWriter = try AVAssetWriter(outputURL: url, fileType: fileType)
      assetWriter.shouldOptimizeForNetworkUse = false
    } catch let error as NSError {
      throw CameraError.capture(.createRecorderError(message: error.description))
    }

    // Assign the metadata item to the asset writer
    let metadataItems = metadataProvider.createVideoMetadata()
    assetWriter.metadata.append(contentsOf: metadataItems)
  }

  deinit {
    recordingTimer?.cancel()
    recordingTimer = nil
    if assetWriter.status == .writing {
      VisionLogger.log(level: .info, message: "Cancelling AssetWriter...")
      assetWriter.cancelWriting()
    }
  }

  /**
   Initializes the video track.
   */
  func initializeVideoTrack(withSettings settings: [String: Any]) throws {
    guard !settings.isEmpty else {
      throw CameraError.capture(.createRecorderError(message: "Tried to initialize Video Track with empty options!"))
    }
    guard videoTrack == nil else {
      throw CameraError.capture(.createRecorderError(message: "Tried to initialize Video Track twice!"))
    }
    guard assetWriter.canApply(outputSettings: settings, forMediaType: .video) else {
      throw CameraError.capture(.createRecorderError(message: "The given output settings are not supported!"))
    }

    VisionLogger.log(level: .info, message: "Initializing Video AssetWriter with settings: \(settings.description)")
    let videoWriter = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    videoWriter.expectsMediaDataInRealTime = true
    videoWriter.transform = videoOrientation.affineTransform
    assetWriter.add(videoWriter)
    videoTrack = Track(ofType: .video, withAssetWriterInput: videoWriter, andClock: clock)
    VisionLogger.log(level: .info, message: "Initialized Video AssetWriter.")
  }

  /**
   Initializes the audio track.
   */
  func initializeAudioTrack(withSettings settings: [String: Any]?, format: CMFormatDescription) throws {
    guard audioTrack == nil else {
      throw CameraError.capture(.createRecorderError(message: "Tried to initialize Audio Track twice!"))
    }

    if let settings = settings {
      VisionLogger.log(level: .info, message: "Initializing Audio AssetWriter with settings: \(settings.description)")
    } else {
      VisionLogger.log(level: .info, message: "Initializing Audio AssetWriter default settings...")
    }
    let audioWriter = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
    audioWriter.expectsMediaDataInRealTime = true
    assetWriter.add(audioWriter)
    audioTrack = Track(ofType: .audio, withAssetWriterInput: audioWriter, andClock: clock)
    VisionLogger.log(level: .info, message: "Initialized Audio AssetWriter.")
  }

  /**
   Start the RecordingSession using the current time of the provided synchronization clock.
   All buffers passed to [append] must be synchronized to this Clock.
   */
  func start() throws {
      guard isMicrophoneAvailable() else {
          throw CameraError.capture(.microphoneUnavailable)
        }
    lock.wait()
    defer {
      lock.signal()
    }

    VisionLogger.log(level: .info, message: "Starting Asset Writer...")

    // Prepare the AssetWriter for writing to the video file
    let success = assetWriter.startWriting()
    guard success else {
      throw CameraError.capture(.createRecorderError(message: "Failed to start Asset Writer!"))
    }
    VisionLogger.log(level: .info, message: "Asset Writer started!")

    // Start the session - any timestamp before this point will be cut off.
    let now = CMClockGetTime(clock)
    assetWriter.startSession(atSourceTime: now)
    VisionLogger.log(level: .info, message: "Asset Writer session started at \(now.seconds).")

    // Start both tracks
    videoTrack?.start()
    audioTrack?.start()
      
      // Schedule a timer to stop the recording after maxDuration
    recordingTimer = DispatchSource.makeTimerSource()
    recordingTimer?.schedule(deadline: .now() + maxDuration)
    recordingTimer?.setEventHandler { [weak self] in
      guard let self = self else { return }
      VisionLogger.log(level: .info, message: "Max recording duration reached. Stopping session.")
      self.stop()
    }
    recordingTimer?.resume()
  }

  /**
   Requests the RecordingSession to stop writing frames at the current time of the provided synchronization clock.
   The RecordingSession will continue to write video frames and audio frames that have been produced (but not yet consumed)
   before the requested timestamp.
   This may happen if the Camera pipeline has an additional processing overhead, e.g. when video stabilization is enabled.
   Once all late frames have been captured (or an artificial abort timeout has been triggered), the [completionHandler] will be called.
   */
  func stop() {
    recordingTimer?.cancel() // Cancel the timer
    recordingTimer = nil
    audioFrameCount = 0
    lock.wait()
    defer {
      lock.signal()
    }
      
      

    VisionLogger.log(level: .info, message: "Stopping Asset Writer with status \"\(assetWriter.status.descriptor)\"...")

    // Stop both tracks
    videoTrack?.stop()
    audioTrack?.stop()

    // Start a timeout that will force-stop the session if it still hasn't been stopped (maybe no more frames came in?)
    let latency = max(videoTrack?.latency.seconds ?? 0.0, audioTrack?.latency.seconds ?? 0.0)
    let timeout = max(latency * 2, 0.1)
    CameraQueues.cameraQueue.asyncAfter(deadline: .now() + timeout) {
      if !self.isFinishing {
        VisionLogger.log(level: .error, message: "Waited \(timeout) seconds but session is still not finished - force-stopping session...")
        self.finish()
      }
    }
  }

  /**
   Requests the RecordingSession to temporarily pause writing frames at the current time of the provided synchronization clock.
   The RecordingSession will continue to write video frames and audio frames that have been produced (but not yet consumed)
   before the requested timestamp.
   This may happen if the Camera pipeline has an additional processing overhead, e.g. when video stabilization is enabled.
   */
  func pause() {
    lock.wait()
    defer {
      lock.signal()
    }

    // Stop both tracks
    videoTrack?.pause()
    audioTrack?.pause()
  }

  /**
   Resumes the RecordingSession and starts writing frames starting with the time of the provided synchronization clock.
   */
  func resume() {
    lock.wait()
    defer {
      lock.signal()
    }

    // Resume both tracks
    videoTrack?.resume()
    audioTrack?.resume()
  }

  func append(buffer: CMSampleBuffer, ofType type: TrackType) throws {
    guard !isFinishing else {
      // Session is already finishing, can't write anything more
      return
    }
    guard assetWriter.status == .writing else {
      throw CameraError.capture(.unknown(message: "Frame arrived, but AssetWriter status is \(assetWriter.status.descriptor)!"))
    }

    // Write buffer to video/audio track
    let track = try getTrack(ofType: type)
    try track.append(buffer: buffer)

      if let _ = self.onLoudnessDetected {
          // NEW AUDIO TODO:
          // get or start audio file if doesnt exist
          // append buffer to audio file
          
          // Calculate and print loudness for audio buffers
          if type == .audio {
              if self.duplicateAudioWriter == nil {
                  // Set output file URL
                  //TODO: create url for duplicateAudioWriter to be the same as url but with -audio before the extension
                  let newURL = self.url
                    .deletingPathExtension()
                    .deletingLastPathComponent()
                    .appendingPathComponent(self.url.deletingPathExtension().lastPathComponent + "-audio-\(self.audioChunkCounter)").appendingPathExtension("m4a")
                  self.duplicateAudioURL = newURL
                  VisionLogger.log(level: .info, message: "NEW URL OLD::: \(newURL))")
                  
                  // Set up asset writer
                  self.duplicateAudioWriter = try AVAssetWriter(outputURL: self.duplicateAudioURL!, fileType: .m4a)
                  let formatDesc = CMSampleBufferGetFormatDescription(buffer)!
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
                  let audioSettings: [String: Any] = [
                      AVFormatIDKey: kAudioFormatMPEG4AAC,
                      AVSampleRateKey: asbd.mSampleRate,
                      AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                      AVEncoderBitRateKey: 64000
                  ]

                  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                  input.expectsMediaDataInRealTime = true
                  if  self.duplicateAudioWriter!.canAdd(input) {
                      self.duplicateAudioWriter!.add(input)
                      self.duplicateAudioInput = input
                      self.duplicateAudioWriter!.startWriting()
                      self.duplicateAudioWriter!.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                  }
              }
              
              // Append buffer
              if let input = duplicateAudioInput, input.isReadyForMoreMediaData {
                  input.append(buffer)
              }
              
              if let (db, isTalking) = calculateLoudness(from: buffer) {
                  let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                  if !isTalking {
                      silenceInterval += 1
                  }else{
                      silenceInterval = 0
                      silence = false
                  }
                  if silenceInterval > minSilenceDuration {
                      silence = true
                  }
                  if (lastSilence != silence){
                      // TODO : If silence = true
                      // 1) close audio track
                      if (silence == true){
//                          if let audioInput = duplicateAudioInput, audioInput.isReadyForMoreMediaData {
//                              audioInput.markAsFinished()
//                          }
                          if let audioInput = duplicateAudioInput {
                              audioInput.markAsFinished()
                          }
                          
                          //TODO: PROBLEM, self.duplicateAudioWriter block is never accessed
                          self.duplicateAudioWriter?.finishWriting {
                              self.duplicateAudioWriter = nil
                              if let url = self.duplicateAudioURL {
                                  do {
                                      let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                                      let fileSize = attrs[.size] as? Int64 ?? -1
                                      // 2) notify js
                                      VisionLogger.log(level: .info, message: "NEW AUDIO CHUNK!! \(url.path) (\(fileSize) bytes)")
                                      // You can now use the URL or size for further use
                                  } catch {
                                      VisionLogger.log(level: .error, message: "Could not read audio file attributes: \(error.localizedDescription)")
                                  }
                              }
                          }
                          // 3) add to counter to name next audio chunk
                          self.audioChunkCounter = self.audioChunkCounter + 1
                      }
//                      VisionLogger.log(level: .info, message: "STATUS CHANGED from lastSilence \(lastSilence) to \(silence)" )
                      lastSilence = silence
                      self.onLoudnessDetected?(silence ? (self.duplicateAudioURL?.path ?? "Error. No path found"):"", self.audioChunkCounter - 1, -1)
                  }
              }
          }
      }
      
    // If we failed to write the frames, stop the Recording
    if assetWriter.status == .failed {
      let error = assetWriter.error?.localizedDescription ?? "(unknown error)"
      VisionLogger.log(level: .error, message: "AssetWriter failed to write buffer! Error: \(error)")
      finish()
      return
    }
 
    // When all tracks (video + audio) are finished, finish the Recording.
    if isFinished {
        // NEW AUDIO TODO:
        // finish/close audio file
        if let audioInput = duplicateAudioInput, audioInput.isReadyForMoreMediaData {
            audioInput.markAsFinished()
            VisionLogger.log(level: .info, message: "Finished recording. Current audio path: \(self.duplicateAudioURL?.path)")
        }
        if let _ = self.onLoudnessDetected {
            if let audioWriter = self.duplicateAudioWriter {
                // Immediately set to nil to prevent re-entry
                self.duplicateAudioWriter = nil

                audioWriter.finishWriting {
                    if let url = self.duplicateAudioURL {
                        do {
                            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                            let fileSize = attrs[.size] as? Int64 ?? -1
                            VisionLogger.log(level: .info, message: "NEW AUDIO CHUNK!! \(url.path) (\(fileSize) bytes)")
                            self.onLoudnessDetected?(url.path, self.audioChunkCounter, self.audioChunkCounter)
                            
                            // You can now use the URL or size for further use
                        } catch {
                            VisionLogger.log(level: .error, message: "Could not read audio file attributes: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
      finish()
    }
  }

    
    /**
     Calculates the loudness (in dB) of an audio CMSampleBuffer and determines if it represents talking.
     Returns a tuple with the dB value and a boolean indicating if the audio is classified as talking, or nil if the buffer cannot be processed.
     */
    private func calculateLoudness(from buffer: CMSampleBuffer) -> (db: Float, isTalking: Bool)? {
        // Verify audio format is 16-bit PCM
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
              CMFormatDescriptionGetMediaSubType(format) == kAudioFormatLinearPCM else {
            VisionLogger.log(level: .error, message: "Audio format is not Linear PCM")
            return nil
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
            VisionLogger.log(level: .error, message: "Failed to get data buffer for loudness calculation")
            return nil
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer = dataPointer else {
            VisionLogger.log(level: .error, message: "Failed to access audio samples: \(status)")
            return nil
        }

        // Interpret the raw data as 16-bit PCM samples
        let sampleCount = length / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            VisionLogger.log(level: .error, message: "No audio samples available")
            return nil
        }

        // Cast the raw pointer to Int16 for 16-bit PCM audio
        let samples = dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { ptr in
            return ptr
        }

        // Calculate RMS
        var sum: Float = 0.0
        for i in 0..<sampleCount {
            let sample = Float(samples[i])
            sum += sample * sample
        }
        let meanSquare = sum / Float(sampleCount)
        let rms = sqrt(meanSquare)

        // Calculate dB with adjusted reference for typical speech levels
        let referenceAmplitude: Float = 2000.0 // Calibrated for speech
        guard rms > 0 else {
            return (db: -60.0, isTalking: false) // Silence
        }
        let db = 20.0 * log10(rms / referenceAmplitude)

        // Classify as talking if dB is above threshold
        let talkingThreshold: Float = -5.0 // Adjust based on testing
        let isTalking = db > talkingThreshold

        // Option: Normalize to 0–100 scale (uncomment to use instead of dB)
        /*
        let maxRms: Float = 32768.0
        let normalized = min(max(rms / maxRms * 100.0, 0.0), 100.0)
        let talkingThresholdNormalized: Float = 10.0 // Adjust based on testing
        let isTalking = normalized > talkingThresholdNormalized
        return (db: normalized, isTalking: isTalking)
        */

        return (db: db, isTalking: isTalking)
    }
    
  @inline(__always)
  private func getTrack(ofType type: TrackType) throws -> Track {
    switch type {
    case .audio:
      guard let audioTrack else {
        throw CameraError.capture(.unknown(message: "Tried to write an audio buffer, but no audio track was initialized!"))
      }
      return audioTrack
    case .video:
      guard let videoTrack else {
        throw CameraError.capture(.unknown(message: "Tried to write a video buffer, but no video track was initialized!"))
      }
      return videoTrack
    }
  }

  /**
   Stops the AssetWriters and calls the completion callback.
   */
  private func finish() {
    recordingTimer?.cancel() // Cancel the timer
    recordingTimer = nil
    lock.wait()
    defer {
      lock.signal()
    }

    VisionLogger.log(level: .info, message: "Stopping AssetWriter with status \"\(assetWriter.status.descriptor)\"...")

    guard let videoTrack,
          let lastVideoTimestamp = videoTrack.lastTimestamp else {
      VisionLogger.log(level: .error, message: "Failed to finish() - No video track was ever initialized/started!")
      completionHandler(self, assetWriter.status, assetWriter.error)
      assetWriter.cancelWriting()
      return
    }
    guard assetWriter.status == .writing else {
      // The asset writer has an error - cancel everything.
      VisionLogger.log(level: .error, message: "Failed to finish() - AssetWriter status was \(assetWriter.status.descriptor)!")
      completionHandler(self, assetWriter.status, assetWriter.error)
      assetWriter.cancelWriting()
      return
    }

    guard !isFinishing else {
      // We're already finishing - there was a second call to this method.
      VisionLogger.log(level: .warning, message: "Tried calling finish() twice!")
      return
    }

    isFinishing = true

    // End the session at the last video frame's timestamp.
    // If there are audio frames after this timestamp, they will be cut off.
    assetWriter.endSession(atSourceTime: lastVideoTimestamp)
    VisionLogger.log(level: .info, message: "Asset Writer session stopped at \(lastVideoTimestamp.seconds).")
    assetWriter.finishWriting {
      VisionLogger.log(level: .info, message: "Asset Writer finished writing!")
      self.completionHandler(self, self.assetWriter.status, self.assetWriter.error)
    }
  }
    private func isMicrophoneAvailable() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: .defaultToSpeaker)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            return audioSession.isInputAvailable
        } catch {
            VisionLogger.log(level: .error, message: "Failed to activate audio session: \(error.localizedDescription)")
            return false
        }
    }
}

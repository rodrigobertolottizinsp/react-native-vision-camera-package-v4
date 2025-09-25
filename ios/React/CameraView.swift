//
//  CameraView.swift
//  mrousavy
//
//  Created by Marc Rousavy on 09.11.20.
//  Copyright © 2020 mrousavy. All rights reserved.
//

import AVFoundation
import Foundation
import UIKit
import CoreMotion
import Speech

// TODOs for the CameraView which are currently too hard to implement either because of AVFoundation's limitations, or my brain capacity
//
// CameraView+RecordVideo
// TODO: Better startRecording()/stopRecording() (promise + callback, wait for TurboModules/JSI)
//
// CameraView+TakePhoto
// TODO: Photo HDR

// MARK: - CameraView

public final class CameraView: UIView, CameraSessionDelegate, PreviewViewDelegate, FpsSampleCollectorDelegate {
  // pragma MARK: React Properties

  // props that require reconfiguring
  @objc var cameraId: NSString?
  @objc var enableDepthData = false
  @objc var enablePortraitEffectsMatteDelivery = false
  @objc var enableBufferCompression = false
  @objc var isMirrored = false
  @objc var enableMotionAware = false
  // use cases
  @objc var photo = false
  @objc var video = false
  @objc var audio = false
  @objc var enableFrameProcessor = false
  @objc var codeScannerOptions: NSDictionary?
  @objc var pixelFormat: NSString?
  @objc var enableLocation = false
  @objc var preview = true {
    didSet {
      updatePreview()
    }
  }

  // props that require format reconfiguring
  @objc var format: NSDictionary?
  @objc var minFps: NSNumber?
  @objc var maxFps: NSNumber?
  @objc var videoHdr = false
  @objc var photoHdr = false
  @objc var photoQualityBalance: NSString?
  @objc var lowLightBoost = false
  @objc var outputOrientation: NSString?

  // other props
  @objc var isActive = false
  @objc var torch = "off"
  @objc var zoom: NSNumber = 1.0 // in "factor"
  @objc var exposure: NSNumber = 0.0
  @objc var videoStabilizationMode: NSString?
  @objc var resizeMode: NSString = "cover" {
    didSet {
      updatePreview()
    }
  }

  // events
  @objc var onInitializedEvent: RCTDirectEventBlock?
  @objc var onErrorEvent: RCTDirectEventBlock?
  @objc var onStartedEvent: RCTDirectEventBlock?
  @objc var onStoppedEvent: RCTDirectEventBlock?
  @objc var onPreviewStartedEvent: RCTDirectEventBlock?
  @objc var onPreviewStoppedEvent: RCTDirectEventBlock?
  @objc var onShutterEvent: RCTDirectEventBlock?
  @objc var onPreviewOrientationChangedEvent: RCTDirectEventBlock?
  @objc var onOutputOrientationChangedEvent: RCTDirectEventBlock?
  @objc var onViewReadyEvent: RCTDirectEventBlock?
  @objc var onAverageFpsChangedEvent: RCTDirectEventBlock?
  @objc var onCodeScannedEvent: RCTDirectEventBlock?
  @objc var onZoomChanged: RCTDirectEventBlock?
  @objc var onZoomStateChanged: RCTDirectEventBlock?
  @objc var onMicInputChanged: RCTDirectEventBlock?
  @objc var onTranscribedTextChanged: RCTDirectEventBlock?
  @objc var onMotionChanged: RCTDirectEventBlock?
  @objc var onSteadyMovementChanged: RCTDirectEventBlock?  
  @objc var onPositionChanged: RCTDirectEventBlock?

  // zoom
  @objc var enableZoomGesture = false {
    didSet {
      if enableZoomGesture {
        addPinchGestureRecognizer()
      } else {
        removePinchGestureRecognizer()
      }
    }
  }

  #if VISION_CAMERA_ENABLE_FRAME_PROCESSORS
    @objc public var frameProcessor: FrameProcessor?
  #endif

  // pragma MARK: Internal Properties
  var cameraSession = CameraSession()
  var previewView: PreviewView?
  var isMounted = false
  private var currentConfigureCall: DispatchTime?
  private let fpsSampleCollector = FpsSampleCollector()

  // CameraView+Zoom
  var pinchGestureRecognizer: UIPinchGestureRecognizer?
  var pinchScaleOffset: CGFloat = 1.0

  // CameraView+TakeSnapshot
  var latestVideoFrame: Snapshot?
    
  private var elapsedTime: Double = 0.0 // Initialize a counter
  var motionManager = CMMotionManager()  // CoreMotion Manager for accelerometer
  var updateInterval = 0.0333
  // pragma MARK: Setup
  var accelerometerDataList: [[String: Any]] = []
   var timer: DispatchSourceTimer?

    private var imuWindow: [(xa: Double, ya: Double, za: Double, xg: Double, yg: Double, zg: Double)] = []
    private let windowSize = 5
    private var lastMotionClassification: String? = nil
    private var steadyAccumulator: Double = 0.0
    private let steadyTrigger: Double = 2.0
    private var movingTime: Double? = nil
    private var unsteadyTime: Double? = nil
    private var panningTime: Double? = nil

    //TODO: Initialize vector (x, y , z)
    private var accRotation: (x: Double, y: Double, z: Double) = (0.0, 0.0, 0.0)
    
    //
    private let accRotationThreshold = 20.0 * .pi / 180  // adjust this value based on your needs
    private let steadySticknessThreshold = 20.0 * .pi / 180  // adjust this value based on your needs

    private var lastRunInterval = 0.0
    
    private var accRotationMagnitude = 0.0
    
    let zoomState = ZoomState()
    let gyroErrorMargin = 0.01
    
  override public init(frame: CGRect) {
    super.init(frame: frame)
    cameraSession.delegate = self
    fpsSampleCollector.delegate = self
    updatePreview()
  }


    
    
  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) is not implemented.")
  }

    func startAccelerometerUpdates() {
      guard let onPositionChanged = self.onPositionChanged else {
        print("onPositionChanged is nil. Accelerometer updates will not start.")
        return
      }
      elapsedTime = 0.0

      guard motionManager.isAccelerometerAvailable, motionManager.isGyroAvailable else {
        print("Required sensors are not available on this device.")
        return
      }

      motionManager.accelerometerUpdateInterval = updateInterval
      motionManager.gyroUpdateInterval = updateInterval

      motionManager.startAccelerometerUpdates()
      motionManager.startGyroUpdates()

      timer = DispatchSource.makeTimerSource(queue: .main)
      timer?.schedule(deadline: .now(), repeating: updateInterval)

      timer?.setEventHandler { [weak self] in
        guard let self = self else { return }
        guard let accelerometerData = self.motionManager.accelerometerData,
              let gyroscopeData = self.motionManager.gyroData else { return }

          let xa = accelerometerData.acceleration.x
          let ya = accelerometerData.acceleration.y
          let za = accelerometerData.acceleration.z

          let xg = gyroscopeData.rotationRate.x
          let yg = gyroscopeData.rotationRate.y
          let zg = gyroscopeData.rotationRate.z

        if let _ = self.onMotionChanged {
            let currentRunTimestamp = gyroscopeData.timestamp
            let realUpdateInterval = currentRunTimestamp - self.lastRunInterval
            self.lastRunInterval = currentRunTimestamp
            
            let logZoom = log(Double(zoom)) + 1
            
            var xgAccRot = abs(xg) < gyroErrorMargin ? 0 : xg
            var ygAccRot = abs(yg) < gyroErrorMargin ? 0 : yg
            var zgAccRot = abs(zg) < gyroErrorMargin ? 0 : zg

            let accRotX = self.accRotation.x
            let accRotY = self.accRotation.y
            let accRotZ = self.accRotation.z
            
            var forceMotionChange = false
            
            self.accRotation.x = accRotX + (xgAccRot * realUpdateInterval * logZoom)
            self.accRotation.y = accRotY + (ygAccRot * realUpdateInterval * logZoom)
            self.accRotation.z = accRotZ + (zgAccRot * realUpdateInterval * logZoom)
            
            if self.imuWindow.count >= self.windowSize {
              self.imuWindow.removeFirst()
            }
            self.imuWindow.append((xa, ya, za, xg, yg, zg))

            if self.imuWindow.count == self.windowSize {
              let avg = self.imuWindow.reduce((0.0, 0.0, 0.0, 0.0, 0.0, 0.0)) { acc, val in
                (
                  acc.0 + val.xa,
                  acc.1 + val.ya,
                  acc.2 + val.za,
                  acc.3 + val.xg,
                  acc.4 + val.yg,
                  acc.5 + val.zg
                )
              }

              let divisor = Double(self.windowSize)
              let (avgAx, avgAy, avgAz, avgGx, avgGy, avgGz) = (
                avg.0 / divisor,
                avg.1 / divisor,
                avg.2 / divisor,
                avg.3 / divisor,
                avg.4 / divisor,
                avg.5 / divisor
              )

              let netAcc = sqrt(avgAx * avgAx + avgAy * avgAy + avgAz * avgAz)
                
              let gx2 = avgGx * avgGx
              let gy2 = avgGy * avgGy
              let gz2 = avgGz * avgGz
              let agularVelocityMagnitude = sqrt(gx2 + gy2 + gz2)
                
              let tangencialVelocityMagnitude = agularVelocityMagnitude * logZoom
            
              let accDev = abs(netAcc - 1.0)
                
              var motion = "Steady"
                
              if tangencialVelocityMagnitude <= 0.25 {
                motion = "Steady"
              } else if (self.lastMotionClassification == "Steady" && self.accRotationMagnitude > steadySticknessThreshold){
                motion = "Steady"
                forceMotionChange = true
              } else if tangencialVelocityMagnitude <= 1.0 {
                motion = "Panning"
                self.panningTime = Date().timeIntervalSince1970
              } else {
                motion = "Unsteady"
                self.unsteadyTime = Date().timeIntervalSince1970
              }

              
                
              if motion == "Steady" && accDev > 0.03 {
                  if accDev < 0.1 {
                      motion = "Moving"
                      self.movingTime = Date().timeIntervalSince1970
                  } else {
                      motion = "Unsteady"
                      self.unsteadyTime = Date().timeIntervalSince1970
                  }
              }
                
                var inertia = false;
                
                if (self.movingTime != nil){
                    let inertiaTime = Date().timeIntervalSince1970 - self.movingTime!
                    inertia = self.lastMotionClassification == "Moving" && inertiaTime < 1.0
                }
                
                if (self.unsteadyTime != nil){
                    let inertiaTime = Date().timeIntervalSince1970 - self.unsteadyTime!
                    inertia = inertia || self.lastMotionClassification == "Unsteady" && inertiaTime < 1.0
                }
                
                if (self.panningTime != nil){
                    let inertiaTime = Date().timeIntervalSince1970 - self.panningTime!
                    inertia = inertia || self.lastMotionClassification == "Panning" && inertiaTime < 1.0
                }
                
                
                if ((motion == "Steady" || motion == "Panning" || motion == "Moving") && inertia){
                    motion = self.lastMotionClassification!
                }
                
                if motion == "Steady" {
                    let rotationMagnitude = sqrt(
                        self.accRotation.x * self.accRotation.x +
                        self.accRotation.y * self.accRotation.y +
                        self.accRotation.z * self.accRotation.z
                    )
                    
                    self.accRotationMagnitude = rotationMagnitude
                    
                    if rotationMagnitude > self.accRotationThreshold {
//                        self.onSteadyMovementChanged?(["timestamp": Date().timeIntervalSince1970])
                        forceMotionChange = true
                        self.accRotation = (0.0, 0.0, 0.0)
                        self.accRotationMagnitude = 0.0
                    }
                }
                
                if motion != self.lastMotionClassification || forceMotionChange {
                    // TODO: IF motion == steady clean vector
                    // accRotation = (0, 0, 0)
                    self.accRotation = (0.0, 0.0, 0.0)
                    self.lastMotionClassification = motion
                    self.onMotionChanged?(["motion": motion])
                }
                
                self.lastMotionClassification = motion
            }
          }
        
        self.onPositionChanged?([
          "position": [
            "xAccel": xa,
            "yAccel": ya,
            "zAccel": za,
            "xGyro": xg,
            "yGyro": yg,
            "zGyro": zg,
            "time": self.elapsedTime,
          ]
        ])
        self.elapsedTime += self.updateInterval
      }
      timer?.resume()
  }




    
    func stopAccelerometerUpdates() {
        timer?.cancel()
        timer = nil
      motionManager.stopAccelerometerUpdates()
    }
    
  override public func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)

    if enableMotionAware {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                print("Speech permission status: \(status)")
            }
        }
    }
      
    if newSuperview != nil {
      fpsSampleCollector.start()
      if !isMounted {
        isMounted = true
        onViewReadyEvent?(nil)
      }
    } else {
      fpsSampleCollector.stop()
    }
  }

  override public func layoutSubviews() {
    if let previewView {
      previewView.frame = frame
      previewView.bounds = bounds
    }
  }

  func getPixelFormat() -> PixelFormat {
    // TODO: Use ObjC RCT enum parser for this
    if let pixelFormat = pixelFormat as? String {
      do {
        return try PixelFormat(jsValue: pixelFormat)
      } catch {
        if let error = error as? CameraError {
          onError(error)
        } else {
          onError(.unknown(message: error.localizedDescription, cause: error as NSError))
        }
      }
    }
    return .yuv
  }

  func getTorch() -> Torch {
    // TODO: Use ObjC RCT enum parser for this
    if let torch = try? Torch(jsValue: torch) {
      return torch
    }
    return .off
  }

  func getPhotoQualityBalance() -> QualityBalance {
    if let photoQualityBalance = photoQualityBalance as? String,
       let balance = try? QualityBalance(jsValue: photoQualityBalance) {
      return balance
    }
    return .balanced
  }

  // pragma MARK: Props updating
  override public final func didSetProps(_ changedProps: [String]!) {
    VisionLogger.log(level: .info, message: "Updating \(changedProps.count) props: [\(changedProps.joined(separator: ", "))]")
    let now = DispatchTime.now()
    currentConfigureCall = now

    cameraSession.configure { [self] config in
      // Check if we're still the latest call to configure { ... }
      guard currentConfigureCall == now else {
        // configure waits for a lock, and if a new call to update() happens in the meantime we can drop this one.
        // this works similar to how React implemented concurrent rendering, the newer call to update() has higher priority.
        VisionLogger.log(level: .info, message: "A new configure { ... } call arrived, aborting this one...")
        throw CameraConfiguration.AbortThrow.abort
      }

      // Input Camera Device
      config.cameraId = cameraId as? String
      config.isMirrored = isMirrored
      config.enableMotionAware = enableMotionAware
      // Photo
      if photo {
        config.photo = .enabled(config: CameraConfiguration.Photo(qualityBalance: getPhotoQualityBalance(),
                                                                  enableDepthData: enableDepthData,
                                                                  enablePortraitEffectsMatte: enablePortraitEffectsMatteDelivery))
      } else {
        config.photo = .disabled
      }

      // Video/Frame Processor
      if video || enableFrameProcessor {
        config.video = .enabled(config: CameraConfiguration.Video(pixelFormat: getPixelFormat(),
                                                                  enableBufferCompression: enableBufferCompression,
                                                                  enableHdr: videoHdr,
                                                                  enableFrameProcessor: enableFrameProcessor))
      } else {
        config.video = .disabled
      }

      // Audio
      if audio {
        config.audio = .enabled(config: CameraConfiguration.Audio())
      } else {
        config.audio = .disabled
      }

      // Code Scanner
      if let codeScannerOptions {
        let options = try CodeScannerOptions(fromJsValue: codeScannerOptions)
        config.codeScanner = .enabled(config: CameraConfiguration.CodeScanner(options: options))
      } else {
        config.codeScanner = .disabled
      }

      // Location tagging
      config.enableLocation = enableLocation && isActive

      // Video Stabilization
      if let jsVideoStabilizationMode = videoStabilizationMode as? String {
        let videoStabilizationMode = try VideoStabilizationMode(jsValue: jsVideoStabilizationMode)
        config.videoStabilizationMode = videoStabilizationMode
      } else {
        config.videoStabilizationMode = .off
      }

      // Orientation
      if let jsOrientation = outputOrientation as? String {
        let outputOrientation = try OutputOrientation(jsValue: jsOrientation)
        config.outputOrientation = outputOrientation
      } else {
        config.outputOrientation = .device
      }

      // Format
      if let jsFormat = format {
        let format = try CameraDeviceFormat(jsValue: jsFormat)
        config.format = format
      } else {
        config.format = nil
      }

      // Side-Props
      config.minFps = minFps?.int32Value
      config.maxFps = maxFps?.int32Value
      config.enableLowLightBoost = lowLightBoost
      config.torch = try Torch(jsValue: torch)

      // Zoom
      config.zoom = zoom.doubleValue

      // Exposure
      config.exposure = exposure.floatValue

      // isActive
      config.isActive = isActive
    }

    // Store `zoom` offset for native pinch-gesture
    if changedProps.contains("zoom") {
      pinchScaleOffset = zoom.doubleValue
    }

    // Prevent phone from going to sleep
    UIApplication.shared.isIdleTimerDisabled = isActive
  }

  func updatePreview() {
    if preview && previewView == nil {
      // Create PreviewView and add it
      previewView = cameraSession.createPreviewView(frame: frame)
      previewView!.delegate = self
      addSubview(previewView!)
    } else if !preview && previewView != nil {
      // Remove PreviewView and destroy it
      previewView?.removeFromSuperview()
      previewView = nil
    }

    if let previewView {
      // Update resizeMode from React
      let parsed = try? ResizeMode(jsValue: resizeMode as String)
      previewView.resizeMode = parsed ?? .cover
    }
  }

  // pragma MARK: Event Invokers

  func onError(_ error: CameraError) {
    VisionLogger.log(level: .error, message: "Invoking onError(): \(error.message)")

    var causeDictionary: [String: Any]?
    if case let .unknown(_, cause) = error,
       let cause = cause {
      causeDictionary = [
        "code": cause.code,
        "domain": cause.domain,
        "message": cause.description,
        "details": cause.userInfo,
      ]
    }
    onErrorEvent?([
      "code": error.code,
      "message": error.message,
      "cause": causeDictionary ?? NSNull(),
    ])
  }

  func onSessionInitialized() {
    onInitializedEvent?([:])
  }

  func onCameraStarted() {
    onStartedEvent?([:])
  }

  func onCameraStopped() {
    onStoppedEvent?([:])
  }

  func onPreviewStarted() {
    onPreviewStartedEvent?([:])
  }

  func onPreviewStopped() {
    onPreviewStoppedEvent?([:])
  }

  func onCaptureShutter(shutterType: ShutterType) {
    onShutterEvent?([
      "type": shutterType.jsValue,
    ])
  }

  func onOutputOrientationChanged(_ outputOrientation: Orientation) {
    onOutputOrientationChangedEvent?([
      "outputOrientation": outputOrientation.jsValue,
    ])
  }

  func onPreviewOrientationChanged(_ previewOrientation: Orientation) {
    onPreviewOrientationChangedEvent?([
      "previewOrientation": previewOrientation.jsValue,
    ])
  }

  func onFrame(sampleBuffer: CMSampleBuffer, orientation: Orientation, isMirrored: Bool) {
    // Update latest frame that can be used for snapshot capture
    latestVideoFrame = Snapshot(imageBuffer: sampleBuffer, orientation: orientation)

    // Notify FPS Collector that we just had a Frame
    fpsSampleCollector.onTick()

    #if VISION_CAMERA_ENABLE_FRAME_PROCESSORS
      if let frameProcessor = frameProcessor {
        // Call Frame Processor
        let frame = Frame(buffer: sampleBuffer,
                          orientation: orientation.imageOrientation,
                          isMirrored: isMirrored)
        frameProcessor.call(frame)
      }
    #endif
  }

  func onCodeScanned(codes: [CameraSession.Code], scannerFrame: CameraSession.CodeScannerFrame) {
    onCodeScannedEvent?([
      "codes": codes.map { $0.toJSValue() },
      "frame": scannerFrame.toJSValue(),
    ])
  }

  func onAverageFpsChanged(averageFps: Double) {
    onAverageFpsChangedEvent?([
      "averageFps": averageFps,
    ])
  }
}

final class ZoomState {
  var value: CGFloat

  init(initialZoom: CGFloat = 1.0) {
    self.value = initialZoom
  }
}

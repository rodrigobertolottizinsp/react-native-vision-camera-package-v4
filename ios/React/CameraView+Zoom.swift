//
//  CameraView+Zoom.swift
//  mrousavy
//
//  Created by Marc Rousavy on 18.12.20.
//  Updated to track zoom start and end on 16.07.25.
//

import Foundation
import UIKit

// MARK: - Associated Keys for storing state
private struct AssociatedKeys {
  static var isZooming = "isZooming"
  static var zoomEndTimer = "zoomEndTimer"
}

// MARK: - Zoom Helpers
extension CameraView {
  
  // Callback to notify zooming state (start: true, end: false)
  @objc var onZoomingChanged: RCTDirectEventBlock? {
    get { objc_getAssociatedObject(self, &AssociatedKeys.isZooming) as? RCTDirectEventBlock }
    set { objc_setAssociatedObject(self, &AssociatedKeys.isZooming, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
  }

  private var isZooming: Bool {
    get { objc_getAssociatedObject(self, &AssociatedKeys.isZooming) as? Bool ?? false }
    set { objc_setAssociatedObject(self, &AssociatedKeys.isZooming, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  private var zoomEndTimer: Timer? {
    get { objc_getAssociatedObject(self, &AssociatedKeys.zoomEndTimer) as? Timer }
    set { objc_setAssociatedObject(self, &AssociatedKeys.zoomEndTimer, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  // MARK: - Pinch Gesture Handler
  @objc
  final func onPinch(_ gesture: UIPinchGestureRecognizer) {
    let scale = max(min(gesture.scale * pinchScaleOffset, cameraSession.maxZoom), CGFloat(1.0))

    // Notify JS of zoom factor change
    onZoomChanged?([
      "zoomFactor": scale
    ])

    // Apply zoom prop
    zoom = NSNumber(value: scale)
    zoomState.value = CGFloat(zoom)
    didSetProps([])

      if enableMicInputChanges {
          // Notify JS that zooming has started (only once)
          if !isZooming {
              isZooming = true
              onZoomStateChanged?(["zooming": true])
          }
          
          // Restart zoom end timer
          zoomEndTimer?.invalidate()
          zoomEndTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
              guard let self = self else { return }
              self.isZooming = false
              onZoomStateChanged?(["zooming": false])
              self.zoomEndTimer = nil
          }
      }

    // Save pinch scale offset when gesture ends
    if gesture.state == .ended {
      pinchScaleOffset = scale
    }
  }

  // MARK: - Gesture Setup
  func addPinchGestureRecognizer() {
    removePinchGestureRecognizer()
    pinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
    addGestureRecognizer(pinchGestureRecognizer!)
  }

  func removePinchGestureRecognizer() {
    if let pinchGestureRecognizer = pinchGestureRecognizer {
      removeGestureRecognizer(pinchGestureRecognizer)
      self.pinchGestureRecognizer = nil
    }
  }
}

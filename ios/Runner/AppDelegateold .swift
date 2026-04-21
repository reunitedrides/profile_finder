import UIKit
import Flutter
import GoogleMaps
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    GMSServices.provideAPIKey("AIzaSyBEdH4WO3_PFhASbmWuTxVkjcv4iAJf6jU")
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let torchChannel = FlutterMethodChannel(
        name: "torch_channel",
        binaryMessenger: controller.binaryMessenger)

      torchChannel.setMethodCallHandler { (call, result) in
        guard call.method == "setTorch",
              let args = call.arguments as? [String: Any],
              let on = args["on"] as? Bool else {
          result(FlutterMethodNotImplemented)
          return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
          self.toggleTorch(on: on, result: result)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
              if granted { self.toggleTorch(on: on, result: result) }
              else { result(FlutterError(code: "NO_PERMISSION", message: "Camera permission denied", details: nil)) }
            }
          }
        default:
          result(FlutterError(code: "NO_PERMISSION", message: "Camera permission denied", details: nil))
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func toggleTorch(on: Bool, result: @escaping FlutterResult) {
    guard let device = AVCaptureDevice.default(for: .video),
          device.hasTorch, device.isTorchAvailable else {
      result(FlutterError(code: "NO_TORCH", message: "Torch not available", details: nil))
      return
    }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if on {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
      result(nil)
    } catch {
      result(FlutterError(code: "TORCH_ERROR", message: error.localizedDescription, details: nil))
    }
  }
}

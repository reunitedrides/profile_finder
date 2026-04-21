import UIKit
import Flutter
import GoogleMaps
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("AIzaSyBEdH4WO3_PFhASbmWuTxVkjcv4iAJf6jU")
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let torchChannel = FlutterMethodChannel(
      name: "torch_channel",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    torchChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTorch" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard let args = call.arguments as? [String: Any],
            let on = args["on"] as? Bool else {
        result(FlutterError(
          code: "BAD_ARGS",
          message: "Expected a boolean 'on' argument.",
          details: nil
        ))
        return
      }

      self?.handleTorchRequest(turnOn: on, result: result)
    }
  }

  private func handleTorchRequest(turnOn on: Bool, result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      toggleTorch(on: on, result: result)

    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard granted else {
            result(FlutterError(
              code: "NO_PERMISSION",
              message: "Camera permission denied.",
              details: nil
            ))
            return
          }
          self?.toggleTorch(on: on, result: result)
        }
      }

    case .denied, .restricted:
      result(FlutterError(
        code: "NO_PERMISSION",
        message: "Camera permission denied or restricted.",
        details: nil
      ))

    @unknown default:
      result(FlutterError(
        code: "NO_PERMISSION",
        message: "Unknown camera permission state.",
        details: nil
      ))
    }
  }

  private func toggleTorch(on: Bool, result: @escaping FlutterResult) {
    guard let device = AVCaptureDevice.default(for: .video) else {
      result(FlutterError(
        code: "NO_CAMERA",
        message: "No video capture device available.",
        details: nil
      ))
      return
    }

    guard device.hasTorch, device.isTorchAvailable else {
      result(FlutterError(
        code: "NO_TORCH",
        message: "Torch is not available on this device.",
        details: nil
      ))
      return
    }

    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }

      if on {
        guard device.isTorchModeSupported(.on) else {
          result(FlutterError(
            code: "NO_TORCH",
            message: "Torch on-mode is not supported on this device.",
            details: nil
          ))
          return
        }
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }

      result(nil)
    } catch {
      result(FlutterError(
        code: "TORCH_ERROR",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }
}

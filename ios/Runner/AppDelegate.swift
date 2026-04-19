import UIKit
import Flutter
import GoogleMaps
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("AIzaSyBEdH4WO3_PFhASbmWuTxVkjcv4iAJf6jU")
    GeneratedPluginRegistrant.register(with: self)

    // Torch channel
    let controller = window?.rootViewController as! FlutterViewController
    let torchChannel = FlutterMethodChannel(name: "torch_channel", binaryMessenger: controller.binaryMessenger)
    torchChannel.setMethodCallHandler { call, result in
      if call.method == "setTorch" {
        if let args = call.arguments as? [String: Any],
           let on = args["on"] as? Bool {
          guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            result(FlutterError(code: "UNAVAILABLE", message: "Torch not available", details: nil))
            return
          }
          do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            result(nil)
          } catch {
            result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
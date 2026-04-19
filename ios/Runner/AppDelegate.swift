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

    // Initialise Google Maps FIRST before anything else
    GMSServices.provideAPIKey("AIzaSyBEdH4WO3_PFhASbmWuTxVkjcv4iAJf6jU")

    // Register Flutter plugins
    GeneratedPluginRegistrant.register(with: self)

    // Set up torch channel AFTER plugins registered
    if let controller = window?.rootViewController as? FlutterViewController {
      let torchChannel = FlutterMethodChannel(
        name: "torch_channel",
        binaryMessenger: controller.binaryMessenger)
      torchChannel.setMethodCallHandler { (call, result) in
        if call.method == "setTorch" {
          if let args = call.arguments as? [String: Any],
             let on = args["on"] as? Bool {
            guard let device = AVCaptureDevice.default(for: .video),
                  device.hasTorch else {
              result(FlutterError(code: "NO_TORCH",
                                  message: "No torch available",
                                  details: nil))
              return
            }
            do {
              try device.lockForConfiguration()
              device.torchMode = on ? .on : .off
              device.unlockForConfiguration()
              result(nil)
            } catch {
              result(FlutterError(code: "TORCH_ERROR",
                                  message: error.localizedDescription,
                                  details: nil))
            }
          }
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

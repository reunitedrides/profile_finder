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
    if let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String {
      GMSServices.provideAPIKey(key)
    }
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as? FlutterViewController
    if let controller = controller {
      let torchChannel = FlutterMethodChannel(name: "torch_channel", binaryMessenger: controller.binaryMessenger)
      torchChannel.setMethodCallHandler { call, result in
        guard call.method == "setTorch",
              let args = call.arguments as? [String: Any],
              let on = args["on"] as? Bool else {
          result(FlutterMethodNotImplemented)
          return
        }
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
package com.marksamazingapps.profilefinder

import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCharacteristics
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val TORCH_CHANNEL = "torch_channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TORCH_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setTorch") {
                val on = call.argument<Boolean>("on") ?: false
                try {
                    val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val cameraId = cameraManager.cameraIdList.firstOrNull { id ->
                        cameraManager.getCameraCharacteristics(id)
                            .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                    }
                    if (cameraId != null) {
                        cameraManager.setTorchMode(cameraId, on)
                        result.success(null)
                    } else {
                        result.error("NO_TORCH", "No torch available", null)
                    }
                } catch (e: Exception) {
                    result.error("TORCH_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}

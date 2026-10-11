package com.example.livecatch_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "livecatch/native_paths",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "lixhResolvePath" -> {
                    val dir = applicationInfo.nativeLibraryDir
                    val so = File(dir, "liblixh_resolve.so")
                    if (so.isFile) {
                        result.success(so.absolutePath)
                    } else {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

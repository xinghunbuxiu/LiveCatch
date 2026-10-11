package com.example.livecatch_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val resolveExecutor = Executors.newSingleThreadExecutor()

    companion object {
        private var nativeReady = false

        init {
            try {
                System.loadLibrary("lixh_stream_resolver")
                nativeReady = true
            } catch (_: UnsatisfiedLinkError) {
                nativeReady = false
            }
        }

        @JvmStatic
        private external fun nativeResolve(url: String, cookies: String?): String
    }

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
                "resolveRoom" -> {
                    if (!nativeReady) {
                        result.error("no_native", "liblixh_stream_resolver not loaded", null)
                        return@setMethodCallHandler
                    }
                    val url = call.argument<String>("url")?.trim().orEmpty()
                    if (url.isEmpty()) {
                        result.error("bad_args", "url required", null)
                        return@setMethodCallHandler
                    }
                    val cookies = call.argument<String>("cookies") ?: ""
                    resolveExecutor.execute {
                        try {
                            val payload = nativeResolve(url, cookies)
                            runOnUiThread { result.success(payload) }
                        } catch (e: Throwable) {
                            runOnUiThread {
                                result.error("resolve_failed", e.message ?: e.toString(), null)
                            }
                        }
                    }
                }
                "resolveNativeReady" -> result.success(nativeReady)
                else -> result.notImplemented()
            }
        }
    }
}

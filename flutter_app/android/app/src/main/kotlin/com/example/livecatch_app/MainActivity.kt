package com.example.livecatch_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val resolveExecutor = Executors.newSingleThreadExecutor()
    private var keepAliveChannel: MethodChannel? = null

    companion object {
        private var nativeReady = false
        private const val REQ_POST_NOTIFICATIONS = 4101

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

        keepAliveChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "livecatch/playback_keepalive",
        ).also { ch ->
            PlaybackBridge.channel = ch
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ensureNotificationPermission()
                        val title = call.argument<String>("title")
                        val text = call.argument<String>("text")
                        try {
                            PlaybackForegroundService.start(this, title, text)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("keepalive_start", e.message ?: e.toString(), null)
                        }
                    }
                    "stop" -> {
                        try {
                            PlaybackForegroundService.stop(this)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("keepalive_stop", e.message ?: e.toString(), null)
                        }
                    }
                    "update" -> {
                        val title = call.argument<String>("title")
                        val text = call.argument<String>("text")
                        try {
                            PlaybackForegroundService.start(this, title, text)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("keepalive_update", e.message ?: e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (PlaybackBridge.channel === keepAliveChannel) {
            PlaybackBridge.channel = null
        }
        keepAliveChannel?.setMethodCallHandler(null)
        keepAliveChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
        }
    }
}

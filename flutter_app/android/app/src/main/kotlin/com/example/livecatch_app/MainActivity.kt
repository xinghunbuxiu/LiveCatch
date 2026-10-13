package com.example.livecatch_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var keepAliveChannel: MethodChannel? = null

    companion object {
        private const val REQ_POST_NOTIFICATIONS = 4101
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

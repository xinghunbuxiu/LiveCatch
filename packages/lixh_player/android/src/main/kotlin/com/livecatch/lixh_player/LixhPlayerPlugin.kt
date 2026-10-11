package com.livecatch.lixh_player

import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

class LixhPlayerPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var textures: TextureRegistry? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var nativeHandle: Long = 0
    private var nativeReady = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "lixh_player")
        channel.setMethodCallHandler(this)
        try {
            System.loadLibrary("lixh_player")
            nativeHandle = nativeCreate()
            nativeReady = nativeHandle != 0L
        } catch (e: UnsatisfiedLinkError) {
            nativeReady = false
        }
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "getPlatformVersion" ->
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            "createVideoTexture" -> {
                releaseSurface()
                textureEntry?.release()
                val entry = textures?.createSurfaceTexture()
                textureEntry = entry
                if (entry == null) {
                    result.error("texture_failed", "TextureRegistry unavailable", null)
                } else {
                    surface = Surface(entry.surfaceTexture())
                    if (nativeReady) nativeAttachSurface(nativeHandle, surface)
                    result.success(
                        mapOf(
                            "textureId" to entry.id(),
                            "width" to ((call.argument<Number>("width"))?.toInt() ?: 1280),
                            "height" to ((call.argument<Number>("height"))?.toInt() ?: 720),
                            "path" to "surface_texture",
                        )
                    )
                }
            }
            "presentTestFrame" -> result.success(null)
            "open" -> {
                if (!ensureNative(result)) return
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("bad_args", "url required", null)
                    return
                }
                val headers = call.argument<String>("headers")
                if (!nativeOpen(nativeHandle, url, headers)) {
                    result.error("open_failed", nativeLastError(nativeHandle), null)
                } else {
                    result.success(true)
                }
            }
            "play" -> {
                if (!ensureNative(result)) return
                if (!nativePlay(nativeHandle)) {
                    result.error("play_failed", nativeLastError(nativeHandle), null)
                } else {
                    result.success(true)
                }
            }
            "stop" -> {
                if (nativeReady) nativeStop(nativeHandle)
                result.success(null)
            }
            "setVideoEnabled" -> {
                if (nativeReady) {
                    nativeSetVideoEnabled(
                        nativeHandle,
                        call.argument<Boolean>("enabled") ?: false
                    )
                }
                result.success(null)
            }
            "setLatency" -> {
                if (nativeReady) {
                    val target = call.argument<Number>("targetMs")?.toInt()
                    val maxv = call.argument<Number>("maxMs")?.toInt()
                    if (target == null || maxv == null) {
                        result.error("bad_args", "targetMs and maxMs required", null)
                        return
                    }
                    nativeSetLatency(nativeHandle, target, maxv)
                }
                result.success(null)
            }
            "getStats" -> {
                val stats = HashMap<String, Any>(
                    mapOf(
                        "textureId" to (textureEntry?.id() ?: -1L),
                        "videoFrames" to 0L,
                        "presentOk" to 0L,
                        "audioFrames" to 0L,
                        "decodeHw" to -1,
                        "lastError" to if (nativeReady) "" else "android native not loaded",
                        "droppedFrames" to 0L,
                        "bytesRead" to 0L,
                        "lagMs" to 0L,
                        "audioQueueMs" to 0,
                        "videoWidth" to 0,
                        "videoHeight" to 0,
                    )
                )
                if (nativeReady) nativeFillStats(nativeHandle, stats)
                stats["textureId"] = textureEntry?.id() ?: -1L
                result.success(stats)
            }
            "disposeVideoTexture" -> {
                releaseSurface()
                textureEntry?.release()
                textureEntry = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        releaseSurface()
        textureEntry?.release()
        textureEntry = null
        if (nativeReady) {
            nativeDestroy(nativeHandle)
            nativeHandle = 0
            nativeReady = false
        }
    }

    private fun releaseSurface() {
        if (nativeReady) nativeDetachSurface(nativeHandle)
        surface?.release()
        surface = null
    }

    private fun ensureNative(result: Result): Boolean {
        if (nativeReady) return true
        result.error(
            "unimplemented",
            "lixh_player Android: native lib missing. Fetch sdk/android-arm64 FFmpeg zip.",
            null
        )
        return false
    }

    private external fun nativeCreate(): Long

    private external fun nativeDestroy(ptr: Long)

    private external fun nativeOpen(ptr: Long, url: String, headers: String?): Boolean

    private external fun nativePlay(ptr: Long): Boolean

    private external fun nativeStop(ptr: Long)

    private external fun nativeSetVideoEnabled(ptr: Long, enabled: Boolean)

    private external fun nativeSetLatency(ptr: Long, targetMs: Int, maxMs: Int)

    private external fun nativeLastError(ptr: Long): String

    private external fun nativeFillStats(ptr: Long, map: HashMap<String, Any>)

    private external fun nativeAttachSurface(ptr: Long, surface: Surface?)

    private external fun nativeDetachSurface(ptr: Long)
}

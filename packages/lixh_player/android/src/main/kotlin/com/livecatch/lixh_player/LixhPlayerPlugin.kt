package com.livecatch.lixh_player

import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LixhPlayerPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var textures: TextureRegistry? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var nativeHandle: Long = 0
    private var nativeReady = false
    private var lastBufW = 0
    private var lastBufH = 0
    private var listen: FlvListenPlayer? = null
    private var pendingUrl: String? = null
    private var pendingHeaders: String? = null
    private var videoWanted = false
    private var latencyTarget = 40
    private var latencyMax = 160
    private var usingListen = false

    // open/stop/play join demux threads — never block Flutter's platform thread.
    private val nativeExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "lixh-player-native").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

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
                val width = (call.argument<Number>("width"))?.toInt() ?: 1280
                val height = (call.argument<Number>("height"))?.toInt() ?: 720
                // Sync detach so MediaCodec open always sees the new Surface.
                awaitNative {
                    try {
                        if (nativeReady) nativeDetachSurface(nativeHandle)
                    } catch (_: Throwable) {
                    }
                }
                surface?.release()
                surface = null
                textureEntry?.release()
                textureEntry = null
                lastBufW = 0
                lastBufH = 0

                val entry = textures?.createSurfaceTexture()
                textureEntry = entry
                if (entry == null) {
                    result.error("texture_failed", "TextureRegistry unavailable", null)
                    return
                }
                entry.surfaceTexture().setDefaultBufferSize(width, height)
                lastBufW = width
                lastBufH = height
                surface = Surface(entry.surfaceTexture())
                val surf = surface
                val handle = nativeHandle
                if (nativeReady) {
                    awaitNative {
                        nativeAttachSurface(handle, surf)
                    }
                }
                result.success(
                    mapOf(
                        "textureId" to entry.id(),
                        "width" to width,
                        "height" to height,
                        "path" to "surface_texture",
                    )
                )
            }
            "presentTestFrame" -> result.success(null)
            "open" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("bad_args", "url required", null)
                    return
                }
                val headers = call.argument<String>("headers")
                nativeExecutor.execute {
                    try {
                        pendingUrl = url
                        pendingHeaders = headers
                        if (openCurrent(url, headers)) {
                            result.success(true)
                        } else {
                            result.error("open_failed", lastOpenError(), null)
                        }
                    } catch (e: Throwable) {
                        result.error("open_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "play" -> {
                nativeExecutor.execute {
                    try {
                        if (playCurrent()) {
                            result.success(true)
                        } else {
                            result.error("play_failed", lastOpenError(), null)
                        }
                    } catch (e: Throwable) {
                        result.error("play_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "stop" -> {
                nativeExecutor.execute {
                    try {
                        stopAll()
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("stop_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "setVideoEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                nativeExecutor.execute {
                    try {
                        val was = videoWanted
                        videoWanted = enabled
                        val url = pendingUrl
                        if (was != enabled && url != null) {
                            stopAll()
                            if (!openCurrent(url, pendingHeaders) || !playCurrent()) {
                                result.error("video_failed", lastOpenError(), null)
                                return@execute
                            }
                        } else if (nativeReady && !usingListen) {
                            nativeSetVideoEnabled(nativeHandle, enabled)
                        }
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("video_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "setLatency" -> {
                val target = call.argument<Number>("targetMs")?.toInt()
                val maxv = call.argument<Number>("maxMs")?.toInt()
                if (target == null || maxv == null) {
                    result.error("bad_args", "targetMs and maxMs required", null)
                    return
                }
                nativeExecutor.execute {
                    try {
                        latencyTarget = target
                        latencyMax = maxv
                        listen?.setLatency(target, maxv)
                        if (nativeReady) nativeSetLatency(nativeHandle, target, maxv)
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("latency_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "getStats" -> {
                nativeExecutor.execute {
                    try {
                        result.success(snapshotStats())
                    } catch (e: Throwable) {
                        result.error("stats_failed", e.message ?: e.toString(), null)
                    }
                }
            }
            "disposeVideoTexture" -> {
                val handle = nativeHandle
                val ready = nativeReady
                val oldSurface = surface
                surface = null
                textureEntry?.release()
                textureEntry = null
                lastBufW = 0
                lastBufH = 0
                if (ready) {
                    nativeExecutor.execute {
                        try {
                            nativeDetachSurface(handle)
                        } catch (_: Throwable) {
                        }
                        mainHandler.post { oldSurface?.release() }
                    }
                } else {
                    oldSurface?.release()
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val handle = nativeHandle
        val ready = nativeReady
        val oldSurface = surface
        surface = null
        textureEntry?.release()
        textureEntry = null
        nativeReady = false
        nativeHandle = 0
        listen?.stop()
        listen = null
        if (ready) {
            nativeExecutor.execute {
                try {
                    nativeDetachSurface(handle)
                    nativeDestroy(handle)
                } catch (_: Throwable) {
                }
                mainHandler.post { oldSurface?.release() }
            }
        } else {
            oldSurface?.release()
        }
        nativeExecutor.shutdown()
    }

    private fun preferListen(url: String): Boolean {
        return !videoWanted && !FlvListenPlayer.looksLikeHls(url)
    }

    private fun stopAll() {
        listen?.stop()
        listen = null
        usingListen = false
        if (nativeReady) nativeStop(nativeHandle)
    }

    private fun lastOpenError(): String {
        val l = listen?.lastError
        if (!l.isNullOrEmpty()) return l
        if (nativeReady) {
            val e = nativeLastError(nativeHandle)
            if (e.isNotEmpty()) return e
        }
        return "open failed"
    }

    private fun openCurrent(url: String, headers: String?): Boolean {
        stopAll()
        if (preferListen(url)) {
            val p = FlvListenPlayer()
            p.setLatency(latencyTarget, latencyMax)
            p.prepare(url, headers)
            listen = p
            usingListen = true
            return true
        }
        if (!nativeReady) return false
        usingListen = false
        nativeSetVideoEnabled(nativeHandle, videoWanted)
        nativeSetLatency(nativeHandle, latencyTarget, latencyMax)
        return nativeOpen(nativeHandle, url, headers)
    }

    private fun playCurrent(): Boolean {
        if (usingListen) {
            val p = listen ?: return false
            if (p.start()) return true
            // Not FLV / connect failed — fall back to FFmpeg if present.
            val url = pendingUrl ?: return false
            listen?.stop()
            listen = null
            usingListen = false
            if (!nativeReady) return false
            nativeSetVideoEnabled(nativeHandle, videoWanted)
            nativeSetLatency(nativeHandle, latencyTarget, latencyMax)
            if (!nativeOpen(nativeHandle, url, pendingHeaders)) return false
            return nativePlay(nativeHandle)
        }
        if (!nativeReady) return false
        return nativePlay(nativeHandle)
    }

    private fun snapshotStats(): HashMap<String, Any> {
        val stats = HashMap<String, Any>(
            mapOf(
                "textureId" to (textureEntry?.id() ?: -1L),
                "videoFrames" to 0L,
                "presentOk" to 0L,
                "audioFrames" to 0L,
                "decodeHw" to -1,
                "presentMode" to 0,
                "lastError" to if (nativeReady || usingListen) "" else "android native not loaded",
                "droppedFrames" to 0L,
                "bytesRead" to 0L,
                "lagMs" to 0L,
                "audioQueueMs" to 0,
                "videoWidth" to 0,
                "videoHeight" to 0,
            )
        )
        val p = listen
        if (usingListen && p != null) {
            stats["audioFrames"] = p.audioFrames.get()
            stats["droppedFrames"] = p.droppedFrames.get()
            stats["bytesRead"] = p.bytesRead.get()
            stats["audioQueueMs"] = p.audioQueueMs.get()
            stats["decodeHw"] = p.decodeHw.get()
            stats["lagMs"] = p.audioQueueMs.get().toLong()
            stats["lastError"] = p.lastError
            stats["presentMode"] = 0
            stats["textureId"] = textureEntry?.id() ?: -1L
            return stats
        }
        if (nativeReady) {
            nativeFillStats(nativeHandle, stats)
            stats["textureId"] = textureEntry?.id() ?: -1L
            val vw = (stats["videoWidth"] as? Number)?.toInt() ?: 0
            val vh = (stats["videoHeight"] as? Number)?.toInt() ?: 0
            if (vw > 0 && vh > 0 && (vw != lastBufW || vh != lastBufH)) {
                mainHandler.post {
                    try {
                        textureEntry?.surfaceTexture()?.setDefaultBufferSize(vw, vh)
                        lastBufW = vw
                        lastBufH = vh
                    } catch (_: Throwable) {
                    }
                }
            }
        }
        return stats
    }

    /** Run on native worker and wait so Surface is bound before open returns to Dart. */
    private fun awaitNative(block: () -> Unit) {
        val done = java.util.concurrent.CountDownLatch(1)
        var error: Throwable? = null
        nativeExecutor.execute {
            try {
                block()
            } catch (t: Throwable) {
                error = t
            } finally {
                done.countDown()
            }
        }
        try {
            done.await(3, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        error?.let { throw it }
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

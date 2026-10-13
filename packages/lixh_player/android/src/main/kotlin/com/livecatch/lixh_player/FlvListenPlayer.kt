package com.livecatch.lixh_player

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Listen-only: HTTP-FLV demux + MediaCodec AAC + AudioTrack.
 * No FFmpeg. Picture stays on the native FFmpeg path.
 */
class FlvListenPlayer {
    @Volatile
    var lastError: String = ""
        private set

    val audioFrames = AtomicLong(0)
    val bytesRead = AtomicLong(0)
    val droppedFrames = AtomicLong(0)
    val audioQueueMs = AtomicInteger(0)
    val decodeHw = AtomicInteger(1)

    private val running = AtomicBoolean(false)
    private var worker: Thread? = null
    @Volatile
    private var url: String = ""
    @Volatile
    private var headers: String? = null
    @Volatile
    private var maxQueueMs: Int = 50

    fun setLatency(targetMs: Int, maxMs: Int) {
        val t = targetMs.coerceAtLeast(30)
        maxQueueMs = (t + t / 2).coerceIn(40, 120)
    }

    fun prepare(url: String, headers: String?) {
        this.url = url
        this.headers = headers
        lastError = ""
    }

    /** @return false if the URL is not HTTP-FLV (caller may fall back to FFmpeg). */
    fun start(): Boolean {
        stop()
        if (url.isEmpty()) {
            lastError = "no url"
            return false
        }
        var conn: HttpURLConnection? = null
        try {
            conn = openConn(url, headers)
            val ins = BufferedInputStream(conn.inputStream, 16 * 1024)
            if (!readFlvHeader(ins)) {
                lastError = "not flv"
                conn.disconnect()
                return false
            }
            running.set(true)
            val held = conn
            worker = Thread({
                try {
                    runLoop(held, ins)
                } catch (t: Throwable) {
                    lastError = t.message ?: t.toString()
                    Log.w(TAG, "listen loop", t)
                } finally {
                    running.set(false)
                    try {
                        held.disconnect()
                    } catch (_: Throwable) {
                    }
                }
            }, "lixh-flv-listen").apply {
                isDaemon = true
                start()
            }
            conn = null
            return true
        } catch (t: Throwable) {
            lastError = t.message ?: t.toString()
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
            return false
        }
    }

    fun stop() {
        running.set(false)
        worker?.interrupt()
        try {
            worker?.join(1500)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        worker = null
    }

    fun isRunning(): Boolean = running.get()

    private fun u24(b: ByteArray, off: Int): Int {
        return ((b[off].toInt() and 0xff) shl 16) or
            ((b[off + 1].toInt() and 0xff) shl 8) or
            (b[off + 2].toInt() and 0xff)
    }

    private fun runLoop(@Suppress("UNUSED_PARAMETER") conn: HttpURLConnection, ins: InputStream) {
        var codec: MediaCodec? = null
        var track: AudioTrack? = null
        try {
            val info = MediaCodec.BufferInfo()
            var sampleRate = 44100
            var channels = 2
            var pcmWritten = 0L
            val hdr = ByteArray(11)
            while (running.get() && !Thread.currentThread().isInterrupted) {
                if (!readFully(ins, hdr, 0, 11)) break
                val tagType = hdr[0].toInt() and 0xff
                val dataSize = u24(hdr, 1)
                if (dataSize < 0 || dataSize > 2_000_000) {
                    lastError = "bad flv tag"
                    break
                }
                val payload = if (dataSize > 0) ByteArray(dataSize) else EMPTY
                if (dataSize > 0 && !readFully(ins, payload, 0, dataSize)) break
                val prev = ByteArray(4)
                if (!readFully(ins, prev, 0, 4)) break

                if (tagType != 8) {
                    // 9=video 18=script — listen-only discards.
                    continue
                }
                if (payload.size < 2) continue
                val soundFormat = (payload[0].toInt() and 0xff) ushr 4
                if (soundFormat != 10) continue // AAC only
                val pktType = payload[1].toInt() and 0xff
                val aac = payload.copyOfRange(2, payload.size)
                if (pktType == 0) {
                    if (aac.isEmpty()) continue
                    val parsed = parseAsc(aac)
                    sampleRate = parsed.first
                    channels = parsed.second
                    codec?.stop()
                    codec?.release()
                    codec = openAacCodec(aac, sampleRate, channels)
                    continue
                }
                val dec = codec ?: continue
                val inIx = dec.dequeueInputBuffer(5_000)
                if (inIx >= 0) {
                    val buf = dec.getInputBuffer(inIx)
                    if (buf != null) {
                        buf.clear()
                        buf.put(aac)
                        dec.queueInputBuffer(inIx, 0, aac.size, 0, 0)
                    }
                }
                while (true) {
                    val outIx = dec.dequeueOutputBuffer(info, 0)
                    if (outIx == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    if (outIx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val fmt = dec.outputFormat
                        sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        track?.release()
                        track = openTrack(sampleRate, channels)
                        continue
                    }
                    if (outIx < 0) continue
                    val out = dec.getOutputBuffer(outIx)
                    if (out != null && info.size > 0 && track != null) {
                        val pcm = ByteArray(info.size)
                        out.position(info.offset)
                        out.get(pcm)
                        val qms = queuedMs(track, pcmWritten, sampleRate)
                        audioQueueMs.set(qms)
                        if (qms > maxQueueMs) {
                            droppedFrames.addAndGet(1)
                        } else {
                            val n = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
                            if (n > 0) {
                                pcmWritten += n / (2 * channels.coerceAtLeast(1))
                                audioFrames.addAndGet(1)
                            }
                        }
                    }
                    dec.releaseOutputBuffer(outIx, false)
                }
            }
        } finally {
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            try {
                codec?.release()
            } catch (_: Throwable) {
            }
            try {
                track?.pause()
                track?.flush()
                track?.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun queuedMs(track: AudioTrack?, writtenFrames: Long, rate: Int): Int {
        if (track == null || rate <= 0) return 0
        val head = track.playbackHeadPosition.toLong() and 0xffffffffL
        val q = (writtenFrames - head).coerceAtLeast(0)
        return ((q * 1000L) / rate).toInt()
    }

    private fun openAacCodec(asc: ByteArray, rate: Int, ch: Int): MediaCodec {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, ch)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(asc))
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096)
        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, 0)
        codec.start()
        decodeHw.set(1)
        return codec
    }

    private fun openTrack(rate: Int, ch: Int): AudioTrack {
        val channelMask =
            if (ch >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val min = AudioTrack.getMinBufferSize(rate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        val want = (rate * ch.coerceAtLeast(1) * 2 * maxQueueMs / 1000).coerceAtLeast(min)
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(rate)
            .setChannelMask(channelMask)
            .build()
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(fmt)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(want)
        if (Build.VERSION.SDK_INT >= 26) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val track = builder.build()
        track.play()
        return track
    }

    private fun readFlvHeader(ins: InputStream): Boolean {
        val h = ByteArray(9)
        if (!readFully(ins, h, 0, 9)) return false
        if (h[0] != 0x46.toByte() || h[1] != 0x4C.toByte() || h[2] != 0x56.toByte()) {
            return false
        }
        val extra = ((h[5].toInt() and 0xff) shl 24) or
            ((h[6].toInt() and 0xff) shl 16) or
            ((h[7].toInt() and 0xff) shl 8) or
            (h[8].toInt() and 0xff)
        val skip = extra - 9
        if (skip > 0) {
            val junk = ByteArray(skip)
            if (!readFully(ins, junk, 0, skip)) return false
        }
        val prev = ByteArray(4)
        return readFully(ins, prev, 0, 4)
    }

    private fun readFully(ins: InputStream, buf: ByteArray, off: Int, len: Int): Boolean {
        var n = 0
        while (n < len) {
            if (Thread.currentThread().isInterrupted) return false
            val r = ins.read(buf, off + n, len - n)
            if (r < 0) return false
            n += r
            bytesRead.addAndGet(r.toLong())
        }
        return n == len
    }

    companion object {
        private const val TAG = "lixh-flv"
        private val EMPTY = ByteArray(0)
        private val RATES = intArrayOf(
            96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
            16000, 12000, 11025, 8000, 7350, 0, 0, 0
        )

        fun looksLikeHls(url: String): Boolean {
            val u = url.lowercase()
            return u.contains(".m3u8") || u.contains("m3u8")
        }

        fun openConn(url: String, headers: String?): HttpURLConnection {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 4000
            conn.readTimeout = 8000
            conn.instanceFollowRedirects = true
            conn.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36"
            )
            conn.setRequestProperty("Accept", "*/*")
            conn.setRequestProperty("Connection", "keep-alive")
            if (!headers.isNullOrBlank()) {
                for (line in headers.split("\r\n", "\n")) {
                    val i = line.indexOf(':')
                    if (i > 0) {
                        conn.setRequestProperty(line.substring(0, i).trim(), line.substring(i + 1).trim())
                    }
                }
            } else if (!conn.requestProperties.containsKey("Referer")) {
                conn.setRequestProperty("Referer", "https://live.douyin.com/")
            }
            conn.connect()
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("http $code")
            }
            return conn
        }

        fun parseAsc(asc: ByteArray): Pair<Int, Int> {
            val bits = BitReader(asc)
            var objType = bits.read(5)
            if (objType == 31) objType = 32 + bits.read(6)
            val freqIdx = bits.read(4)
            val rate = if (freqIdx == 15) bits.read(24) else RATES.getOrElse(freqIdx) { 44100 }
            val chCfg = bits.read(4)
            val ch = when (chCfg) {
                1 -> 1
                0 -> 2
                else -> chCfg.coerceIn(1, 8)
            }
            if (rate <= 0) return 44100 to 2
            return rate to ch
        }
    }

    private class BitReader(private val data: ByteArray) {
        private var bitPos = 0
        fun read(n: Int): Int {
            var v = 0
            repeat(n) {
                val byte = data.getOrElse(bitPos / 8) { 0 }.toInt() and 0xff
                val bit = (byte shr (7 - (bitPos % 8))) and 1
                v = (v shl 1) or bit
                bitPos++
            }
            return v
        }
    }
}

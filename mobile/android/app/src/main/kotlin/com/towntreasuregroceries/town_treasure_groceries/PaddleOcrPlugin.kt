package com.towntreasuregroceries.town_treasure_groceries

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import java.util.Collections
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Offline PP-OCRv5 Mobile ONNX inference engine for Android.
 * Runs DBNet text detection + skew-aware rotated cropping + SVTR/CTC recognition
 * completely offline on a dedicated background executor.
 */
class PaddleOcrPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.towntreasuregroceries/paddle_ocr"
        private const val DET_ASSET = "assets/ocr/det.onnx"
        private const val REC_ASSET = "assets/ocr/rec.onnx"
        private const val DICT_ASSET = "assets/ocr/dict.txt"
        private const val MAX_DET_SIDE = 960
        private const val DET_THRESH = 0.30f
        private const val BOX_SCORE_THRESH = 0.45f
        private const val UNCLIP_RATIO = 1.55f
        private const val REC_HEIGHT = 48
        private const val REC_MAX_WIDTH = 640
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val initLock = Any()

    private var env: OrtEnvironment? = null
    private var detSession: OrtSession? = null
    private var recSession: OrtSession? = null
    private var chars: List<String> = emptyList()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognizeFile" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "Missing filePath", null)
                    return
                }
                executor.execute {
                    try {
                        val output = recognizeImageFile(filePath)
                        mainHandler.post { result.success(output) }
                    } catch (e: Throwable) {
                        mainHandler.post {
                            result.error(
                                "OCR_ERROR",
                                e.message ?: e.javaClass.simpleName,
                                null
                            )
                        }
                    }
                }
            }
            "dispose" -> {
                executor.execute {
                    closeSessions()
                    mainHandler.post { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureInitialized() {
        synchronized(initLock) {
            if (detSession != null && recSession != null && chars.isNotEmpty()) {
                return
            }
            val ocrDir = File(context.filesDir, "ocr_v5").apply { mkdirs() }
            val detFile = ensureAssetFile(DET_ASSET, File(ocrDir, "det.onnx"))
            val recFile = ensureAssetFile(REC_ASSET, File(ocrDir, "rec.onnx"))
            val dictFile = ensureAssetFile(DICT_ASSET, File(ocrDir, "dict.txt"))

            val ortEnv = OrtEnvironment.getEnvironment()
            val opts = OrtSession.SessionOptions().apply {
                setIntraOpNumThreads(2)
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            }
            detSession = ortEnv.createSession(detFile.absolutePath, opts)
            recSession = ortEnv.createSession(recFile.absolutePath, opts)
            env = ortEnv

            val dictLines = dictFile.readLines(Charsets.UTF_8)
                .map { it.trimEnd('\r', '\n') }
            val vocab = ArrayList<String>(dictLines.size + 2)
            vocab.add("") // index 0: CTC blank
            vocab.addAll(dictLines)
            vocab.add(" ") // final index: space char
            chars = vocab
        }
    }

    private fun ensureAssetFile(assetPath: String, target: File): File {
        val loader = FlutterInjector.instance().flutterLoader()
        val lookupKey = loader.getLookupKeyForAsset(assetPath)
        context.assets.open(lookupKey).use { input ->
            val available = input.available().toLong()
            if (target.exists() && target.length() > 0 && (available <= 0 || target.length() == available)) {
                return target
            }
            FileOutputStream(target).use { output ->
                input.copyTo(output)
            }
        }
        return target
    }

    fun closeSessions() {
        synchronized(initLock) {
            try { detSession?.close() } catch (_: Throwable) {}
            try { recSession?.close() } catch (_: Throwable) {}
            detSession = null
            recSession = null
        }
    }

    private data class Component(
        val xs: IntArray,
        val ys: IntArray,
        val count: Int,
        val pcaAngleDeg: Float,
        val majorLen: Float,
        val minorLen: Float
    )

    private fun recognizeImageFile(filePath: String): List<Map<String, Any>> {
        ensureInitialized()
        val ortEnv = env ?: throw IllegalStateException("ONNX environment unavailable")
        val det = detSession ?: throw IllegalStateException("Detection model unavailable")
        val rec = recSession ?: throw IllegalStateException("Recognition model unavailable")

        val bitmap = decodeOrientedBitmap(filePath)
            ?: throw IllegalArgumentException("Could not decode image: $filePath")

        try {
            val origW = bitmap.width
            val origH = bitmap.height
            val ratio = min(MAX_DET_SIDE.toFloat() / max(origW, origH).toFloat(), 1.0f)
            val detW = max(32, ((origW * ratio / 32f).roundToInt() * 32))
            val detH = max(32, ((origH * ratio / 32f).roundToInt() * 32))
            val sx = origW.toFloat() / detW.toFloat()
            val sy = origH.toFloat() / detH.toFloat()

            val detBitmap = if (detW == origW && detH == origH) {
                bitmap
            } else {
                Bitmap.createScaledBitmap(bitmap, detW, detH, true)
            }

            val detInputData = bitmapToDetFloatBuffer(detBitmap, detW, detH)
            if (detBitmap !== bitmap) {
                detBitmap.recycle()
            }

            val detInputName = det.inputNames.iterator().next()
            val detShape = longArrayOf(1, 3, detH.toLong(), detW.toLong())
            val probMap = OnnxTensor.createTensor(ortEnv, detInputData, detShape).use { tensor ->
                det.run(Collections.singletonMap(detInputName, tensor)).use { results ->
                    val raw = results[0].value as Array<Array<Array<FloatArray>>>
                    val outH = raw[0][0].size
                    val outW = raw[0][0][0].size
                    val flat = FloatArray(outH * outW)
                    for (y in 0 until outH) {
                        System.arraycopy(raw[0][0][y], 0, flat, y * outW, outW)
                    }
                    Triple(flat, outW, outH)
                }
            }

            val pred = probMap.first
            val mapW = probMap.second
            val mapH = probMap.third
            val components = extractComponents(pred, mapW, mapH)
            if (components.isEmpty()) return emptyList()

            // Estimate dominant skew angle from elongated text lines (-45..+45 deg)
            val wideAngles = components
                .filter { it.majorLen >= 3.0f * max(1.0f, it.minorLen) && it.majorLen >= 24f }
                .map { normalizeHorizontalAngle(it.pcaAngleDeg) }
                .sorted()
            val pageSkewDeg = if (wideAngles.isNotEmpty()) {
                wideAngles[wideAngles.size / 2]
            } else {
                0f
            }

            val resultsList = ArrayList<Map<String, Any>>()
            val recInputName = rec.inputNames.iterator().next()

            for (comp in components) {
                val aspect = comp.majorLen / max(1f, comp.minorLen)
                val angleDeg = if (aspect >= 2.3f) {
                    val norm = normalizeHorizontalAngle(comp.pcaAngleDeg)
                    if (abs(norm - pageSkewDeg) <= 18f || wideAngles.isEmpty()) norm else pageSkewDeg
                } else {
                    pageSkewDeg
                }

                val rad = Math.toRadians(angleDeg.toDouble())
                val cosA = cos(rad).toFloat()
                val sinA = sin(rad).toFloat()

                var minU = Float.POSITIVE_INFINITY
                var maxU = Float.NEGATIVE_INFINITY
                var minV = Float.POSITIVE_INFINITY
                var maxV = Float.NEGATIVE_INFINITY

                for (i in 0 until comp.count) {
                    val px = comp.xs[i].toFloat()
                    val py = comp.ys[i].toFloat()
                    val u = px * cosA + py * sinA
                    val v = -px * sinA + py * cosA
                    if (u < minU) minU = u
                    if (u > maxU) maxU = u
                    if (v < minV) minV = v
                    if (v > maxV) maxV = v
                }

                val bw = maxU - minU
                val bh = maxV - minV
                if (bw < 3f || bh < 3f) continue

                // Score directly inside the oriented bounding box bounds on pred map
                val minXBound = max(0, floorMinX(minU, maxU, minV, maxV, cosA, sinA))
                val maxXBound = min(mapW - 1, ceilMaxX(minU, maxU, minV, maxV, cosA, sinA))
                val minYBound = max(0, floorMinY(minU, maxU, minV, maxV, cosA, sinA))
                val maxYBound = min(mapH - 1, ceilMaxY(minU, maxU, minV, maxV, cosA, sinA))

                var scoreSum = 0f
                var scoreCount = 0
                for (yy in minYBound..maxYBound) {
                    val rowOff = yy * mapW
                    for (xx in minXBound..maxXBound) {
                        val u = xx * cosA + yy * sinA
                        val v = -xx * sinA + yy * cosA
                        if (u in minU..maxU && v in minV..maxV) {
                            scoreSum += pred[rowOff + xx]
                            scoreCount++
                        }
                    }
                }
                val score = if (scoreCount > 0) scoreSum / scoreCount else 0f
                if (score < BOX_SCORE_THRESH) continue

                // DBNet unclip expansion
                val expand = (bw * bh) * UNCLIP_RATIO / (2f * (bw + bh))
                val u0 = minU - expand
                val u1 = maxU + expand
                val v0 = minV - expand * 0.85f
                val v1 = maxV + expand * 0.85f

                val centerU = (u0 + u1) * 0.5f
                val centerV = (v0 + v1) * 0.5f
                val centerXOrig = (centerU * cosA - centerV * sinA) * sx
                val centerYOrig = (centerU * sinA + centerV * cosA) * sy
                val boxWOrig = max(8f, (u1 - u0) * ((sx + sy) * 0.5f))
                val boxHOrig = max(8f, (v1 - v0) * ((sx + sy) * 0.5f))

                val crop = cropRotatedBox(
                    bitmap,
                    centerXOrig,
                    centerYOrig,
                    boxWOrig,
                    boxHOrig,
                    angleDeg
                ) ?: continue

                val recPair = runRecognition(ortEnv, rec, recInputName, crop)
                crop.recycle()
                val recognizedText = recPair.first.trim()
                val recConf = recPair.second
                if (recognizedText.isEmpty()) continue

                resultsList.add(
                    hashMapOf(
                        "text" to recognizedText,
                        "confidence" to recConf.toDouble(),
                        "centerX" to centerXOrig.toDouble(),
                        "centerY" to centerYOrig.toDouble(),
                        "width" to boxWOrig.toDouble(),
                        "height" to boxHOrig.toDouble(),
                        "angle" to angleDeg.toDouble(),
                        "left" to (centerXOrig - boxWOrig * 0.5f).toDouble(),
                        "top" to (centerYOrig - boxHOrig * 0.5f).toDouble(),
                        "right" to (centerXOrig + boxWOrig * 0.5f).toDouble(),
                        "bottom" to (centerYOrig + boxHOrig * 0.5f).toDouble()
                    )
                )
            }

            return resultsList
        } finally {
            bitmap.recycle()
        }
    }

    private fun runRecognition(
        ortEnv: OrtEnvironment,
        rec: OrtSession,
        inputName: String,
        crop: Bitmap
    ): Pair<String, Float> {
        val h = crop.height
        val w = crop.width
        val targetW = min(
            REC_MAX_WIDTH,
            max(16, ceil(w.toDouble() * (REC_HEIGHT.toDouble() / max(1, h))).toInt())
        )
        val resized = if (w == targetW && h == REC_HEIGHT) {
            crop
        } else {
            Bitmap.createScaledBitmap(crop, targetW, REC_HEIGHT, true)
        }
        val recBuf = bitmapToRecFloatBuffer(resized, targetW, REC_HEIGHT)
        if (resized !== crop) resized.recycle()

        val recShape = longArrayOf(1, 3, REC_HEIGHT.toLong(), targetW.toLong())
        return OnnxTensor.createTensor(ortEnv, recBuf, recShape).use { tensor ->
            rec.run(Collections.singletonMap(inputName, tensor)).use { results ->
                val raw = results[0].value as Array<Array<FloatArray>>
                val steps = raw[0]
                val sb = StringBuilder()
                var confSum = 0f
                var confCount = 0
                var prevIdx = -1

                for (t in steps.indices) {
                    val probs = steps[t]
                    var bestIdx = 0
                    var bestVal = probs[0]
                    for (c in 1 until probs.size) {
                        if (probs[c] > bestVal) {
                            bestVal = probs[c]
                            bestIdx = c
                        }
                    }
                    if (bestIdx != 0 && bestIdx != prevIdx && bestIdx < chars.size) {
                        sb.append(chars[bestIdx])
                        confSum += bestVal
                        confCount++
                    }
                    prevIdx = bestIdx
                }
                val avgConf = if (confCount > 0) confSum / confCount else 0f
                Pair(sb.toString(), avgConf)
            }
        }
    }

    private fun extractComponents(pred: FloatArray, w: Int, h: Int): List<Component> {
        val visited = BooleanArray(w * h)
        val queue = IntArray(w * h)
        val components = ArrayList<Component>()
        val dx = intArrayOf(1, -1, 0, 0, 1, 1, -1, -1)
        val dy = intArrayOf(0, 0, 1, -1, 1, -1, 1, -1)

        for (y in 0 until h) {
            for (x in 0 until w) {
                val startIdx = y * w + x
                if (visited[startIdx] || pred[startIdx] <= DET_THRESH) continue

                var head = 0
                var tail = 0
                queue[tail++] = startIdx
                visited[startIdx] = true

                while (head < tail) {
                    val cur = queue[head++]
                    val cx = cur % w
                    val cy = cur / w
                    for (k in 0 until 8) {
                        val nx = cx + dx[k]
                        val ny = cy + dy[k]
                        if (nx in 0 until w && ny in 0 until h) {
                            val nIdx = ny * w + nx
                            if (!visited[nIdx] && pred[nIdx] > DET_THRESH) {
                                visited[nIdx] = true
                                queue[tail++] = nIdx
                            }
                        }
                    }
                }

                if (tail < 6) continue

                val xs = IntArray(tail)
                val ys = IntArray(tail)
                var sumX = 0.0
                var sumY = 0.0
                var minX = w
                var maxX = 0
                var minY = h
                var maxY = 0

                for (i in 0 until tail) {
                    val pIdx = queue[i]
                    val px = pIdx % w
                    val py = pIdx / w
                    xs[i] = px
                    ys[i] = py
                    sumX += px
                    sumY += py
                    if (px < minX) minX = px
                    if (px > maxX) maxX = px
                    if (py < minY) minY = py
                    if (py > maxY) maxY = py
                }

                val spanX = (maxX - minX + 1).toFloat()
                val spanY = (maxY - minY + 1).toFloat()
                if (spanX < 3f || spanY < 3f) continue

                val meanX = sumX / tail
                val meanY = sumY / tail
                var cxx = 0.0
                var cyy = 0.0
                var cxy = 0.0
                for (i in 0 until tail) {
                    val ux = xs[i] - meanX
                    val uy = ys[i] - meanY
                    cxx += ux * ux
                    cyy += uy * uy
                    cxy += ux * uy
                }
                val angleRad = 0.5 * atan2(2.0 * cxy, cxx - cyy)
                val angleDeg = Math.toDegrees(angleRad).toFloat()

                // Project onto PCA major/minor axes to find clean extent
                val ca = cos(angleRad).toFloat()
                val sa = sin(angleRad).toFloat()
                var uMin = Float.POSITIVE_INFINITY
                var uMax = Float.NEGATIVE_INFINITY
                var vMin = Float.POSITIVE_INFINITY
                var vMax = Float.NEGATIVE_INFINITY
                for (i in 0 until tail) {
                    val u = xs[i] * ca + ys[i] * sa
                    val v = -xs[i] * sa + ys[i] * ca
                    if (u < uMin) uMin = u
                    if (u > uMax) uMax = u
                    if (v < vMin) vMin = v
                    if (v > vMax) vMax = v
                }

                components.add(
                    Component(
                        xs = xs,
                        ys = ys,
                        count = tail,
                        pcaAngleDeg = angleDeg,
                        majorLen = max(uMax - uMin, vMax - vMin),
                        minorLen = min(uMax - uMin, vMax - vMin)
                    )
                )
            }
        }
        return components
    }

    private fun normalizeHorizontalAngle(rawDeg: Float): Float {
        var a = rawDeg % 180f
        if (a > 90f) a -= 180f
        if (a < -90f) a += 180f
        if (a > 45f) a -= 90f
        if (a < -45f) a += 90f
        return a
    }

    private fun cropRotatedBox(
        src: Bitmap,
        centerX: Float,
        centerY: Float,
        boxW: Float,
        boxH: Float,
        angleDeg: Float
    ): Bitmap? {
        val outW = boxW.roundToInt().coerceIn(8, 2400)
        val outH = boxH.roundToInt().coerceIn(8, 1200)
        val result = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        canvas.drawColor(android.graphics.Color.WHITE)

        val matrix = Matrix().apply {
            postTranslate(-centerX, -centerY)
            postRotate(-angleDeg)
            postTranslate(outW * 0.5f, outH * 0.5f)
        }
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        canvas.drawBitmap(src, matrix, paint)
        return result
    }

    private fun decodeOrientedBitmap(filePath: String): Bitmap? {
        val opts = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val bmp = BitmapFactory.decodeFile(filePath, opts) ?: return null
        val orientation = try {
            ExifInterface(filePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (_: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val deg = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (deg == 0f) return bmp
        val m = Matrix().apply { postRotate(deg) }
        val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        if (rotated !== bmp) bmp.recycle()
        return rotated
    }

    private fun bitmapToDetFloatBuffer(bmp: Bitmap, w: Int, h: Int): FloatBuffer {
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)
        val buf = FloatBuffer.allocate(3 * w * h)
        val plane = w * h
        val meanB = 0.485f
        val meanG = 0.456f
        val meanR = 0.406f
        val stdB = 0.229f
        val stdG = 0.224f
        val stdR = 0.225f

        for (i in 0 until plane) {
            val c = pixels[i]
            val r = ((c shr 16) and 0xFF) / 255f
            val g = ((c shr 8) and 0xFF) / 255f
            val b = (c and 0xFF) / 255f
            buf.put(i, (b - meanB) / stdB)
            buf.put(plane + i, (g - meanG) / stdG)
            buf.put(2 * plane + i, (r - meanR) / stdR)
        }
        buf.rewind()
        return buf
    }

    private fun bitmapToRecFloatBuffer(bmp: Bitmap, w: Int, h: Int): FloatBuffer {
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)
        val buf = FloatBuffer.allocate(3 * w * h)
        val plane = w * h
        for (i in 0 until plane) {
            val c = pixels[i]
            val r = (((c shr 16) and 0xFF) / 255f - 0.5f) / 0.5f
            val g = (((c shr 8) and 0xFF) / 255f - 0.5f) / 0.5f
            val b = ((c and 0xFF) / 255f - 0.5f) / 0.5f
            buf.put(i, b)
            buf.put(plane + i, g)
            buf.put(2 * plane + i, r)
        }
        buf.rewind()
        return buf
    }

    private fun floorMinX(u0: Float, u1: Float, v0: Float, v1: Float, c: Float, s: Float): Int {
        val m = minOf(
            minOf(u0 * c - v0 * s, u1 * c - v0 * s),
            minOf(u0 * c - v1 * s, u1 * c - v1 * s)
        )
        return m.toInt() - 1
    }

    private fun ceilMaxX(u0: Float, u1: Float, v0: Float, v1: Float, c: Float, s: Float): Int {
        val m = maxOf(
            maxOf(u0 * c - v0 * s, u1 * c - v0 * s),
            maxOf(u0 * c - v1 * s, u1 * c - v1 * s)
        )
        return ceil(m.toDouble()).toInt() + 1
    }

    private fun floorMinY(u0: Float, u1: Float, v0: Float, v1: Float, c: Float, s: Float): Int {
        val m = minOf(
            minOf(u0 * s + v0 * c, u1 * s + v0 * c),
            minOf(u0 * s + v1 * c, u1 * s + v1 * c)
        )
        return m.toInt() - 1
    }

    private fun ceilMaxY(u0: Float, u1: Float, v0: Float, v1: Float, c: Float, s: Float): Int {
        val m = maxOf(
            maxOf(u0 * s + v0 * c, u1 * s + v0 * c),
            maxOf(u0 * s + v1 * c, u1 * s + v1 * c)
        )
        return ceil(m.toDouble()).toInt() + 1
    }
}

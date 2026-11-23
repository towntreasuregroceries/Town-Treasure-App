package com.towntreasuregroceries.town_treasure_groceries

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.min

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val PDF_CHANNEL = "com.towntreasuregroceries/pdf_picker"
        private const val REQ_PICK_PDF = 4109
        private const val REQ_PICK_RAW_DOC = 4110
        private const val MAX_PDF_PAGES = 12
        private const val MAX_PAGE_WIDTH = 2000
        private const val MAX_RAW_DOC_BYTES = 20 * 1024 * 1024
    }

    private var pendingPdfResult: MethodChannel.Result? = null
    private var pendingRawDocResult: MethodChannel.Result? = null
    private val pdfExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun clearStalePendingResults() {
        pendingPdfResult?.let { stale ->
            pendingPdfResult = null
            runCatching { stale.success(emptyList<Map<String, Any>>()) }
        }
        pendingRawDocResult?.let { stale ->
            pendingRawDocResult = null
            runCatching { stale.success(null) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PDF_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickAndRenderPdf" -> {
                    clearStalePendingResults()
                    pendingPdfResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            type = "application/pdf"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
                        }
                        startActivityForResult(intent, REQ_PICK_PDF)
                    } catch (e: Throwable) {
                        pendingPdfResult = null
                        result.error("PICKER_ERROR", e.message ?: "Could not open PDF picker", null)
                    }
                }
                "pickRawDocument" -> {
                    clearStalePendingResults()
                    pendingRawDocResult = result
                    val mimeTypes = arrayOf("application/pdf", "image/*", "text/plain")
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
                        }
                        startActivityForResult(intent, REQ_PICK_RAW_DOC)
                    } catch (_: ActivityNotFoundException) {
                        try {
                            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                type = "*/*"
                                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
                            }
                            startActivityForResult(fallback, REQ_PICK_RAW_DOC)
                        } catch (e: Throwable) {
                            pendingRawDocResult = null
                            result.error("PICKER_ERROR", e.message ?: "Could not open file picker", null)
                        }
                    } catch (e: Throwable) {
                        pendingRawDocResult = null
                        result.error("PICKER_ERROR", e.message ?: "Could not open file picker", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_PDF) {
            val res = pendingPdfResult
            pendingPdfResult = null
            if (res == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res.success(emptyList<Map<String, Any>>())
                return
            }
            val uri = data.data!!
            pdfExecutor.execute {
                try {
                    val pages = renderPdfUriToJpegs(uri)
                    mainHandler.post { res.success(pages) }
                } catch (e: Throwable) {
                    mainHandler.post {
                        res.error("PDF_RENDER_ERROR", e.message ?: "Could not read PDF", null)
                    }
                }
            }
            return
        }
        if (requestCode == REQ_PICK_RAW_DOC) {
            val res = pendingRawDocResult
            pendingRawDocResult = null
            if (res == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res.success(null)
                return
            }
            val uri = data.data!!
            pdfExecutor.execute {
                try {
                    val docMap = readRawDocumentUri(uri)
                    mainHandler.post { res.success(docMap) }
                } catch (e: Throwable) {
                    mainHandler.post {
                        res.error("DOC_READ_ERROR", e.message ?: "Could not read selected file", null)
                    }
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun readRawDocumentUri(uri: Uri): Map<String, Any> {
        var displayName = "document"
        runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) displayName = name
                    }
                }
            }
        }
        val mimeType = contentResolver.getType(uri) ?: if (displayName.lowercase().endsWith(".pdf")) {
            "application/pdf"
        } else {
            "application/octet-stream"
        }
        val stream = contentResolver.openInputStream(uri)
            ?: contentResolver.openAssetFileDescriptor(uri, "r")?.createInputStream()
            ?: throw IllegalStateException("Could not open the selected document.")
        val bytes = stream.use { input ->
            val baos = ByteArrayOutputStream()
            val buf = ByteArray(16384)
            var total = 0
            while (true) {
                val read = input.read(buf)
                if (read <= 0) break
                total += read
                if (total > MAX_RAW_DOC_BYTES) {
                    throw IllegalStateException("Selected document exceeds the 20 MB size limit.")
                }
                baos.write(buf, 0, read)
            }
            baos.toByteArray()
        }
        if (bytes.isEmpty()) {
            throw IllegalStateException("Selected document is empty.")
        }
        return hashMapOf(
            "fileName" to displayName,
            "mimeType" to mimeType,
            "bytes" to bytes
        )
    }

    private fun renderPdfUriToJpegs(uri: Uri): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val pfd = contentResolver.openFileDescriptor(uri, "r")
            ?: throw IllegalStateException("Could not open selected PDF file.")
        pfd.use { fd ->
            PdfRenderer(fd).use { renderer ->
                val count = min(renderer.pageCount, MAX_PDF_PAGES)
                val ts = System.currentTimeMillis()
                for (i in 0 until count) {
                    renderer.openPage(i).use { page ->
                        val scale = min(2.6f, MAX_PAGE_WIDTH.toFloat() / page.width.coerceAtLeast(1))
                        val targetW = (page.width * scale).toInt().coerceAtLeast(600)
                        val targetH = (page.height * scale).toInt().coerceAtLeast(600)
                        val bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                        try {
                            Canvas(bitmap).drawColor(Color.WHITE)
                            page.render(
                                bitmap,
                                null,
                                null,
                                PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
                            )
                            val outFile = File(cacheDir, "ttg_pdf_${ts}_p${i + 1}.jpg")
                            val baos = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, baos)
                            val bytes = baos.toByteArray()
                            FileOutputStream(outFile).use { fos -> fos.write(bytes) }
                            out.add(
                                hashMapOf(
                                    "filePath" to outFile.absolutePath,
                                    "bytes" to bytes
                                )
                            )
                        } finally {
                            bitmap.recycle()
                        }
                    }
                }
            }
        }
        return out
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        clearStalePendingResults()
        pdfExecutor.shutdownNow()
        super.onDestroy()
    }
}

package com.towntreasuregroceries.town_treasure_groceries

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
        private const val MAX_PDF_PAGES = 12
        private const val MAX_PAGE_WIDTH = 2000
    }

    private var pendingPdfResult: MethodChannel.Result? = null
    private val pdfExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PDF_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "pickAndRenderPdf") {
                if (pendingPdfResult != null) {
                    result.error("BUSY", "PDF picker already active", null)
                    return@setMethodCallHandler
                }
                pendingPdfResult = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/pdf"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
                    }
                    startActivityForResult(intent, REQ_PICK_PDF)
                } catch (e: Throwable) {
                    pendingPdfResult = null
                    result.error("PICKER_ERROR", e.message ?: "Could not open PDF picker", null)
                }
            } else {
                result.notImplemented()
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
        super.onActivityResult(requestCode, resultCode, data)
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
}

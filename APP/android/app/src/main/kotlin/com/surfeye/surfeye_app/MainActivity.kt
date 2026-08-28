package com.surfeye.surfeye_app

import android.graphics.BitmapFactory
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {

    private val ORIENTATION_CHANNEL = "surfeye/orientation"

    // Live camera preview: fast on-device geometry (no Python, no OpenCV).
    // Only used for the hold-to-preview contour overlay in camera_screen.dart.
    private val PREVIEW_CHANNEL = "com.surfeye/preview"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Auto-rotate query ──────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ORIENTATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "isAutoRotateEnabled") {
                    try {
                        val v = Settings.System.getInt(
                            contentResolver,
                            Settings.System.ACCELEROMETER_ROTATION, 0
                        )
                        result.success(v == 1)
                    } catch (_: Exception) {
                        result.success(true)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // ── App control channel ────────────────────────────────────────────
        // Used for actions like moving the app to the background
        val appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.surfeye/app")
        appChannel.setMethodCallHandler { call, result ->
            if (call.method == "moveToBack") {
                moveTaskToBack(true)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        // ── Lightweight preview analysis (pure Kotlin, no native libs) ─────
        // Decodes the JPEG with Android's built-in BitmapFactory, converts to
        // greyscale, runs a simple edge-density scan to estimate the baseline,
        // then does a naïve circle-fit on the brightest-edge pixels for a fast
        // angle preview.  Accuracy is intentionally approximate — the server
        // does the precise Young-Laplace fit after the user confirms.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PREVIEW_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "previewAnalyze") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val imagePath = call.argument<String>("imagePath")
                if (imagePath == null) {
                    result.error("INVALID_ARGUMENT", "imagePath required", null)
                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        // 1. Decode to greyscale bitmap
                        val opts = BitmapFactory.Options().apply {
                            inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                        }
                        val bmp = BitmapFactory.decodeFile(imagePath, opts)
                            ?: throw Exception("Failed to decode image")

                        val W = bmp.width
                        val H = bmp.height

                        // Build grey pixel array
                        val pixels = IntArray(W * H)
                        bmp.getPixels(pixels, 0, W, 0, 0, W, H)
                        bmp.recycle()

                        fun grey(px: Int): Int {
                            val r = (px shr 16) and 0xFF
                            val g = (px shr 8) and 0xFF
                            val b = px and 0xFF
                            return (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                        }

                        // 2. Simple Sobel-Y edge map (horizontal edges → baseline)
                        val edgeRow = IntArray(H)
                        for (y in 1 until H - 1) {
                            var sum = 0
                            for (x in 1 until W - 1) {
                                val above = grey(pixels[(y - 1) * W + x])
                                val below = grey(pixels[(y + 1) * W + x])
                                sum += abs(below - above)
                            }
                            edgeRow[y] = sum
                        }

                        // 3. Baseline = row with peak horizontal edge energy
                        //    in the lower 60 % of the image
                        val searchStart = (H * 0.4).toInt()
                        var baselineY = H - 10
                        var maxEdge = 0
                        for (y in searchStart until H) {
                            if (edgeRow[y] > maxEdge) {
                                maxEdge = edgeRow[y]
                                baselineY = y
                            }
                        }

                        // 4. Collect "bright-edge" pixels above baseline as a
                        //    proxy contour (Sobel magnitude > threshold)
                        val threshold = (maxEdge * 0.15).toInt().coerceAtLeast(20)
                        val contourPts = mutableListOf<Pair<Double, Double>>()
                        for (y in 0 until baselineY) {
                            if (edgeRow[y] < threshold) continue
                            // Find local bright-edge columns in this row
                            for (x in 1 until W - 1) {
                                val gx = abs(
                                    grey(pixels[y * W + (x + 1)]) -
                                    grey(pixels[y * W + (x - 1)])
                                )
                                val gy = if (y > 0 && y < H - 1) abs(
                                    grey(pixels[(y + 1) * W + x]) -
                                    grey(pixels[(y - 1) * W + x])
                                ) else 0
                                val mag = sqrt((gx * gx + gy * gy).toDouble())
                                if (mag > 30) contourPts.add(x.toDouble() to y.toDouble())
                            }
                        }

                        // 5. Circle fit for approximate contact angle
                        var approxAngle: Double? = null
                        val ptsArray = JSONArray()
                        val step = maxOf(1, contourPts.size / 200)
                        contourPts.forEachIndexed { i, (px, py) ->
                            if (i % step == 0) {
                                val p = JSONArray()
                                p.put(px); p.put(py)
                                ptsArray.put(p)
                            }
                        }

                        val above = contourPts.filter { it.second < baselineY }
                        if (above.size >= 5) {
                            val cx = above.map { it.first }.average()
                            val cy = above.map { it.second }.average()
                            val r = above.map {
                                sqrt((it.first - cx) * (it.first - cx) +
                                     (it.second - cy) * (it.second - cy))
                            }.average()
                            val dY = baselineY - cy
                            val sinTheta = (dY / r).coerceIn(-1.0, 1.0)
                            approxAngle = Math.toDegrees(Math.asin(sinTheta))
                        }

                        val json = JSONObject().apply {
                            put("baseline_y", baselineY)
                            put("detected_baseline_y", baselineY)
                            put("img_width", W)
                            put("img_height", H)
                            put("contour_points", ptsArray)
                            if (approxAngle != null) put("approx_angle", approxAngle)
                        }

                        runOnUiThread { result.success(json.toString()) }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error("PREVIEW_ERROR", e.message, null)
                        }
                    }
                }.start()
            }
    }
}

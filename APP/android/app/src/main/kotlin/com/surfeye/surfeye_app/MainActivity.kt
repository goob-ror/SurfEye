package com.surfeye.surfeye_app

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.opencv.android.OpenCVLoader
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "surfeye/orientation"
    private val PYTHON_CHANNEL = "com.surfeye/python"
    private val PREVIEW_CHANNEL = "com.surfeye/preview"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "isAutoRotateEnabled") {
                    try {
                        val autoRotate = Settings.System.getInt(
                            contentResolver,
                            Settings.System.ACCELEROMETER_ROTATION,
                            0
                        )
                        result.success(autoRotate == 1)
                    } catch (e: Exception) {
                        result.success(true) // Fallback: allow rotation
                    }
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PYTHON_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "analyzeDroplet") {
                    val imagePath = call.argument<String>("imagePath")
                    val baselineYOverride = call.argument<Int>("baselineY")
                    if (imagePath == null) {
                        result.error("INVALID_ARGUMENT", "imagePath is required", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            if (!OpenCVLoader.initDebug()) {
                                throw Exception("OpenCV initialization failed.")
                            }

                            // 1. Load image
                            val img = Imgcodecs.imread(imagePath)
                            if (img.empty()) throw Exception("Failed to load image")

                            // 2. Preprocess (Gray -> Blur -> Canny)
                            val gray = Mat()
                            Imgproc.cvtColor(img, gray, Imgproc.COLOR_BGR2GRAY)
                            val blurred = Mat()
                            Imgproc.GaussianBlur(gray, blurred, Size(3.0, 3.0), 0.0)
                            val edges = Mat()
                            Imgproc.Canny(blurred, edges, 50.0, 150.0)

                            // 3. Baseline detection (HoughLinesP)
                            val lines = Mat()
                            Imgproc.HoughLinesP(edges, lines, 1.0, Math.PI / 180.0, 80, (edges.cols() / 3).toDouble(), 20.0)
                            val horizontalLines = mutableListOf<Int>()
                            for (i in 0 until lines.rows()) {
                                val vec = lines.get(i, 0)
                                if (vec != null && vec.size >= 4) {
                                    val x1 = vec[0]
                                    val y1 = vec[1]
                                    val x2 = vec[2]
                                    val y2 = vec[3]
                                    val angle = abs(Math.toDegrees(atan2(y2 - y1, x2 - x1)))
                                    if (angle < 30.0) {
                                        horizontalLines.add(((y1 + y2) / 2).toInt())
                                    }
                                }
                            }
                            
                            val baselineY = baselineYOverride ?: if (horizontalLines.isNotEmpty()) {
                                horizontalLines.sorted()[horizontalLines.size / 2] - 4
                            } else {
                                edges.rows() - 10 // fallback
                            }

                            // 4. Contour extraction
                            val maskedEdges = edges.clone()
                            val rowRange = maskedEdges.rowRange(baselineY, maskedEdges.rows())
                            rowRange.setTo(org.opencv.core.Scalar(0.0))
                            
                            val contours = ArrayList<MatOfPoint>()
                            val hierarchy = Mat()
                            Imgproc.findContours(maskedEdges, contours, hierarchy, Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_NONE)
                            
                            if (contours.isEmpty()) throw Exception("No droplet contour found.")
                            
                            val largestContour = contours.maxByOrNull { Imgproc.contourArea(it) }!!
                            val points = largestContour.toArray()
                            val pyPoints = points.map { doubleArrayOf(it.x.toDouble(), it.y.toDouble()) }.toTypedArray()

                            // 5. Python physics math
                            val py = Python.getInstance()
                            val module = py.getModule("surfeye.analyze")
                            val resJsonStr = module.callAttr("analyze_droplet_json", null, null, pyPoints, baselineY).toString()
                            
                            val resultJson = JSONObject(resJsonStr)
                            if (resultJson.optBoolean("success", false)) {
                                val annotatedImg = img.clone()
                                
                                // Draw baseline (Blue)
                                Imgproc.line(annotatedImg, org.opencv.core.Point(0.0, baselineY.toDouble()), org.opencv.core.Point(img.cols().toDouble(), baselineY.toDouble()), org.opencv.core.Scalar(255.0, 0.0, 0.0), 3)
                                
                                // Draw contour (Blue)
                                val contoursList = ArrayList<MatOfPoint>()
                                contoursList.add(largestContour)
                                Imgproc.drawContours(annotatedImg, contoursList, -1, org.opencv.core.Scalar(255.0, 0.0, 0.0), 3)

                                // Draw tangents
                                val leftAngle = resultJson.optDouble("left_angle", -1.0)
                                val rightAngle = resultJson.optDouble("right_angle", -1.0)
                                
                                val leftPtObj = points.filter { it.y <= baselineY + 2 }.minByOrNull { it.x }
                                val rightPtObj = points.filter { it.y <= baselineY + 2 }.maxByOrNull { it.x }
                                
                                val length = 150.0 // tangent line length
                                
                                if (leftPtObj != null && leftAngle >= 0) {
                                    val rad = Math.toRadians(leftAngle)
                                    val endX = leftPtObj.x + length * Math.cos(rad)
                                    val endY = leftPtObj.y - length * Math.sin(rad)
                                    Imgproc.line(annotatedImg, leftPtObj, org.opencv.core.Point(endX, endY), org.opencv.core.Scalar(0.0, 255.0, 0.0), 4)
                                    Imgproc.putText(annotatedImg, java.lang.String.format(java.util.Locale.US, "%.1f", leftAngle) + "\u00B0", org.opencv.core.Point(leftPtObj.x + 10, leftPtObj.y - 40), Imgproc.FONT_HERSHEY_SIMPLEX, 1.5, org.opencv.core.Scalar(0.0, 255.0, 0.0), 4)
                                }
                                
                                if (rightPtObj != null && rightAngle >= 0) {
                                    val rad = Math.toRadians(180 - rightAngle)
                                    val endX = rightPtObj.x + length * Math.cos(rad)
                                    val endY = rightPtObj.y - length * Math.sin(rad)
                                    Imgproc.line(annotatedImg, rightPtObj, org.opencv.core.Point(endX, endY), org.opencv.core.Scalar(0.0, 255.0, 0.0), 4)
                                    Imgproc.putText(annotatedImg, java.lang.String.format(java.util.Locale.US, "%.1f", rightAngle) + "\u00B0", org.opencv.core.Point(rightPtObj.x - 120, rightPtObj.y - 40), Imgproc.FONT_HERSHEY_SIMPLEX, 1.5, org.opencv.core.Scalar(0.0, 255.0, 0.0), 4)
                                }
                                
                                // --- 1:1 Cropping logic ---
                                val rect = Imgproc.boundingRect(largestContour)
                                val size = (Math.max(rect.width, rect.height) * 1.5).toInt()
                                val centerX = rect.x + rect.width / 2
                                val centerY = baselineY - (baselineY - rect.y) / 2
                                
                                var cropX = centerX - size / 2
                                var cropY = centerY - size / 2
                                cropX = Math.max(0, cropX)
                                cropY = Math.max(0, cropY)
                                
                                val cropSize = Math.min(size, Math.min(img.cols() - cropX, img.rows() - cropY))
                                val finalRect = org.opencv.core.Rect(cropX, cropY, cropSize, cropSize)
                                val croppedImg = Mat(annotatedImg, finalRect)

                                val outPath = imagePath.replace(".jpg", "_annotated.jpg")
                                Imgcodecs.imwrite(outPath, croppedImg)
                                resultJson.put("annotated_image_path", outPath)
                                
                                runOnUiThread {
                                    result.success(resultJson.toString())
                                }
                            } else {
                                runOnUiThread {
                                    result.success(resJsonStr)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("PYTHON_ERROR", e.message, e.stackTraceToString())
                            }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }

        // ── Fast Kotlin-only preview channel (no Python) ──────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PREVIEW_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "previewAnalyze") {
                    val imagePath = call.argument<String>("imagePath")
                    val baselineYOverride = call.argument<Int>("baselineY")
                    if (imagePath == null) {
                        result.error("INVALID_ARGUMENT", "imagePath required", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            if (!OpenCVLoader.initDebug()) throw Exception("OpenCV init failed")

                            val img = Imgcodecs.imread(imagePath)
                            if (img.empty()) throw Exception("Failed to load image")

                            val gray = Mat()
                            Imgproc.cvtColor(img, gray, Imgproc.COLOR_BGR2GRAY)
                            val blurred = Mat()
                            Imgproc.GaussianBlur(gray, blurred, Size(3.0, 3.0), 0.0)
                            val edges = Mat()
                            Imgproc.Canny(blurred, edges, 50.0, 150.0)

                            // Baseline detection
                            val lines = Mat()
                            Imgproc.HoughLinesP(edges, lines, 1.0, Math.PI / 180.0, 80, (edges.cols() / 3).toDouble(), 20.0)
                            val horizontalLines = mutableListOf<Int>()
                            for (i in 0 until lines.rows()) {
                                val vec = lines.get(i, 0)
                                if (vec != null && vec.size >= 4) {
                                    val x1 = vec[0]; val y1 = vec[1]; val x2 = vec[2]; val y2 = vec[3]
                                    val angle = abs(Math.toDegrees(atan2(y2 - y1, x2 - x1)))
                                    if (angle < 30.0) horizontalLines.add(((y1 + y2) / 2).toInt())
                                }
                            }
                            val baselineY = baselineYOverride
                                ?: if (horizontalLines.isNotEmpty())
                                    horizontalLines.sorted()[horizontalLines.size / 2] - 4
                                else edges.rows() - 10

                            // Contour extraction
                            val maskedEdges = edges.clone()
                            maskedEdges.rowRange(baselineY.coerceAtLeast(0), maskedEdges.rows()).setTo(org.opencv.core.Scalar(0.0))
                            val contours = ArrayList<MatOfPoint>()
                            Imgproc.findContours(maskedEdges, contours, Mat(), Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_NONE)

                            // Build JSON response
                            val json = JSONObject()
                            json.put("baseline_y", baselineY)
                            json.put("img_width", img.cols())
                            json.put("img_height", img.rows())

                            if (contours.isNotEmpty()) {
                                val largest = contours.maxByOrNull { Imgproc.contourArea(it) }!!
                                val pts = largest.toArray()
                                // Simple geometric angle: tangent angle at baseline intersection
                                val ptsArr = JSONArray()
                                for (pt in pts) { val p = JSONArray(); p.put(pt.x); p.put(pt.y); ptsArr.put(p) }
                                json.put("contour_points", ptsArr)

                                // Fast circle-fit angle estimate (no Python)
                                val ptsAbove = pts.filter { it.y < baselineY }
                                if (ptsAbove.size >= 5) {
                                    val cx = ptsAbove.map { it.x }.average()
                                    val cy = ptsAbove.map { it.y }.average()
                                    val r = ptsAbove.map { sqrt((it.x - cx) * (it.x - cx) + (it.y - cy) * (it.y - cy)) }.average()
                                    val dY = baselineY - cy
                                    val sinTheta = (dY / r).coerceIn(-1.0, 1.0)
                                    val approxAngle = Math.toDegrees(Math.asin(sinTheta))
                                    json.put("approx_angle", approxAngle)
                                }
                            }

                            runOnUiThread { result.success(json.toString()) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PREVIEW_ERROR", e.message, null) }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }
}

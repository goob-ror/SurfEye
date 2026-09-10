# SurfEye - Contact Angle Analyzer

SurfEye is a mobile application for measuring water droplet contact angles on surfaces using image analysis. It provides accurate, automated contact angle measurements for wettability analysis in research and quality control applications.

## Features

### Core Functionality
- 📸 **Real-time Camera Capture** - Live preview with grid alignment and focus controls
- 🔍 **Automated Analysis** - Automatic baseline and droplet detection using OpenCV
- 📊 **Precise Measurements** - Polynomial curve fitting for accurate contact angle calculation
- 🎯 **Surface Classification** - Automatic classification (Superhydrophobic, Hydrophobic, Hydrophilic, Superhydrophilic)
- 💾 **Measurement History** - Local database storage with detailed metadata
- 📤 **Export & Share** - Share analysis results and images

### Advanced Features (v1.0.0+)

#### 🔎 Zoom Controls
- **1x-4x zoom** on both calibration and results screens
- **Pinch-to-zoom** gesture support with smooth animations
- **Precision slider** for fine-grained zoom control
- **Real-time zoom indicator** showing current magnification level

#### ✏️ Manual Droplet Selection
- **Bounding box drawing** to manually specify droplet region
- **Always optional** - available as override for automatic detection
- **Interactive drawing mode** with visual feedback
- **Clear error messages** when selection doesn't contain a droplet

#### 🎯 Enhanced Circle Detection
- **Hybrid detection approach** using HoughCircles + contour analysis
- **Bokeh filtering** - automatically selects largest circle, ignores highlights
- **Region-constrained analysis** - focuses on relevant area, reducing noise
- **Graceful fallback** - automatically reverts to traditional method if needed

#### 💾 Calibration Memory
- **Save defaults** - store your baseline and droplet region preferences
- **Persistent across sessions** - saved settings automatically load on next capture
- **Smart prompting** - only asks to save when manual adjustments were made
- **Easy reset** - one-tap return to automatic detection

> **📖 Detailed Documentation**: See [docs/ZOOM_AND_DETECTION.md](docs/ZOOM_AND_DETECTION.md) for comprehensive usage guide, configuration, and troubleshooting.

## Architecture

### Mobile App (Flutter)
- Cross-platform iOS/Android application
- Material Design with custom "Nature" theme
- Camera integration with live preview
- Local SQLite database for measurements
- HTTP client for API communication

### Analysis API (Python/FastAPI)
- RESTful API with FastAPI framework
- OpenCV-based image processing pipeline
- HoughCircles for intelligent droplet detection
- Polynomial fitting for contact angle calculation
- Ngrok tunnel support for development/testing

### Processing Pipeline

```
Image Capture
    ↓
Preprocessing (Grayscale, Gaussian Blur, Canny Edge Detection)
    ↓
Baseline Detection (Hough Line Transform)
    ↓
Circle Detection (HoughCircles - NEW in v1.0.0)
    ↓
Contour Extraction (Region-constrained with circular mask)
    ↓
Polynomial Curve Fitting (4th degree)
    ↓
Tangent Slope Calculation
    ↓
Contact Angle Measurement
    ↓
Surface Classification
```

## Installation

### Prerequisites

**Mobile App:**
- Flutter SDK 3.11.5 or higher
- Dart SDK 3.11.5 or higher
- Android Studio / Xcode for platform-specific builds

**API Server:**
- Python 3.12+
- pip or uv package manager
- Virtual environment recommended

### Setup Instructions

#### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/surfeye.git
cd surfeye
```

#### 2. API Server Setup

```bash
cd API

# Create virtual environment
python -m venv .venv

# Activate virtual environment
# Windows:
.venv\Scripts\activate
# macOS/Linux:
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Create .env file (copy from .env.example and configure)
cp .env.example .env

# Start the server
python server.py
```

The server will start on http://localhost:8000 (or with ngrok tunnel if configured).

#### 3. Mobile App Setup

```bash
cd APP

# Install Flutter dependencies
flutter pub get

# Update API base URL in lib/config/app_config.dart
# Set baseUrl to your API server address

# Run on connected device/emulator
flutter run
```

## Configuration

### API Configuration (`API/config.py`)

All image processing parameters can be tuned in `config.py`:

**Edge Detection:**
- `BLUR_KERNEL_SIZE` - Gaussian blur strength (default: 3)
- `CANNY_THRESHOLD_LOW` - Canny lower threshold (default: 50)
- `CANNY_THRESHOLD_HIGH` - Canny upper threshold (default: 150)

**Baseline Detection:**
- `BASELINE_ANGLE_TOLERANCE` - Max degrees from horizontal (default: 30)
- `BASELINE_Y_OFFSET` - Manual offset adjustment (default: -4)

**Circle Detection (NEW):**
- `CIRCLE_DP` - Accumulator resolution ratio (default: 1.2)
- `CIRCLE_MIN_DIST` - Min distance between circles (default: 50)
- `CIRCLE_PARAM1` - Canny high threshold (default: 100)
- `CIRCLE_PARAM2` - Accumulator threshold (default: 30)
- `CIRCLE_MIN_RADIUS_RATIO` - Min radius as fraction of height (default: 0.05)
- `CIRCLE_MAX_RADIUS_RATIO` - Max radius as fraction of height (default: 0.40)

**Contour & Fitting:**
- `CONTOUR_BASELINE_MARGIN` - Pixels above baseline to ignore (default: 0)
- `FITTING_POLYNOMIAL_DEGREE` - Polynomial degree for curve fitting (default: 4)
- `FITTING_CONTACT_REGION_PX` - Pixels near baseline for tangent (default: 20)

**Spatial Calibration:**
- `PIXELS_PER_MM` - Convert pixels to millimeters (default: 300.0)

See [docs/ZOOM_AND_DETECTION.md](docs/ZOOM_AND_DETECTION.md) for detailed tuning guidance.

### App Configuration (`APP/lib/config/app_config.dart`)

```dart
class AppConfig {
  static const String baseUrl = 'http://your-api-server:8000';
  // Or use ngrok URL for remote testing:
  // static const String baseUrl = 'https://xxxx-xx-xx-xx-xx.ngrok.io';
}
```

## Usage

### Basic Workflow

1. **Open Camera** - Tap "Kamera" button on home screen
2. **Position Droplet** - Use grid overlay to align droplet and surface
3. **Capture Image** - Tap or hold the capture button
4. **Calibrate Baseline** - Adjust yellow line to match the surface
5. **(Optional) Define Droplet Region** - Draw bounding box if needed
6. **(Optional) Zoom** - Use pinch or slider for precision
7. **Analyze** - Tap "Mulai Analisis" to process
8. **Review Results** - View contact angle, classification, and annotated images
9. **(Optional) Save Defaults** - Save calibration settings for next time

### Advanced Features

**Using Manual Droplet Selection:**
- Tap "Tentukan Area Tetesan (Opsional)" on calibration screen
- Draw a rectangle around the water droplet
- System will focus analysis on that region only
- Use when automatic detection struggles with complex backgrounds

**Using Zoom Controls:**
- Tap image to toggle zoom slider
- Pinch to zoom 1x-4x
- Pan around while zoomed
- Useful for precise baseline calibration

**Calibration Memory:**
- After analysis with manual adjustments, you'll be prompted to save
- "Ya, Simpan Default" - saves your settings for next time
- "Tidak, Hanya Sekali Ini" - uses settings once
- Tap reset button (⟳) on calibration screen to clear saved defaults

## Testing

### API Testing

The API includes a built-in web test client:

```bash
# Start the server
python server.py

# Open browser to http://localhost:8000
# Use the web interface to upload images and test analysis
```

### Manual Testing Checklist

- [ ] Camera capture with different lighting conditions
- [ ] Baseline auto-detection and manual adjustment
- [ ] Zoom controls on calibration screen (pinch + slider)
- [ ] Bounding box drawing for manual droplet selection
- [ ] Analysis with automatic detection
- [ ] Analysis with manual bounding box
- [ ] Error handling for empty bounding box region
- [ ] Zoom controls on results screen
- [ ] Calibration defaults save prompt
- [ ] Calibration defaults loading on next capture
- [ ] Reset to automatic detection
- [ ] Measurement history storage and retrieval
- [ ] Share functionality for results

## Documentation

### Feature Guides
- [Zoom and Detection Features](docs/ZOOM_AND_DETECTION.md) - Comprehensive usage and configuration
- [Implementation Summary](IMPLEMENTATION_SUMMARY.md) - Complete technical implementation details
- [Mode Selection](MODE_SELECTION_UPDATE.md) - Auto vs Semi-Auto calibration modes

### Pipeline Analysis
- [Pipeline Comparison Results](COMPARISON_RESULTS.md) - Performance analysis: Old vs New pipeline
- [Comparison Tool Guide](API/README_COMPARISON.md) - How to run pipeline comparisons

### Bug Fixes
- [Drag Area & Result Images Fix](BUGFIX_DRAG_AND_IMAGES.md) - Fixes for bounding box drawing and image display

## Troubleshooting

See [docs/ZOOM_AND_DETECTION.md](docs/ZOOM_AND_DETECTION.md) for detailed troubleshooting guide.

**Common Issues:**

1. **"Could not detect baseline"**
   - Ensure good contrast between surface and background
   - Adjust lighting to create clear edge at surface
   - Manually position yellow line if auto-detection fails

2. **"No droplet detected in specified region"**
   - Redraw bounding box to fully contain the droplet
   - Try "Gunakan Otomatis" to search full image
   - Check that droplet has visible edges

3. **Bokeh highlights detected as droplet**
   - Use manual bounding box to exclude bokeh region
   - Increase `CIRCLE_MIN_DIST` parameter
   - System automatically selects largest circle (should filter bokeh)

4. **Zoom is laggy**
   - Use lower camera resolution preset
   - High-resolution images (>4K) may be slow on some devices

## Dependencies

### Mobile App
- `flutter` - UI framework
- `camera` - Camera access and preview
- `image_picker` - Gallery image selection
- `photo_view` - Zoomable image viewer (NEW)
- `shared_preferences` - Local storage for calibration defaults (NEW)
- `go_router` - Navigation
- `google_fonts` - Typography
- `flutter_animate` - Animations
- `sqflite` - Local database
- `http` - API communication
- `share_plus` - Share functionality

### API Server
- `fastapi` - Web framework
- `uvicorn` - ASGI server
- `opencv-python` - Image processing
- `numpy` - Numerical operations
- `scipy` - Scientific computing (curve fitting)
- `matplotlib` - Visualization (optional)
- `pyngrok` - Tunneling (development)
- `python-multipart` - Form data parsing
- `python-dotenv` - Environment configuration

## Project Structure

```
SurfEye/
├── API/                          # Python backend
│   ├── core/                     # Core processing modules
│   │   ├── preprocessor.py       # Image preprocessing
│   │   ├── baseline.py           # Baseline detection
│   │   ├── circle_detector.py   # Circle detection (NEW)
│   │   ├── contour.py            # Contour extraction (UPDATED)
│   │   ├── fitting.py            # Curve fitting
│   │   └── angle.py              # Angle calculation
│   ├── server.py                 # FastAPI application (UPDATED)
│   ├── pipeline.py               # Analysis pipeline (UPDATED)
│   ├── config.py                 # Configuration (UPDATED)
│   ├── requirements.txt          # Python dependencies
│   └── .env.example              # Environment template
├── APP/                          # Flutter mobile app
│   ├── lib/
│   │   ├── screens/
│   │   │   ├── home_screen.dart
│   │   │   ├── camera_screen.dart
│   │   │   ├── calibration_screen.dart  # (MAJOR UPDATE)
│   │   │   └── results_screen.dart      # (UPDATED with zoom)
│   │   ├── services/
│   │   │   ├── api_service.dart         # (UPDATED for bbox)
│   │   │   ├── calibration_storage.dart # (NEW)
│   │   │   └── database_service.dart
│   │   ├── models/
│   │   │   └── measurement.dart
│   │   ├── theme/
│   │   │   └── app_theme.dart
│   │   ├── config/
│   │   │   └── app_config.dart
│   │   └── main.dart
│   └── pubspec.yaml              # (UPDATED dependencies)
├── docs/
│   └── ZOOM_AND_DETECTION.md     # (NEW) Comprehensive feature guide
└── README.md                      # This file (UPDATED)
```

## Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- OpenCV community for excellent image processing libraries
- Flutter team for the cross-platform framework
- FastAPI for the modern Python web framework
- [LearnOpenCV](https://learnopencv.com/) for HoughCircles tutorials and best practices

## Contact

For questions or support:
- Open an issue on GitHub
- Check documentation in `docs/` directory
- Review API test client at `http://localhost:8000`

---

**Version**: 1.0.0+  
**Last Updated**: 2026-08-28

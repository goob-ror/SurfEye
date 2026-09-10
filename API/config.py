# =============================================================================
# SurfEye — Tuning Configuration
# Adjust these values to fine-tune detection for your specific images/setup.
# =============================================================================


import os
from dotenv import load_dotenv
from pathlib import Path

# Load environment variables from API directory
API_DIR = Path(__file__).parent
load_dotenv(API_DIR / ".env")


# -------------------------------------------------------------------
# Helper to get optional numeric config
# -------------------------------------------------------------------

def _get_optional_float(key, default=None):
    """Get a float value from environment, returning default if not set."""
    val = os.getenv(key)
    if val is None:
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


# -----------------------------------------------------------------------------
# EDGE DETECTION (core/preprocessor.py)
# Controls how edges are found in the image.
# -----------------------------------------------------------------------------
# Gaussian blur strength before edge detection (odd number, e.g. 3, 5, 7)
# Higher = smoother, removes more noise but may lose fine edges
BLUR_KERNEL_SIZE = 3
                            
# Lower bound for Canny edge detection
CANNY_THRESHOLD_LOW = 50\
# Upper bound for Canny edge detection
CANNY_THRESHOLD_HIGH = 150
# Increase both if too many false edges appear
# Decrease both if the droplet edge is not being detected


# -------------------------------------------------------------------
# EDGE CLEANING (core/preprocessor.py)
# After Canny edge detection, small isolated blobs and specks are
# removed using connected-component analysis. Only blobs that are
# "large enough" or "elongated enough" (likely part of the droplet
# boundary) are kept.
# -------------------------------------------------------------------

# Binarisation threshold applied to the raw edge map before
# connected-component analysis. Canny output is already 0/255 so the
# default of 30 removes any sub-threshold compression artefacts.
# Range: 1–254
EDGE_CLEAN_BINARY_THRESHOLD = 30

# Connectivity used by connectedComponentsWithStats (4 or 8).
# 8 treats diagonal neighbours as connected (recommended).
EDGE_CLEAN_CONNECTIVITY = 8

# A blob is always kept if its area (px²) is at or above this value.
# Raise to discard more medium-sized noise; lower to keep finer details.
# Default: 300
EDGE_CLEAN_MIN_AREA = 300

# A blob below EDGE_CLEAN_MIN_AREA is STILL kept if its area is at
# least EDGE_CLEAN_MIN_AREA_ELONGATED **and** its aspect ratio (longer
# side / shorter side) is >= EDGE_CLEAN_MIN_ASPECT. This preserves
# thin, streak-like edge segments that belong to the droplet boundary.
# Default area: 80  |  Default aspect: 3.0
EDGE_CLEAN_MIN_AREA_ELONGATED = 80
EDGE_CLEAN_MIN_ASPECT = 3.0

# Set to False to skip the cleaning step entirely (useful for debugging
# or when working with already-clean images).
EDGE_CLEAN_ENABLED = True


# -----------------------------------------------------------------------------
# BASELINE / SURFACE DETECTION (core/baseline.py)
# Controls how the solid surface line is found.
# -----------------------------------------------------------------------------
# Max degrees from horizontal to count as a baseline line
# Increase if your surface is slightly tilted
BASELINE_ANGLE_TOLERANCE = 30

# Manual offset in pixels applied to the detected baseline
BASELINE_Y_OFFSET = -4
# Positive = move baseline DOWN, Negative = move UP
# Use this if the detected line sits above/below the actual surface


# Fraction of max edge density to use in fallback detection (0.0–1.0)
BASELINE_FALLBACK_THRESHOLD = 0.3  
# Lower = more sensitive fallback, Higher = stricter


# -----------------------------------------------------------------------------
# DROPLET CONTOUR (core/contour.py)
# Controls which part of the image is searched for the droplet.
# -----------------------------------------------------------------------------
# Extra pixels above baseline to ignore (crops contour search region)
CONTOUR_BASELINE_MARGIN = 0
# Increase if the baseline itself is being picked up as part of the droplet


# -----------------------------------------------------------------------------
# CURVE FITTING (core/fitting.py)
# Controls how the droplet profile edges are fitted.
# -----------------------------------------------------------------------------
# Degree of polynomial used to fit droplet edges (2–6)
FITTING_POLYNOMIAL_DEGREE = 4
# Higher = follows the curve more closely, but can overfit noisy edges
# Lower = smoother fit, better for clean images

# Number of pixels near the baseline used for tangent fitting
FITTING_CONTACT_REGION_PX = 20
# Increase for smoother angle estimate, decrease for more local accuracy


# -----------------------------------------------------------------------------
# VISUALIZATION (pipeline.py)
# Controls how the result is drawn.
# -----------------------------------------------------------------------------
# Length in pixels of the red tangent (angle) lines drawn at contact points
ANGLE_LINE_LENGTH = 30


# -------------------------------------------------------------------
# SPATIAL CALIBRATION
# Convert pixel measurements to real-world millimetres.
#
# How to calibrate:
#   1. Place a reference object of known size (ruler, needle, calibration slide)
#      in the same focal plane as the droplet.
#   2. Run the program, note the pixel width of that reference object.
#   3. Set PIXELS_PER_MM = <measured pixels> / <known mm size>
#
# Example: a 1mm reference object spans 120 pixels → PIXELS_PER_MM = 120.0
#
# Set to None to disable mm conversion and show pixels only.
# -------------------------------------------------------------------

# Can be set via environment variable: PIXELS_PER_MM=300
PIXELS_PER_MM = _get_optional_float("PIXELS_PER_MM", 300.0)
# e.g. 120.0


# -----------------------------------------------------------------------------
# CIRCLE DETECTION (core/circle_detector.py)
# Uses Hough Circle Transform to identify the main water droplet and filter
# out smaller circular artifacts (bokeh highlights, reflections).
# -----------------------------------------------------------------------------

# Inverse ratio of accumulator resolution to image resolution
# Larger values = smaller accumulator array = faster but less precise
# Recommended: 1.0 to 2.0
CIRCLE_DP = 1.2

# Minimum distance between detected circle centers (pixels)
# Critical for avoiding false positives from bokeh lights
# Should be at least half the expected droplet diameter
# Recommended: 50-100 for typical droplet images
CIRCLE_MIN_DIST = 50

# Upper threshold for internal Canny edge detector (param1)
# Higher = stricter edge detection, fewer false circles
# Lower = more sensitive, may detect noise
# Recommended: 80-120
CIRCLE_PARAM1 = 100

# Accumulator threshold for circle center detection (param2)
# Lower = more circles detected (including false positives)
# Higher = stricter, may miss valid circles
# Recommended: 20-40
CIRCLE_PARAM2 = 30

# Minimum circle radius as fraction of image height
# E.g., 0.05 = 5% of image height is minimum droplet size
# Adjust based on expected droplet size and image resolution
CIRCLE_MIN_RADIUS_RATIO = 0.05

# Maximum circle radius as fraction of image height
# E.g., 0.40 = 40% of image height is maximum droplet size
# Prevents detecting large background features as droplets
CIRCLE_MAX_RADIUS_RATIO = 0.40


# -------------------------------------------------------------------
# CONFIGURATION OVERRIDES (via environment variables)
# -------------------------------------------------------------------

# BLUR_KERNEL_SIZE = int(os.getenv("BLUR_KERNEL_SIZE", "3"))
# CANNY_THRESHOLD_LOW = int(os.getenv("CANNY_THRESHOLD_LOW", "50"))
# CANNY_THRESHOLD_HIGH = int(os.getenv("CANNY_THRESHOLD_HIGH", "150"))
# BASELINE_ANGLE_TOLERANCE = int(os.getenv("BASELINE_ANGLE_TOLERANCE", "30"))
# BASELINE_Y_OFFSET = int(os.getenv("BASELINE_Y_OFFSET", "-4"))
# CONTOUR_BASELINE_MARGIN = int(os.getenv("CONTOUR_BASELINE_MARGIN", "0"))
# FITTING_POLYNOMIAL_DEGREE = int(os.getenv("FITTING_POLYNOMIAL_DEGREE", "4"))
# FITTING_CONTACT_REGION_PX = int(os.getenv("FITTING_CONTACT_REGION_PX", "20"))
# ANGLE_LINE_LENGTH = int(os.getenv("ANGLE_LINE_LENGTH", "30"))

# Note: Environment variable support can be enabled by uncommenting above

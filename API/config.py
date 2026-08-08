# =============================================================================
# SurfEye — Tuning Configuration
# Adjust these values to fine-tune detection for your specific images/setup.
# =============================================================================


# -----------------------------------------------------------------------------
# EDGE DETECTION (core/preprocessor.py)
# Controls how edges are found in the image.
# -----------------------------------------------------------------------------
# Gaussian blur strength before edge detection (odd number, e.g. 3, 5, 7)
# Higher = smoother, removes more noise but may lose fine edges
BLUR_KERNEL_SIZE = 3
                            
# Lower bound for Canny edge detection
CANNY_THRESHOLD_LOW = 50
# Upper bound for Canny edge detection
CANNY_THRESHOLD_HIGH = 150
# Increase both if too many false edges appear
# Decrease both if the droplet edge is not being detected


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


# -----------------------------------------------------------------------------
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
# -----------------------------------------------------------------------------
PIXELS_PER_MM = 300
# e.g. 120.0

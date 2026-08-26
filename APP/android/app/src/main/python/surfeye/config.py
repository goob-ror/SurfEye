# =============================================================================
# SurfEye — Tuning Configuration
# =============================================================================
# This used to be a flat module of constants imported as `from API.config
# import X`. That layout doesn't travel well to Chaquopy (there's no "API"
# package on the Android side, and module-level globals make it awkward to
# expose per-call overrides to Kotlin/Flutter). It's now a dataclass:
# defaults live here, but every field can be overridden per call by passing
# a `Settings(...)` instance into `analyze_droplet`.
# =============================================================================

from dataclasses import dataclass, field
from typing import Optional, Tuple


@dataclass
class Settings:
    # --- Edge detection (preprocessor.py) ---------------------------------
    blur_kernel_size: int = 3          # odd number; higher = smoother
    canny_threshold_low: int = 50
    canny_threshold_high: int = 150

    # --- Baseline / surface detection (baseline.py) ------------------------
    # Baseline is AUTO by default. To pin it manually (e.g. from a Flutter
    # slider the user drags onto the surface line), pass baseline_y=<int>
    # to analyze_droplet() / detect_baseline() directly — that's a per-call
    # argument, not a Settings field, since it's per-image, not a tuning
    # constant.
    baseline_angle_tolerance: float = 30     # degrees from horizontal
    baseline_y_offset: int = -4              # applied only in AUTO mode
    baseline_fallback_threshold: float = 0.3

    # --- Contour extraction (contour.py) -----------------------------------
    contour_baseline_margin: int = 0

    # --- Young-Laplace fit (young_laplace.py) -------------------------------
    # Bond number search range. Bo = 0 is a perfect sphere; realistic
    # sessile drops of a few mm are usually within +/-3.
    yl_bond_bounds: Tuple[float, float] = (-3.0, 3.0)
    yl_max_nfev: int = 150
    # Margin above the baseline to exclude from the fit (surface noise).
    yl_baseline_margin_px: int = 4
    # Initial Bond-number guesses to multi-start the optimizer from (it's
    # a nonlinear fit with a somewhat flat/multi-modal landscape, so a
    # single start can land a few degrees off). More seeds = better
    # accuracy, roughly linear in fit time. 3 seeds is a reasonable
    # phone-friendly default (~0.5-1s typical, worse for hard cases);
    # widen this list if accuracy matters more than latency for your use
    # case, e.g. a "high precision" mode triggered by the user.
    yl_bond_seed_guesses: Tuple[float, ...] = (0.0, 0.7, -0.7)

    # --- Legacy circle / polynomial fit (fitting.py) ------------------------
    # Kept only as a fast fallback if the Young-Laplace fit fails to
    # converge (e.g. too few contour points, degenerate image).
    fitting_polynomial_degree: int = 4
    fitting_contact_region_px: int = 20

    # --- Visualization -------------------------------------------------------
    angle_line_length: int = 30

    # --- Spatial calibration ---------------------------------------------
    # pixels / mm from a reference object in the same focal plane. None
    # disables mm conversion (pixel units only).
    pixels_per_mm: Optional[float] = 300.0

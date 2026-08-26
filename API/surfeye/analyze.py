"""
Single entry point meant to be called from Kotlin via Chaquopy.

Two call shapes are supported:

1. image_path given, OpenCV available in this environment:
   the whole pipeline (preprocess -> baseline -> contour -> fit) runs
   in Python.

2. edges / contour_points given directly (recommended on Android — see
   README_ANDROID.md): Kotlin does image decode + Canny + Hough +
   findContours using Android's native OpenCV binding, and only hands
   the numeric arrays to Python, which does the Young-Laplace fit
   (numpy/scipy only — no OpenCV needed for this half).

`analyze_droplet_json` returns a plain JSON string, which is the
simplest, least error-prone thing to pass across the Chaquopy boundary
(vs. handing back a dict of numpy scalars / dataclasses).
"""

import json
from typing import Optional

import numpy as np

from .config import Settings
from . import preprocessor, baseline as baseline_mod, contour as contour_mod
from .young_laplace import fit_young_laplace, estimate_surface_tension, YoungLaplaceFit
from .fitting import fit_circle
from .angle import compute_contact_angle_from_circle


def analyze_droplet(
    image_path: Optional[str] = None,
    edges: Optional[np.ndarray] = None,
    contour_points: Optional[np.ndarray] = None,
    baseline_y: Optional[int] = None,
    settings: Optional[Settings] = None,
    delta_rho_kg_m3: Optional[float] = None,
    gravity: float = 9.80665,
) -> dict:
    """
    Run the full contact-angle pipeline.

    baseline_y:
        None (default) = AUTO detection.
        int = MANUAL override in pixels (e.g. from a Flutter slider the
        user drags onto the surface line in a preview overlay).

    delta_rho_kg_m3:
        Optional density difference between the liquid and the
        surrounding fluid (kg/m^3). If given (along with
        settings.pixels_per_mm), surface tension is estimated from the
        fitted Bond number.

    Provide EITHER image_path (full in-Python pipeline, needs OpenCV)
    OR edges (skips preprocessing) OR contour_points directly (skips
    preprocessing + contour extraction too — the leanest path for
    Android, where edge/contour work is done in Kotlin).
    """
    settings = settings or Settings()

    if contour_points is None:
        if edges is None:
            if image_path is None:
                raise ValueError("Provide image_path, edges, or contour_points.")
            _, edges = preprocessor.preprocess(image_path, settings)

        resolved_baseline_y = baseline_mod.detect_baseline(edges, settings, baseline_y=baseline_y)
        if resolved_baseline_y is None:
            return {"success": False, "error": "Baseline not detected. Pass baseline_y explicitly."}

        contour_points = contour_mod.extract_droplet_contour(edges, resolved_baseline_y, settings)
        if contour_points is None:
            return {"success": False, "error": "No droplet contour found."}
    else:
        if baseline_y is None:
            raise ValueError(
                "baseline_y is required when contour_points is supplied directly "
                "(auto-detection needs the edge map, which wasn't provided)."
            )
        resolved_baseline_y = int(baseline_y)

    fit = fit_young_laplace(contour_points, resolved_baseline_y, settings)

    used_fallback = False
    if fit is None:
        # Fallback: legacy spherical-cap circle fit.
        used_fallback = True
        circle = fit_circle(contour_points, resolved_baseline_y, settings)
        if circle is None:
            return {"success": False, "error": "Both Young-Laplace and fallback circle fit failed."}
        cx, cy, r = circle
        circle_result = compute_contact_angle_from_circle(cx, cy, r, resolved_baseline_y)
        result = {
            "success": True,
            "method": "circle_fallback",
            "baseline_y": resolved_baseline_y,
            "baseline_mode": "manual" if baseline_y is not None else "auto",
            **circle_result,
        }
    else:
        result = {
            "success": True,
            "method": "young_laplace",
            "baseline_y": resolved_baseline_y,
            "baseline_mode": "manual" if baseline_y is not None else "auto",
            "apex_x_px": fit.apex_x,
            "apex_y_px": fit.apex_y,
            "apex_radius_px": fit.b,
            "bond_number": fit.bond_number,
            "left_angle": fit.left_angle,
            "right_angle": fit.right_angle,
            "average_angle": fit.average_angle,
            "classification": fit.classification,
            "droplet_height_px": fit.droplet_height_px,
            "droplet_width_px": fit.droplet_width_px,
            "fit_residual_rms_px": fit.residual_rms_px,
        }

        if delta_rho_kg_m3 is not None and settings.pixels_per_mm:
            gamma = estimate_surface_tension(
                fit, delta_rho_kg_m3, settings.pixels_per_mm, gravity=gravity
            )
            result["surface_tension_mN_per_m"] = gamma
            if gamma is not None:
                result["surface_tension_caveat"] = (
                    "Experimental estimate — the Bond number this is derived "
                    "from is weakly constrained by a single image; validate "
                    "against a reference liquid before trusting absolute values."
                )

    if settings.pixels_per_mm:
        ppm = settings.pixels_per_mm
        if "droplet_height_px" in result:
            result["droplet_height_mm"] = result["droplet_height_px"] / ppm
        if "droplet_width_px" in result:
            result["droplet_width_mm"] = result["droplet_width_px"] / ppm

    if used_fallback:
        result["warning"] = (
            "Young-Laplace fit did not converge; fell back to the "
            "spherical-cap circle approximation (gravity ignored)."
        )

    return result


def analyze_droplet_json(*args, **kwargs) -> str:
    """Same as analyze_droplet(), but returns a JSON string — the
    simplest object to hand back across the Chaquopy Python<->Kotlin
    boundary."""
    result = analyze_droplet(*args, **kwargs)
    return json.dumps(result)

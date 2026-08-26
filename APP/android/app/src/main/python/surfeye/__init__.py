"""
SurfEye — contact-angle measurement from sessile-droplet images.

Fits the true axisymmetric Young-Laplace drop shape (Bashforth-Adams
equations) to the digitized droplet contour, rather than approximating
the profile as a circle or independent polynomials. Baseline (surface)
detection is automatic by default but can be overridden per-call, which
is what a Flutter UI slider / manual-correction control should drive.

Designed to run under Chaquopy on Android — see README_ANDROID.md in
this package for the OpenCV caveat and the recommended split of work
between Kotlin and Python.
"""

from .analyze import analyze_droplet, analyze_droplet_json
from .config import Settings

__all__ = ["analyze_droplet", "analyze_droplet_json", "Settings"]

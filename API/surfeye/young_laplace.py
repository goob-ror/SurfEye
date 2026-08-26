"""
Axisymmetric Young-Laplace drop-shape fitting (a.k.a. ADSA — Axisymmetric
Drop Shape Analysis), replacing the spherical-cap / independent-polynomial
approximations previously used in fitting.py.

Physics
-------
For a droplet small enough to be axisymmetric (no sideways tilt), the
Young-Laplace equation ΔP = γ(1/R1 + 1/R2) reduces, along the profile
curve, to the dimensionless Bashforth-Adams ODE system. Using arc length
s (in units of the apex radius of curvature b) as the independent
variable, and phi = angle of the tangent from the horizontal (phi = 0 at
the apex):

    dphi/ds = 2 + Bo*Z - sin(phi)/X      (X > 0; dphi/ds = 1 at the apex)
    dX/ds   = cos(phi)
    dZ/ds   = sin(phi)

where X = x/b, Z = z/b are dimensionless radial/height coordinates
measured from the apex (Z increases downward, matching image
coordinates), and

    Bo = delta_rho * g * b^2 / gamma      (Bond / Eotvos number)

is the ratio of gravitational to surface-tension forces. Bo = 0 is an
exact sphere; increasing |Bo| flattens the drop under its own weight.
This is the same shape equation used in ADSA and in pendant/sessile
drop tensiometers — it is a strictly better model of the physical drop
profile than a circle or an unconstrained polynomial, both of which
ignore gravity entirely.

Fitting
-------
We integrate the ODE once per trial (b, Bo), scale/translate it to pixel
space with (x0, y0, b), mirror it for the left/right branches, and use
least-squares to fit (b, Bo, x0, y0) against the digitized contour
points. The contact angle is then read directly off the fitted profile
at the point where it crosses the baseline.
"""

from dataclasses import dataclass

import numpy as np
from scipy.optimize import least_squares

from .config import Settings
from .angle import classify_surface


@dataclass
class YoungLaplaceFit:
    apex_x: float          # pixel x of the drop apex
    apex_y: float          # pixel y of the drop apex (top of drop)
    b: float                # apex radius of curvature, pixels
    bond_number: float      # dimensionless shape factor (Bo)
    left_angle: float
    right_angle: float
    average_angle: float
    classification: str
    droplet_height_px: float
    droplet_width_px: float
    residual_rms_px: float
    surface_tension_mN_per_m: float | None = None


def _deriv(state: np.ndarray, bond: float) -> np.ndarray:
    phi, X, Z = state
    sin_over_x = 1.0 if X < 1e-8 else np.sin(phi) / X
    return np.array([2.0 + bond * Z - sin_over_x, np.cos(phi), np.sin(phi)])


def _integrate_shape(bond: float, s_max: float = 6.0, n: int = 220):
    """Integrate the dimensionless Bashforth-Adams equations from the
    apex outward using fixed-step RK4. Returns (s_vals, phi, X, Z),
    truncated at the drop's equator (phi = 180 deg, i.e. dZ/ds = 0).

    Past the equator the profile curves back over itself (an overhang) —
    not relevant for a sessile drop resting on a flat surface, and
    physically means Z stops being monotonic in s. Truncating there
    keeps Z monotonic, which the baseline-crossing search in
    fit_young_laplace() depends on, and also covers the full range of
    realistic contact angles (0-180 deg).

    This ODE is smooth and well-behaved (no stiffness), so fixed-step
    RK4 is both accurate (see the Bo=0 exact-circle check in tests) and
    far faster than scipy's adaptive solve_ivp — important since this
    integration runs on every optimizer residual evaluation.
    """
    ds = s_max / (n - 1)

    phi = np.empty(n)
    X = np.empty(n)
    Z = np.empty(n)
    phi[0] = X[0] = Z[0] = 0.0

    state = np.zeros(3)
    stop_at = n  # index of first sample past the equator, if any
    for i in range(n - 1):
        k1 = _deriv(state, bond)
        k2 = _deriv(state + 0.5 * ds * k1, bond)
        k3 = _deriv(state + 0.5 * ds * k2, bond)
        k4 = _deriv(state + ds * k3, bond)
        state = state + (ds / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)
        phi[i + 1], X[i + 1], Z[i + 1] = state
        if state[0] >= np.pi:
            stop_at = i + 2  # keep this sample as the (clamped) endpoint
            phi[i + 1] = np.pi
            break

    s_vals = np.linspace(0.0, ds * (stop_at - 1), stop_at)
    return s_vals, phi[:stop_at], X[:stop_at], Z[:stop_at]


def _profile_points_px(bond, b, x0, y0, s_max=6.0, n=180):
    """Dimensionless profile scaled/translated into pixel space, mirrored
    to both branches. Returns (points_xy, s_vals, phi, X, Z) where X, Z
    are still dimensionless (needed later to locate the baseline crossing).
    """
    s_vals, phi, X, Z = _integrate_shape(bond, s_max=s_max, n=n)
    x_px = np.concatenate([x0 - X * b, x0 + X * b])
    y_px = np.concatenate([y0 + Z * b, y0 + Z * b])
    pts = np.column_stack([x_px, y_px])
    return pts, s_vals, phi, X, Z


def _nearest_dist(data_pts: np.ndarray, curve_pts: np.ndarray) -> np.ndarray:
    """For each data point, distance to the nearest sampled curve point.
    O(N*M) brute force — fine at the point counts a droplet contour has
    (typically a few hundred to a couple thousand).
    """
    d2 = ((data_pts[:, None, :] - curve_pts[None, :, :]) ** 2).sum(axis=2)
    return np.sqrt(d2.min(axis=1))


def fit_young_laplace(
    points: np.ndarray,
    baseline_y: float,
    settings: Settings = None,
) -> YoungLaplaceFit | None:
    """
    Fit the axisymmetric Young-Laplace profile to droplet contour points.

    points: (N, 2) array of (x, y) contour pixels (image coords, y down).
    baseline_y: surface line y-pixel — from baseline.detect_baseline(),
        auto or manual.
    """
    settings = settings or Settings()

    margin = settings.yl_baseline_margin_px
    mask = points[:, 1] < (baseline_y - margin)
    pts = points[mask].astype(float)
    if len(pts) < 15:
        return None

    x, y = pts[:, 0], pts[:, 1]

    # Initial guesses: apex = topmost point / mean x; b = half the width.
    x0_0 = x.mean()
    y0_0 = y.min()
    width0 = max(x.max() - x.min(), 1.0)
    b0 = width0 / 2.0
    bond0 = 0.0

    lo_bond, hi_bond = settings.yl_bond_bounds

    def residuals(params):
        b, bond, x0, y0 = params
        bond = np.clip(bond, lo_bond, hi_bond)
        b = max(b, 1.0)
        curve_pts, *_ = _profile_points_px(bond, b, x0, y0)
        return _nearest_dist(pts, curve_pts)

    lower = [1.0, lo_bond, x.min() - width0, y.min() - width0]
    upper = [width0 * 3.0, hi_bond, x.max() + width0, y.min() + width0]

    # The (b, Bond) pair is weakly identifiable when the visible profile
    # doesn't reach far past the equator (common for flatter drops), so a
    # single starting guess can land in a shallow local minimum. Multi-start
    # over a handful of initial Bond guesses and keep whichever converges
    # to the lowest residual.
    best_result = None
    for bond_guess in settings.yl_bond_seed_guesses:
        try:
            trial = least_squares(
                residuals,
                [b0, bond_guess, x0_0, y0_0],
                bounds=(lower, upper),
                method="trf",
                max_nfev=settings.yl_max_nfev,
                xtol=1e-4, ftol=1e-4,
            )
        except Exception:
            continue
        if best_result is None or trial.cost < best_result.cost:
            best_result = trial
        # Good enough — stop early rather than burning the remaining
        # restarts (this is what keeps the fit fast enough for on-device
        # use; see README_ANDROID.md).
        if best_result is not None and best_result.cost < 0.5 * len(pts):
            break

    if best_result is None:
        return None
    result = best_result

    b, bond, x0, y0 = result.x
    b = float(max(b, 1.0))
    bond = float(np.clip(bond, lo_bond, hi_bond))
    rms = float(np.sqrt(np.mean(result.fun ** 2))) if result.fun.size else float("nan")

    # Locate baseline crossing on the fitted profile to read off phi
    # (the contact angle) and the contact-point x's (for width/asymmetry).
    s_vals, phi, X, Z = _integrate_shape(bond)
    z_target = (baseline_y - y0) / b
    if z_target <= 0 or z_target > Z[-1]:
        # Baseline is above the apex or beyond the integrated profile —
        # fit is not physically usable.
        return None

    idx = np.searchsorted(Z, z_target)
    idx = min(max(idx, 1), len(Z) - 1)
    # Linear interpolation between bracketing samples for a smoother read.
    z0_, z1_ = Z[idx - 1], Z[idx]
    t = 0.0 if z1_ == z0_ else (z_target - z0_) / (z1_ - z0_)
    phi_at_baseline = float(phi[idx - 1] + t * (phi[idx] - phi[idx - 1]))
    x_at_baseline = float(X[idx - 1] + t * (X[idx] - X[idx - 1]))

    contact_angle_deg = float(np.degrees(phi_at_baseline))
    # By axisymmetry the left/right theoretical angle is identical; report
    # it as both so downstream code (classify_surface) works unchanged and
    # any small measured asymmetry can be surfaced separately if needed.
    result_cls = classify_surface(contact_angle_deg, contact_angle_deg)

    droplet_height = float(z_target * b)
    droplet_width = float(2 * x_at_baseline * b)

    fit = YoungLaplaceFit(
        apex_x=float(x0),
        apex_y=float(y0),
        b=b,
        bond_number=bond,
        left_angle=result_cls["left_angle"],
        right_angle=result_cls["right_angle"],
        average_angle=result_cls["average_angle"],
        classification=result_cls["classification"],
        droplet_height_px=droplet_height,
        droplet_width_px=droplet_width,
        residual_rms_px=rms,
    )
    return fit


def estimate_surface_tension(
    fit: YoungLaplaceFit,
    delta_rho_kg_m3: float,
    pixels_per_mm: float,
    gravity: float = 9.80665,
) -> float | None:
    """
    Recover surface/interfacial tension from a Young-Laplace fit, given
    the density difference between the two phases (liquid - surrounding
    fluid, kg/m^3) and the pixel->mm calibration.

    gamma = delta_rho * g * b^2 / Bo     (Bo != 0)

    Returns tension in mN/m, or None if Bo is ~0 (no gravitational
    flattening to anchor the length scale — tension isn't separable from
    b in that limit; a purely circular drop can't self-calibrate this way).

    CAUTION — experimental, not calibration-grade: the contact angle
    from this fit is fairly robust (tested to within a few degrees on
    synthetic profiles), but the Bond number it's paired with is only
    weakly constrained unless the visible profile extends well past the
    drop's equator with clean, sub-pixel-accurate edges. Since gamma
    scales with 1/Bo, a modest Bond error becomes a large tension error
    (seen >5x off on synthetic test data with realistic pixel noise).
    Treat this as a rough order-of-magnitude estimate, not a
    tensiometer replacement, unless you've validated it against a
    reference liquid of known tension on your specific imaging setup.
    """
    if abs(fit.bond_number) < 1e-4 or pixels_per_mm <= 0:
        return None

    b_m = (fit.b / pixels_per_mm) * 1e-3  # px -> mm -> m
    gamma_N_per_m = delta_rho_kg_m3 * gravity * (b_m ** 2) / fit.bond_number
    return float(gamma_N_per_m * 1000.0)  # -> mN/m

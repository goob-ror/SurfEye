"""
Quick smoke test — not a full test suite, just enough to catch a broken
edit before it ships. Run with: python3 -m surfeye.test_smoke
(from the directory containing the surfeye/ package).
"""

import numpy as np

from .young_laplace import _integrate_shape, fit_young_laplace
from .analyze import analyze_droplet, analyze_droplet_json
from .config import Settings


def test_ode_matches_exact_circle_at_zero_bond():
    _, phi, X, Z = _integrate_shape(0.0)
    resid = X**2 + (1 - Z) ** 2 - 1
    assert np.max(np.abs(resid)) < 1e-6, "RK4 integrator drifted from the exact Bo=0 circle solution"


def _synthetic_droplet(true_bond, true_b=90.0, true_x0=250.0, true_y0=100.0, z_frac=0.9, noise=0.5, seed=0):
    _, phi, X, Z = _integrate_shape(true_bond, n=800)
    baseline_y = true_y0 + z_frac * true_b
    z_target = (baseline_y - true_y0) / true_b
    idx = np.searchsorted(Z, z_target)
    t = (z_target - Z[idx - 1]) / (Z[idx] - Z[idx - 1])
    true_angle_deg = float(np.degrees(phi[idx - 1] + t * (phi[idx] - phi[idx - 1])))

    mask = Z <= z_target
    xr = true_x0 + X[mask] * true_b
    xl = true_x0 - X[mask] * true_b
    yv = true_y0 + Z[mask] * true_b
    pts = np.column_stack([np.concatenate([xl, xr]), np.concatenate([yv, yv])])
    rng = np.random.default_rng(seed)
    pts = pts + rng.normal(0, noise, pts.shape)
    return pts, baseline_y, true_angle_deg


def test_fit_recovers_known_angle_within_tolerance():
    pts, baseline_y, true_angle = _synthetic_droplet(true_bond=0.5)
    fit = fit_young_laplace(pts, baseline_y, Settings())
    assert fit is not None, "fit failed to converge on a clean synthetic droplet"
    err = abs(fit.average_angle - true_angle)
    assert err < 10.0, f"contact angle off by {err:.1f} deg (true={true_angle:.1f}, fit={fit.average_angle:.1f})"


def test_analyze_droplet_manual_baseline_path():
    pts, baseline_y, _ = _synthetic_droplet(true_bond=0.3)
    result = analyze_droplet(contour_points=pts, baseline_y=baseline_y, settings=Settings(pixels_per_mm=300))
    assert result["success"]
    assert result["baseline_mode"] == "manual"
    assert "average_angle" in result


def test_analyze_droplet_requires_baseline_with_contour_points():
    pts, _, _ = _synthetic_droplet(true_bond=0.3)
    try:
        analyze_droplet(contour_points=pts)
        raised = False
    except ValueError:
        raised = True
    assert raised, "expected ValueError when contour_points given without baseline_y"


def test_analyze_droplet_json_returns_valid_json():
    import json
    pts, baseline_y, _ = _synthetic_droplet(true_bond=0.3)
    j = analyze_droplet_json(contour_points=pts, baseline_y=baseline_y)
    parsed = json.loads(j)
    assert parsed["success"]


if __name__ == "__main__":
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    failures = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except AssertionError as e:
            failures += 1
            print(f"FAIL {t.__name__}: {e}")
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    if failures:
        raise SystemExit(1)

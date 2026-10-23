"""
SurfEye WCA API server  (v2 — ROI-constrained detection)

What changed compared with the previous version
───────────────────────────────────────────────
  • When the operator locks a Region (bbox), detection now runs ONLY inside it:
      – edges are extracted from the crop, restricted to the area ABOVE the
        baseline (surface texture, baseline edge and reflection are excluded)
      – a RANSAC circle fit finds the droplet arc; the circle must be
        geometrically consistent with the box (contact points + apex inside it)
      – the inliers are refined with cv2.fitEllipse (kept only if it fits
        clearly better and passes sanity checks)
      – any fallback result (auto_detect.py / legacy) that falls outside the
        box is REJECTED (422) instead of silently returned.
  • Bbox may be sent in pixels OR normalised 0-1 (the Flutter /analyze call
    sends normalised values) — the server now handles both.
  • cv2.fitEllipse axis/angle pairing fixed in the legacy path.
  • Legacy Hough fallback now checks containment and no longer drops to
    param2 < 20.
  • Edge-sensitivity now means the same thing in /detect and /preview
    (higher = more edges).
  • /detect and /analyze return a `warnings` list (e.g. saturated pixels from
    brightness/contrast) and a real `confidence`.
  • /analyze no longer applies ellipse_scale_a/b on top of explicit ellipse
    params (the app already applies the scale to the ellipse it sends, so
    the old code scaled twice).  The scalars are still honoured when the
    server auto-detects.
  • /analyze also returns edge_image_path and method for the app's model.

Endpoints
─────────
  GET  /                       web test client (HTML)
  POST /detect                 step 1: detect droplet → ellipse params
  POST /analyze                step 2: compute WCA from ellipse + baseline
  POST /preview                live edge/baseline preview image
  GET  /image/{filename}       serve generated images

Usage
─────
  python server_wca.py                  # uses .env for ngrok token / port
  python server_wca.py --no-ngrok       # LAN / localhost only
  python server_wca.py --port 8080      # custom port
"""

from __future__ import annotations

import argparse
import os
import shutil
import uuid

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse

# Optional improved detector.  Used only when no ROI is locked, or as a
# fallback (validated against the ROI) when the ROI-constrained fit fails.
try:
    from auto_detect import (
        find_substrate as _find_substrate_new,
        detect_droplet as _detect_droplet_new,
    )
    _HAVE_AUTO_DETECT = True
except ImportError:                                   # pragma: no cover
    _HAVE_AUTO_DETECT = False

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

DEFAULT_PORT = int(os.getenv("PORT", "8000"))
NGROK_TOKEN  = os.getenv("NGROK_AUTHTOKEN", "")

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

# Pixels kept clear above the baseline when extracting droplet edges, so the
# baseline edge itself / shadow / reflection never enter the fit.
BASELINE_GUARD_PX = 2

app = FastAPI(title="SurfEye WCA API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ══════════════════════════════════════════════════════════════════════════════
#  PREPROCESSING
# ══════════════════════════════════════════════════════════════════════════════

def adjust_brightness_contrast(gray: np.ndarray, brightness: int, contrast: float) -> np.ndarray:
    """brightness ∈ [-100, 100], contrast ∈ [0.5, 3.0]"""
    img = gray.astype(np.float32)
    img = img * contrast + brightness
    return np.clip(img, 0, 255).astype(np.uint8)


def canny_thresholds(edge_sensitivity: int) -> tuple[int, int]:
    """Higher sensitivity → lower thresholds → more edges (same as /preview)."""
    s = int(np.clip(edge_sensitivity, 10, 150))
    return max(10, 100 - s), max(20, 200 - s)


def edge_map(gray_adj: np.ndarray, edge_sensitivity: int) -> np.ndarray:
    lo, hi = canny_thresholds(edge_sensitivity)
    return cv2.Canny(cv2.GaussianBlur(gray_adj, (5, 5), 1.5), lo, hi)


# ══════════════════════════════════════════════════════════════════════════════
#  BASELINE
# ══════════════════════════════════════════════════════════════════════════════

def find_substrate_top(gray: np.ndarray) -> int:
    """Legacy: scan centre column strip upward to find the substrate top edge."""
    h, w = gray.shape
    cx = w // 2
    strip = gray[:, max(0, cx - 60):cx + 60].mean(axis=1).astype(float)
    start = int(h * 0.55)

    for r in range(h - 1, start, -1):
        if strip[r] < 50:
            dark_bottom = r
            for r2 in range(dark_bottom, max(start, dark_bottom - 20), -1):
                if strip[r2] > 80:
                    for r3 in range(r2, max(start, r2 - 300), -1):
                        if strip[r3] < 80:
                            return r3
                    return max(start, r2 - 150)
            break

    seg = strip[start:]
    peak_offset = int(np.argmax(seg))
    peak_val    = seg[peak_offset]
    threshold   = peak_val * 0.75
    for r in range(start + peak_offset, start, -1):
        if strip[r] < threshold:
            return r
    return int(h * 0.75)


def auto_find_substrate(gray: np.ndarray) -> tuple[int, float]:
    """Return (baseline_y, confidence)."""
    if _HAVE_AUTO_DETECT:
        return _find_substrate_new(gray)
    return find_substrate_top(gray), 0.5


# ══════════════════════════════════════════════════════════════════════════════
#  ROI HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def parse_bbox(x1, y1, x2, y2, w: int, h: int) -> tuple[float, float, float, float] | None:
    """
    Accept pixel OR normalised (0-1) coordinates; return clipped pixel bbox.
    Returns None when no bbox was supplied or it is degenerate.
    """
    vals = [x1, y1, x2, y2]
    if any(v is None for v in vals):
        return None
    vals = [float(v) for v in vals]
    if max(vals) <= 1.5 and w > 2 and h > 2:       # normalised
        vals = [vals[0] * w, vals[1] * h, vals[2] * w, vals[3] * h]
    bx1, bx2 = sorted((vals[0], vals[2]))
    by1, by2 = sorted((vals[1], vals[3]))
    bx1, by1 = max(0.0, bx1), max(0.0, by1)
    bx2, by2 = min(float(w), bx2), min(float(h), by2)
    if bx2 - bx1 < 20 or by2 - by1 < 20:
        return None
    return bx1, by1, bx2, by2


def _roi_margin(bbox) -> float:
    return 0.04 * (bbox[2] - bbox[0]) + 4.0


def _geometry_ok(cx: float, cy: float, r: float, by: float, bbox, margin: float) -> bool:
    """
    A droplet cap is a circle arc above the baseline.  The circle itself may be
    larger than the cap (contact angle < 90°), so containment is tested on the
    VISIBLE part only:
        centre above baseline → widest point (cx ± r) is visible
        centre below baseline → widest visible points are the contact points
    """
    x1, y1, x2, y2 = bbox
    bw, bh = x2 - x1, y2 - y1
    if r < 10 or r > 4.0 * max(bw, bh):
        return False
    dy = cy - by                                   # >0: centre below baseline
    if abs(dy) >= r:                               # must cross baseline twice
        return False
    half_chord = float(np.sqrt(r * r - dy * dy))
    half_w = r if dy < 0 else half_chord
    if cx - half_w < x1 - margin or cx + half_w > x2 + margin:
        return False
    if cy - r < y1 - margin:                       # apex inside the box
        return False
    return True


def _ellipse_in_bbox(ell: list[float], by: float, bbox) -> bool:
    """Final gate for any ellipse returned while a ROI is locked."""
    res = compute_wca(ell, int(round(by)))
    if res is None:
        return False
    x1, y1, x2, y2 = bbox
    m = _roi_margin(bbox)
    lp, rp = res[2], res[3]
    if lp[0] < x1 - m or rp[0] > x2 + m:
        return False
    cx, cy, a, b, ang = ell
    if not (x1 - m <= cx <= x2 + m):
        return False
    t = np.deg2rad(ang)
    half_h = float(np.sqrt((a * np.sin(t)) ** 2 + (b * np.cos(t)) ** 2))
    return cy - half_h >= y1 - m


# ══════════════════════════════════════════════════════════════════════════════
#  ROI-CONSTRAINED DROPLET DETECTION  (RANSAC circle → optional ellipse refine)
# ══════════════════════════════════════════════════════════════════════════════

def _circle_from_3(p: np.ndarray):
    A = np.c_[2 * p[:, 0], 2 * p[:, 1], np.ones(3)]
    rhs = (p ** 2).sum(axis=1)
    try:
        cx, cy, c = np.linalg.solve(A, rhs)
    except np.linalg.LinAlgError:
        return None
    r2 = c + cx * cx + cy * cy
    if r2 <= 0:
        return None
    return float(cx), float(cy), float(np.sqrt(r2))


def _ransac_circle(pts: np.ndarray, bbox, by: float, tol: float,
                   iters: int = 1500, seed: int = 0):
    rng = np.random.default_rng(seed)
    n = len(pts)
    margin = _roi_margin(bbox)
    best = None
    for _ in range(iters):
        c = _circle_from_3(pts[rng.choice(n, 3, replace=False)])
        if c is None:
            continue
        cx, cy, r = c
        if not _geometry_ok(cx, cy, r, by, bbox, margin):
            continue
        d = np.abs(np.hypot(pts[:, 0] - cx, pts[:, 1] - cy) - r)
        cnt = int((d < tol).sum())
        if best is None or cnt > best[0]:
            best = (cnt, cx, cy, r)
    return best


def _ellipse_rms(pts: np.ndarray, ell: list[float]) -> float:
    cx, cy, a, b, ang = ell
    t = np.deg2rad(ang)
    c, s = np.cos(t), np.sin(t)
    dx, dy = pts[:, 0] - cx, pts[:, 1] - cy
    u, v = dx * c + dy * s, -dx * s + dy * c
    rho = np.sqrt((u / a) ** 2 + (v / b) ** 2)
    d = np.abs(rho - 1.0) * np.sqrt(a * b)         # first-order distance
    return float(np.sqrt(np.mean(d ** 2)))


def _fit_confidence(inl: np.ndarray, n_pts: int, cx: float, cy: float, r: float,
                    by: float, bbox) -> float:
    """0..1 from inlier fraction, angular coverage of the visible arc, ROI touch."""
    inlier_frac = len(inl) / max(n_pts, 1)
    ang = np.arctan2(inl[:, 1] - cy, inl[:, 0] - cx) % (2 * np.pi)
    bins = np.unique((ang // (np.pi / 12)).astype(int))
    s = float(np.clip((by - cy) / r, -1.0, 1.0))
    arc = np.pi + 2 * np.arcsin(s)
    expected = max(arc / (np.pi / 12), 1.0)
    coverage = min(1.0, len(bins) / (0.85 * expected))
    conf = 0.5 * min(1.0, inlier_frac / 0.45) + 0.5 * coverage

    x1, y1, x2, y2 = bbox
    dy = cy - by
    half_w = r if dy < 0 else float(np.sqrt(max(r * r - dy * dy, 0.0)))
    if cx - half_w < x1 + 2 or cx + half_w > x2 - 2 or cy - r < y1 + 2:
        conf *= 0.75                                # fit presses against the ROI
    return float(np.clip(conf, 0.0, 1.0))


def detect_droplet_bbox(
    gray_adj: np.ndarray,
    sub_top: int,
    edge_sensitivity: int,
    bbox: tuple[float, float, float, float],
) -> tuple[list[float] | None, float]:
    """
    Detect the droplet strictly inside `bbox`, using only pixels above the
    baseline.  Returns ([cx, cy, a, b, angle_deg], confidence) or (None, 0).
    """
    h, w = gray_adj.shape
    x1 = max(0, int(round(bbox[0]))); y1 = max(0, int(round(bbox[1])))
    x2 = min(w, int(round(bbox[2])));  y2 = min(h, int(round(bbox[3])))
    y_cut = min(y2, sub_top - BASELINE_GUARD_PX)
    if x2 - x1 < 20 or y_cut - y1 < 20:
        return None, 0.0

    box = (float(x1), float(y1), float(x2), float(y2))
    roi = gray_adj[y1:y_cut, x1:x2]
    roi_h, roi_w = roi.shape
    blurred = cv2.GaussianBlur(roi, (5, 5), 1.5)
    lo, hi = canny_thresholds(edge_sensitivity)
    tol = max(2.0, 0.01 * max(roi_w, roi_h))
    rng = np.random.default_rng(1)

    best = None                                     # (conf, cx, cy, r, inliers, pts)
    for scale in (1.0, 0.6, 0.35):
        edges = cv2.Canny(blurred, max(5, int(lo * scale)), max(15, int(hi * scale)))
        ys, xs = np.nonzero(edges)
        keep = (xs > 2) & (xs < roi_w - 3) & (ys > 2)
        xs, ys = xs[keep], ys[keep]
        if len(xs) < 40:
            continue
        pts_all = np.c_[xs + x1, ys + y1].astype(np.float64)
        pts = pts_all
        if len(pts) > 2000:
            pts = pts[rng.choice(len(pts), 2000, replace=False)]

        res = _ransac_circle(pts, box, float(sub_top), tol)
        if res is None:
            continue
        _, cx, cy, r = res
        d = np.abs(np.hypot(pts_all[:, 0] - cx, pts_all[:, 1] - cy) - r)
        inl = pts_all[d < tol]
        if len(inl) < 25:
            continue
        conf = _fit_confidence(inl, len(pts_all), cx, cy, r, float(sub_top), box)
        if best is None or conf > best[0]:
            best = (conf, cx, cy, r, inl)
        if conf >= 0.7:
            break

    if best is None:
        return None, 0.0

    conf, cx, cy, r, inl = best
    circle = [cx, cy, r, r, 0.0]

    # Optional ellipse refinement on the inliers
    try:
        (ex, ey), (ma, mi), ang = cv2.fitEllipse(inl.astype(np.float32).reshape(-1, 1, 2))
        # cv2: `ang` is the rotation of the FIRST axis (ma) — keep that pairing
        cand = [float(ex), float(ey), ma / 2.0, mi / 2.0, float(ang)]
        ratio = max(cand[2], cand[3]) / max(min(cand[2], cand[3]), 1e-6)
        if (min(cand[2], cand[3]) >= 5 and ratio <= 1.6
                and _ellipse_in_bbox(cand, float(sub_top), box)
                and _ellipse_rms(inl, cand) < 0.85 * _ellipse_rms(inl, circle)):
            return cand, conf
    except cv2.error:
        pass
    return circle, conf


# ══════════════════════════════════════════════════════════════════════════════
#  LEGACY DETECTOR  (fallback only; used when no ROI is locked)
# ══════════════════════════════════════════════════════════════════════════════

def detect_droplet_ellipse(
    gray_adj: np.ndarray,
    sub_top: int,
    canny_thresh: int,
    bbox: tuple[float, float, float, float] | None = None,
) -> list[float] | None:
    """Contour-based ellipse fit with HoughCircles fallback."""
    h, w = gray_adj.shape

    if bbox is not None:
        x1, y1, x2, y2 = (int(v) for v in bbox)
        x1 = max(0, x1); y1 = max(0, y1)
        x2 = min(w, x2); y2 = min(h, y2)
        roi = gray_adj[y1:y2, x1:x2]
        roi_top_offset = y1
    else:
        roi_top_offset = max(0, sub_top - 500)
        roi = gray_adj[roi_top_offset:sub_top + 10, :]
        x1 = 0
        x2 = w

    if roi.size == 0:
        return None
    roi_h, roi_w = roi.shape

    # Stage 1: contour ellipse
    blurred = cv2.GaussianBlur(roi, (5, 5), 1.5)
    best_contour_result = None
    for lo_thresh in [max(10, canny_thresh // 3), max(5, canny_thresh // 5), 5]:
        edges = cv2.Canny(blurred, lo_thresh, lo_thresh * 3)
        contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        for cnt in contours:
            if len(cnt) < 5 or cv2.contourArea(cnt) < 200:
                continue
            _, _, rw, rh = cv2.boundingRect(cnt)
            if rw < 20 or rh < 15:
                continue
            try:
                (ecx, ecy), (ma, mi), angle = cv2.fitEllipse(cnt)
            except Exception:
                continue
            semi_a, semi_b = ma / 2.0, mi / 2.0      # keep cv2's axis/angle pairing
            if min(semi_a, semi_b) < 1e-3:
                continue
            aspect = max(semi_a, semi_b) / min(semi_a, semi_b)
            if aspect > 5.0:
                continue
            ecx_full, ecy_full = ecx + x1, ecy + roi_top_offset
            bottom = ecy_full + max(semi_a, semi_b)
            if bottom > sub_top + max(10.0, min(semi_a, semi_b) * 0.15):
                continue
            area = cv2.contourArea(cnt)
            score = area - abs(bottom - sub_top) * 2.0
            if best_contour_result is None or score > best_contour_result[0]:
                best_contour_result = (score, [ecx_full, ecy_full, semi_a, semi_b, float(angle)])
        if best_contour_result is not None:
            break
    if best_contour_result is not None:
        return best_contour_result[1]

    # Stage 2: HoughCircles (with containment + stricter accumulator)
    blurred_h = cv2.GaussianBlur(roi, (9, 9), 2)
    cands: list[tuple[float, float, float]] = []
    for p2 in [35, 30, 25, 20]:
        circles = cv2.HoughCircles(
            blurred_h, cv2.HOUGH_GRADIENT, dp=1.5, minDist=40,
            param1=max(canny_thresh, 20), param2=p2,
            minRadius=15, maxRadius=max(roi_w, roi_h),
        )
        if circles is not None:
            for c in circles[0]:
                cands.append((c[0] + x1, c[1] + roi_top_offset, c[2]))
    if not cands:
        return None

    box = (float(x1), float(roi_top_offset), float(x2), float(roi_top_offset + roi_h))
    margin = _roi_margin(box)
    best, best_score = None, -1.0
    for cx, cy, r in cands:
        if bbox is not None and not _geometry_ok(cx, cy, r, float(sub_top), box, margin):
            continue
        if cy + r > sub_top + max(10.0, r * 0.15) and cy < sub_top:
            pass  # cap larger than circle bottom is fine; handled by geometry check
        votes = sum(1 for cx2, cy2, r2 in cands
                    if abs(cx2 - cx) < 25 and abs(cy2 - cy) < 25 and abs(r2 - r) < 25)
        score = votes * 10 - abs(cy - sub_top) * 0.05
        if score > best_score:
            best_score, best = score, (cx, cy, r)
    if best is None:
        return None
    cx, cy, r = best
    return [float(cx), float(cy), float(r), float(r), 0.0]


def auto_detect_ellipse(
    gray_adj: np.ndarray,
    sub_top: int,
    edge_sensitivity: int = 50,
    bbox: tuple[float, float, float, float] | None = None,
) -> tuple[list[float] | None, float]:
    """
    Dispatcher.
      • ROI locked  → ROI-constrained RANSAC fit first.  If that fails, the
        other detectors may try, but their result must pass the ROI gate.
      • No ROI      → auto_detect.py if present, else legacy.
    """
    if bbox is not None:
        ell, conf = detect_droplet_bbox(gray_adj, sub_top, edge_sensitivity, bbox)
        if ell is not None:
            return ell, conf

    ell, conf = None, 0.0
    if _HAVE_AUTO_DETECT:
        try:
            ell, conf = _detect_droplet_new(gray_adj, sub_top, edge_sensitivity, bbox)
        except Exception:
            ell, conf = None, 0.0
    if ell is None:
        ell = detect_droplet_ellipse(gray_adj, sub_top, edge_sensitivity, bbox)
        conf = 0.5 if ell is not None else 0.0

    if ell is not None and bbox is not None:
        if not _ellipse_in_bbox(ell, float(sub_top), bbox):
            return None, 0.0                        # never return a fit outside the ROI
        conf = min(conf, 0.5)                       # fallback result: ask operator to check
    return ell, conf


# ══════════════════════════════════════════════════════════════════════════════
#  WCA
# ══════════════════════════════════════════════════════════════════════════════

def compute_wca(
    ellipse: list[float],
    baseline_y: int,
) -> tuple | None:
    """
    Compute WCA from ellipse [cx, cy, semi_a, semi_b, angle_deg] and baseline_y.

    Returns (left_wca, right_wca, contact_left, contact_right,
             left_tangent, right_tangent) or None if the ellipse does not
    cross the baseline at two points.
    """
    cx, cy, a, b, angle_deg = ellipse
    angle_rad = np.deg2rad(angle_deg)

    N          = 4000
    angles_arr = np.linspace(0, 2 * np.pi, N, endpoint=False)
    cos_a      = np.cos(angle_rad)
    sin_a      = np.sin(angle_rad)

    ex = cx + a * np.cos(angles_arr) * cos_a - b * np.sin(angles_arr) * sin_a
    ey = cy + a * np.cos(angles_arr) * sin_a + b * np.sin(angles_arr) * cos_a

    dy          = ey - baseline_y
    sign_change = dy[:-1] * dy[1:] < 0

    crossings: list[tuple[float, float, float]] = []
    for i in np.where(sign_change)[0]:
        t_frac   = dy[i] / (dy[i] - dy[i + 1])
        t_interp = angles_arr[i] + t_frac * (angles_arr[i + 1] - angles_arr[i])
        xi       = cx + a * np.cos(t_interp) * cos_a - b * np.sin(t_interp) * sin_a
        crossings.append((xi, float(baseline_y), t_interp))

    if len(crossings) < 2:
        return None

    crossings.sort(key=lambda c: c[0])
    left_pt  = crossings[0]
    right_pt = crossings[-1]

    def tangent_at(t_param: float) -> tuple[float, float]:
        dx = -a * np.sin(t_param) * cos_a - b * np.cos(t_param) * sin_a
        dy = -a * np.sin(t_param) * sin_a + b * np.cos(t_param) * cos_a
        return float(dx), float(dy)

    def orient_into_drop(dx: float, dy: float) -> tuple[float, float]:
        if dy > 0:
            return -dx, -dy
        return dx, dy

    lt_dx, lt_dy = orient_into_drop(*tangent_at(left_pt[2]))
    rt_dx, rt_dy = orient_into_drop(*tangent_at(right_pt[2]))

    def contact_angle(dx: float, dy: float, side: str) -> float:
        mag    = np.hypot(dx, dy)
        dx_n   = dx / mag
        cos_th = dx_n if side == "left" else -dx_n
        cos_th = float(np.clip(cos_th, -1.0, 1.0))
        return float(np.degrees(np.arccos(cos_th)))

    left_wca  = contact_angle(lt_dx, lt_dy, "left")
    right_wca = contact_angle(rt_dx, rt_dy, "right")

    return (
        left_wca, right_wca,
        (float(left_pt[0]),  float(left_pt[1])),
        (float(right_pt[0]), float(right_pt[1])),
        (lt_dx, lt_dy),
        (rt_dx, rt_dy),
    )


def _classify(avg_angle: float) -> str:
    if avg_angle > 150:
        return "Superhydrophobic"
    if avg_angle > 90:
        return "Hydrophobic"
    return "Hydrophilic"


# ══════════════════════════════════════════════════════════════════════════════
#  DRAWING
# ══════════════════════════════════════════════════════════════════════════════

def _draw_annotated(
    image_orig: np.ndarray,
    ellipse: list[float],
    baseline_y: int,
    wca_result: tuple,
) -> np.ndarray:
    """Ellipse, baseline, tangents, dotted arcs and angle labels on a gray copy."""
    out = cv2.cvtColor(image_orig, cv2.COLOR_BGR2GRAY)
    out = cv2.cvtColor(out, cv2.COLOR_GRAY2BGR)
    h, w = out.shape[:2]

    cv2.line(out, (0, baseline_y), (w, baseline_y), (0, 0, 255), 2)

    cx_i, cy_i, a_i, b_i, angle_deg = ellipse
    ar = np.deg2rad(angle_deg)
    pts = []
    for t in np.linspace(0, 2 * np.pi, 300):
        ex = int(cx_i + a_i * np.cos(t) * np.cos(ar) - b_i * np.sin(t) * np.sin(ar))
        ey = int(cy_i + a_i * np.cos(t) * np.sin(ar) + b_i * np.sin(t) * np.cos(ar))
        pts.append([ex, ey])
    cv2.polylines(out, [np.array(pts, dtype=np.int32)], isClosed=True,
                  color=(0, 255, 100), thickness=2)
    cv2.circle(out, (int(cx_i), int(cy_i)), 5, (0, 255, 100), -1)

    if wca_result is not None:
        left_wca, right_wca, lpt, rpt, ltangent, rtangent = wca_result
        avg            = (left_wca + right_wca) / 2.0
        tangent_length = 100
        arc_radius     = 40
        PURPLE_BGR     = (128, 0, 128)
        RED_BGR        = (0, 0, 255)

        def draw_dotted_arc(img, cx, cy, r, start_deg, end_deg, color, dot_gap=6):
            a0      = np.radians(min(start_deg, end_deg))
            a1      = np.radians(max(start_deg, end_deg))
            arc_len = r * (a1 - a0)
            n_dots  = max(int(arc_len / dot_gap), 2)
            for i in range(n_dots):
                t   = a0 + (a1 - a0) * i / (n_dots - 1)
                cv2.circle(img, (int(cx + r * np.cos(t)), int(cy - r * np.sin(t))),
                           2, color, -1)

        for side, pt, tangent, wca in [
            ("left",  lpt, ltangent, left_wca),
            ("right", rpt, rtangent, right_wca),
        ]:
            px, py     = int(pt[0]), int(pt[1])
            dx, dy     = tangent
            mag        = np.hypot(dx, dy)
            dx_n, dy_n = dx / mag, dy / mag

            cv2.circle(out, (px, py), 5, PURPLE_BGR, -1)
            cv2.circle(out, (px, py), 7, (255, 255, 255), 1)

            tgt_end = (int(px + dx_n * tangent_length), int(py + dy_n * tangent_length))
            cv2.line(out, (px, py), tgt_end, RED_BGR, 2)

            base_end = (px - tangent_length, py) if side == "left" else (px + tangent_length, py)
            cv2.line(out, (px, py), base_end, RED_BGR, 2)

            if side == "left":
                s       = -(-dx_n / dy_n) if abs(dy_n) > 1e-6 else float("inf")
                tgt_ang = float(np.degrees(np.arctan2(1.0, s)))
                arc_s, arc_e = 0.0, tgt_ang
            else:
                s       = dx_n / (-dy_n) if abs(dy_n) > 1e-6 else float("inf")
                tgt_ang = float(np.degrees(np.arctan2(1.0, s)))
                arc_s, arc_e = 180.0 - tgt_ang, 180.0

            draw_dotted_arc(out, px, py, arc_radius, arc_s, arc_e, PURPLE_BGR)

            mid_rad = np.radians((arc_s + arc_e) / 2)
            lx2 = int(px + (arc_radius + 18) * np.cos(mid_rad))
            ly2 = int(py - (arc_radius + 18) * np.sin(mid_rad))
            cv2.putText(out, f"{wca:.1f}", (lx2 - 15, ly2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, PURPLE_BGR, 2)

        cv2.putText(out, f"WCA avg: {avg:.1f}deg", (20, 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, PURPLE_BGR, 2)

    return out


def _draw_edge_image(gray_adj: np.ndarray, edge_sensitivity: int,
                     bbox, sub_top: int) -> np.ndarray:
    """Adjusted image + green edges + ROI box + baseline (what the detector saw)."""
    out = cv2.cvtColor(gray_adj, cv2.COLOR_GRAY2BGR)
    out[edge_map(gray_adj, edge_sensitivity) > 0] = (0, 255, 0)
    h, w = out.shape[:2]
    cv2.line(out, (0, sub_top), (w, sub_top), (0, 255, 255), 2, cv2.LINE_AA)
    if bbox is not None:
        cv2.rectangle(out, (int(bbox[0]), int(bbox[1])), (int(bbox[2]), int(bbox[3])),
                      (255, 160, 0), 2)
    return out


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _load_gray(path: str) -> tuple[np.ndarray, np.ndarray]:
    img = cv2.imread(path)
    if img is None:
        raise ValueError(f"Cannot read image: {path}")
    return img, cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)


def _save_webp(img: np.ndarray, path: str, quality: int = 85) -> None:
    cv2.imwrite(path, img, [cv2.IMWRITE_WEBP_QUALITY, quality])


def _save_upload(file: UploadFile) -> str:
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")
    ext = os.path.splitext(file.filename)[1] or ".png"
    path = os.path.join(UPLOAD_DIR, f"{uuid.uuid4()}{ext}")
    with open(path, "wb") as buf:
        shutil.copyfileobj(file.file, buf)
    return path


def _saturation_warnings(gray_adj: np.ndarray, bbox, brightness: int,
                         contrast: float) -> list[str]:
    roi = gray_adj
    if bbox is not None:
        x1, y1, x2, y2 = (int(v) for v in bbox)
        roi = gray_adj[y1:y2, x1:x2]
    if roi.size == 0:
        return []
    hi = float((roi >= 250).mean())
    lo = float((roi <= 5).mean())
    out: list[str] = []
    if hi > 0.25:
        out.append(f"{hi * 100:.0f}% of the analysed area is saturated white "
                   f"(brightness {brightness}, contrast {contrast:.2f}); droplet "
                   f"edges may be washed out. Lower brightness/contrast.")
    if lo > 0.40:
        out.append(f"{lo * 100:.0f}% of the analysed area is crushed to black; "
                   f"raise brightness or lower contrast.")
    return out


def _resolve_baseline(gray_adj: np.ndarray, baseline_y: int | None) -> tuple[int, float]:
    h = gray_adj.shape[0]
    if baseline_y is not None:
        return int(np.clip(baseline_y, 0, h - 1)), 1.0
    return auto_find_substrate(gray_adj)


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES
# ══════════════════════════════════════════════════════════════════════════════

@app.get("/")
async def serve_test_client():
    html = """<!DOCTYPE html>
<html>
<head>
  <title>SurfEye WCA API Test</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body{font-family:sans-serif;padding:20px;max-width:680px;margin:0 auto;background:#f0f4f8}
    .card{background:#fff;padding:24px;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.1);margin-bottom:16px}
    h2{margin-top:0}h3{margin-top:0;color:#334}
    #result{background:#1e1e1e;color:#4af626;padding:16px;border-radius:8px;
            white-space:pre-wrap;font-family:monospace;min-height:60px}
    img{max-width:100%;border-radius:8px;margin-top:8px}
    .btn{background:#2563eb;color:#fff;padding:11px 18px;border:none;border-radius:8px;
         cursor:pointer;font-size:14px;width:100%;margin-top:8px}
    .btn:hover{background:#1d4ed8}.btn:disabled{opacity:.5;cursor:not-allowed}
    .btn2{background:#16a34a}.btn2:hover{background:#15803d}
    label{font-weight:600;font-size:13px}
    input[type=file]{display:block;margin:6px 0 12px;width:100%}
    input[type=number],input[type=text]{width:90px;padding:5px;border:1px solid #ccc;border-radius:6px;margin-right:8px}
    .row{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px}
    .hint{font-size:11px;color:#888;margin-top:4px}
  </style>
</head>
<body>
<div class="card">
  <h2>SurfEye WCA API Tester</h2>
  <label>Image</label>
  <input type="file" id="img" accept="image/*">

  <div class="row">
    <div><label>Brightness</label><br><input type="number" id="bri" value="0" min="-100" max="100"></div>
    <div><label>Contrast</label><br><input type="number" id="con" value="1.0" min="0.5" max="3.0" step="0.05"></div>
    <div><label>Edge Sensitivity</label><br><input type="number" id="edge" value="50" min="10" max="150"></div>
    <div><label>Baseline Y (px, optional)</label><br><input type="number" id="by" placeholder="auto"></div>
  </div>

  <label>Region lock (px or 0-1, optional)</label>
  <div class="row">
    <input type="number" id="rx1" placeholder="x1" step="any">
    <input type="number" id="ry1" placeholder="y1" step="any">
    <input type="number" id="rx2" placeholder="x2" step="any">
    <input type="number" id="ry2" placeholder="y2" step="any">
  </div>

  <button class="btn" onclick="detectDroplet()">1 — Detect Droplet (→ ellipse)</button>
  <p class="hint">After detecting, the ellipse params below will be filled in automatically.</p>

  <div class="row" id="ellipseRow" style="opacity:.4">
    <div><label>cx</label><br><input type="number" id="ecx" step="0.5"></div>
    <div><label>cy</label><br><input type="number" id="ecy" step="0.5"></div>
    <div><label>semi_a</label><br><input type="number" id="esa" step="0.5"></div>
    <div><label>semi_b</label><br><input type="number" id="esb" step="0.5"></div>
    <div><label>angle°</label><br><input type="number" id="eang" value="0" step="0.5"></div>
  </div>

  <button class="btn btn2" onclick="computeWCA()">2 — Compute WCA (→ angles + annotated image)</button>
  <div id="imgPreview"></div>
</div>
<div class="card">
  <h3>Result</h3>
  <div id="result">Load an image and click Detect Droplet to begin.</div>
</div>

<script>
const R = document.getElementById('result');
const EP = document.getElementById('ellipseRow');
let lastFile = null;

document.getElementById('img').addEventListener('change', function(){
  if(this.files[0]){
    lastFile = this.files[0];
    const reader = new FileReader();
    reader.onload = e => {
      document.getElementById('imgPreview').innerHTML = '<img src="'+e.target.result+'" style="margin-top:8px">';
    };
    reader.readAsDataURL(this.files[0]);
  }
});

function getFile(){
  const f = document.getElementById('img').files[0] || lastFile;
  if(!f){ R.innerText='No image selected.'; return null; }
  return f;
}

function baseForm(f){
  const fd = new FormData();
  fd.append('file', f);
  const by = document.getElementById('by').value;
  if(by) fd.append('baseline_y', by);
  fd.append('brightness', document.getElementById('bri').value);
  fd.append('contrast', document.getElementById('con').value);
  fd.append('edge_sensitivity', document.getElementById('edge').value);
  const ids = ['rx1','ry1','rx2','ry2'], keys = ['droplet_x1','droplet_y1','droplet_x2','droplet_y2'];
  const vals = ids.map(i => document.getElementById(i).value);
  if(vals.every(v => v !== '')) vals.forEach((v,i)=>fd.append(keys[i], v));
  return fd;
}

async function detectDroplet(){
  const f = getFile(); if(!f) return;
  R.innerText = 'Detecting droplet…';
  try{
    const res = await fetch('/detect',{method:'POST',body:baseForm(f)});
    const data = await res.json();
    R.innerText = 'HTTP '+res.status+'\\n\\n'+JSON.stringify(data,null,2);
    if(res.ok && data.cx != null){
      document.getElementById('ecx').value   = data.cx.toFixed(1);
      document.getElementById('ecy').value   = data.cy.toFixed(1);
      document.getElementById('esa').value   = data.semi_a.toFixed(1);
      document.getElementById('esb').value   = data.semi_b.toFixed(1);
      document.getElementById('eang').value  = (data.angle_deg||0).toFixed(1);
      EP.style.opacity = '1';
    }
  } catch(e){ R.innerText='Error: '+e.message; }
}

async function computeWCA(){
  const f = getFile(); if(!f) return;
  R.innerText = 'Computing WCA…';
  const fd = baseForm(f);
  const keys = ['cx','cy','semi_a','semi_b','angle_deg'];
  const ids  = ['ecx','ecy','esa','esb','eang'];
  keys.forEach((k,i)=>{ const v = document.getElementById(ids[i]).value; if(v) fd.append(k, v); });
  try{
    const res = await fetch('/analyze',{method:'POST',body:fd});
    const data = await res.json();
    R.innerText = 'HTTP '+res.status+'\\n\\n'+JSON.stringify(data,null,2);
    if(data.annotated_image_path){
      document.getElementById('imgPreview').innerHTML =
        '<img src="'+data.annotated_image_path+'" style="margin-top:8px">';
    }
  } catch(e){ R.innerText='Error: '+e.message; }
}
</script>
</body>
</html>"""
    return HTMLResponse(content=html)


# ── /detect ────────────────────────────────────────────────────────────────────
@app.post("/detect")
def detect_droplet(
    file: UploadFile = File(...),
    baseline_y:       int   | None = Form(default=None),
    droplet_x1:       float | None = Form(default=None),
    droplet_y1:       float | None = Form(default=None),
    droplet_x2:       float | None = Form(default=None),
    droplet_y2:       float | None = Form(default=None),
    brightness:       int          = Form(default=0),
    contrast:         float        = Form(default=1.0),
    edge_sensitivity: int          = Form(default=50),
):
    """
    Step 1 — detect the droplet and return ellipse parameters (pixel coords).
    With a locked region the fit is constrained to that region.
    """
    saved = _save_upload(file)
    try:
        _, gray = _load_gray(saved)
        h, w = gray.shape

        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)
        sub_top, baseline_conf = _resolve_baseline(gray_adj, baseline_y)
        bbox = parse_bbox(droplet_x1, droplet_y1, droplet_x2, droplet_y2, w, h)

        warnings = _saturation_warnings(gray_adj, bbox, brightness, contrast)
        if bbox is not None and sub_top <= bbox[1] + 20:
            warnings.append("Baseline is at/above the top of the locked region; "
                            "there is no droplet area above it.")

        ellipse, detect_conf = auto_detect_ellipse(gray_adj, sub_top, edge_sensitivity, bbox)

        if ellipse is None:
            detail = ("No droplet detected" +
                      (" inside the locked region" if bbox is not None else "") +
                      ". Try adjusting brightness/contrast, edge sensitivity, the "
                      "region, or the baseline position.")
            if warnings:
                detail += " Note: " + " ".join(warnings)
            raise HTTPException(status_code=422, detail=detail)

        cx, cy, semi_a, semi_b, angle_deg = ellipse
        return JSONResponse(content={
            "cx":                  cx,
            "cy":                  cy,
            "semi_a":              semi_a,
            "semi_b":              semi_b,
            "angle_deg":           angle_deg,
            "detected_baseline_y": sub_top,
            "image_width":         w,
            "image_height":        h,
            "confidence":          round(float(detect_conf), 3),
            "baseline_confidence": round(float(baseline_conf), 3),
            "roi_locked":          bbox is not None,
            "bbox_used":           list(bbox) if bbox is not None else None,
            "warnings":            warnings,
        })
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        if os.path.exists(saved):
            os.remove(saved)


# ── /analyze ───────────────────────────────────────────────────────────────────
@app.post("/analyze")
def analyze_droplet(
    file: UploadFile = File(...),
    baseline_y:       int   | None = Form(default=None),
    # Optional region (pixels OR normalised 0-1) used if no ellipse is supplied
    droplet_x1:       float | None = Form(default=None),
    droplet_y1:       float | None = Form(default=None),
    droplet_x2:       float | None = Form(default=None),
    droplet_y2:       float | None = Form(default=None),
    brightness:       int          = Form(default=0),
    contrast:         float        = Form(default=1.0),
    edge_sensitivity: int          = Form(default=50),
    # Explicit ellipse (pixels) from the app after the user dragged handles
    cx:               float | None = Form(default=None),
    cy:               float | None = Form(default=None),
    semi_a:           float | None = Form(default=None),
    semi_b:           float | None = Form(default=None),
    angle_deg:        float        = Form(default=0.0),
    # Legacy fine-tune scalars
    ellipse_scale_a:  float | None = Form(default=None),
    ellipse_scale_b:  float | None = Form(default=None),
    ellipse_angle:    float | None = Form(default=None),
):
    """
    Step 2 — compute WCA and return angles + annotated image.

    Explicit ellipse params are used AS SENT (the app has already applied its
    scale sliders to them).  ellipse_scale_a/b are applied only when the server
    has to auto-detect the ellipse itself.
    """
    saved    = _save_upload(file)
    file_id  = uuid.uuid4()
    out_path  = os.path.join(UPLOAD_DIR, f"{file_id}_annotated.webp")
    edge_path = os.path.join(UPLOAD_DIR, f"{file_id}_edges.webp")

    try:
        img_orig, gray = _load_gray(saved)
        h, w = gray.shape

        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)
        sub_top, _ = _resolve_baseline(gray_adj, baseline_y)
        bbox = parse_bbox(droplet_x1, droplet_y1, droplet_x2, droplet_y2, w, h)
        warnings = _saturation_warnings(gray_adj, bbox, brightness, contrast)

        if cx is not None and cy is not None and semi_a is not None and semi_b is not None:
            if semi_a <= 0 or semi_b <= 0:
                raise HTTPException(status_code=422, detail="semi_a and semi_b must be positive.")
            eff_angle = ellipse_angle if ellipse_angle is not None else angle_deg
            ellipse = [float(cx), float(cy), float(semi_a), float(semi_b), float(eff_angle)]
            method = "ellipse_tangent_manual"
        else:
            ellipse, _conf = auto_detect_ellipse(gray_adj, sub_top, edge_sensitivity, bbox)
            if ellipse is None:
                raise HTTPException(
                    status_code=422,
                    detail="No droplet detected. Please use Deteksi Tetesan first "
                           "or adjust preprocessing settings.",
                )
            ellipse = [ellipse[0], ellipse[1],
                       ellipse[2] * (ellipse_scale_a if ellipse_scale_a is not None else 1.0),
                       ellipse[3] * (ellipse_scale_b if ellipse_scale_b is not None else 1.0),
                       ellipse_angle if ellipse_angle is not None else ellipse[4]]
            method = "ellipse_tangent_auto"

        wca_result = compute_wca(ellipse, sub_top)
        if wca_result is None:
            raise HTTPException(
                status_code=422,
                detail="Ellipse does not intersect baseline at two points. "
                       "Move the baseline or adjust the ellipse.",
            )

        left_wca, right_wca, lpt, rpt, _lt, _rt = wca_result
        avg_angle = (left_wca + right_wca) / 2.0

        _save_webp(_draw_annotated(img_orig, ellipse, sub_top, wca_result), out_path)
        _save_webp(_draw_edge_image(gray_adj, edge_sensitivity, bbox, sub_top),
                   edge_path, quality=80)

        return JSONResponse(content={
            "left_angle":           left_wca,
            "right_angle":          right_wca,
            "average_angle":        avg_angle,
            "classification":       _classify(avg_angle),
            "method":               method,
            "contact_left_x":       lpt[0],
            "contact_left_y":       lpt[1],
            "contact_right_x":      rpt[0],
            "contact_right_y":      rpt[1],
            "ellipse_cx":           ellipse[0],
            "ellipse_cy":           ellipse[1],
            "ellipse_semi_a":       ellipse[2],
            "ellipse_semi_b":       ellipse[3],
            "ellipse_angle_deg":    ellipse[4],
            "detected_baseline_y":  sub_top,
            "droplet_width_px":     ellipse[2] * 2,
            "droplet_height_px":    ellipse[3] * 2,
            "annotated_image_path": "/image/" + os.path.basename(out_path),
            "edge_image_path":      "/image/" + os.path.basename(edge_path),
            "warnings":             warnings,
        })
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        if os.path.exists(saved):
            os.remove(saved)


# ── /preview ───────────────────────────────────────────────────────────────────
@app.post("/preview")
def preview_preprocessing(
    file: UploadFile = File(...),
    brightness:       int          = Form(default=0),
    contrast:         float        = Form(default=1.0),
    edge_sensitivity: int          = Form(default=50),
    sharpness:        int          = Form(default=0),
    baseline_y:       int   | None = Form(default=None),
    droplet_x1:       float | None = Form(default=None),
    droplet_y1:       float | None = Form(default=None),
    droplet_x2:       float | None = Form(default=None),
    droplet_y2:       float | None = Form(default=None),
):
    """
    Quick preview of what the detector sees: adjusted image, edges (same
    thresholds as /detect), baseline and the locked region.
    """
    if sharpness != 0:                      # legacy mapping used by older builds
        edge_sensitivity = int(np.clip(50 + sharpness, 10, 150))

    saved       = _save_upload(file)
    preview_out = os.path.join(UPLOAD_DIR, f"{uuid.uuid4()}_preview.webp")

    try:
        _, gray = _load_gray(saved)
        h, w = gray.shape
        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)

        by, _ = _resolve_baseline(gray_adj, baseline_y)
        bbox = parse_bbox(droplet_x1, droplet_y1, droplet_x2, droplet_y2, w, h)

        preview = _draw_edge_image(gray_adj, edge_sensitivity, bbox, by)
        cv2.putText(preview, "baseline", (5, max(by - 6, 12)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
        _save_webp(preview, preview_out, quality=80)

        return JSONResponse(content={
            "preview_image_path":  "/image/" + os.path.basename(preview_out),
            "detected_baseline_y": by,
            "warnings":            _saturation_warnings(gray_adj, bbox, brightness, contrast),
        })
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        if os.path.exists(saved):
            os.remove(saved)


# ── /image/{filename} ──────────────────────────────────────────────────────────
@app.get("/image/{filename}")
async def get_image(filename: str):
    safe = os.path.basename(filename)      # block path traversal
    path = os.path.join(UPLOAD_DIR, safe)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Image not found")

    ext        = os.path.splitext(safe)[1].lower()
    media_type = {
        ".webp": "image/webp",
        ".png":  "image/png",
        ".jpg":  "image/jpeg",
        ".jpeg": "image/jpeg",
    }.get(ext, "image/png")

    return FileResponse(path, media_type=media_type)


# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import uvicorn

    parser = argparse.ArgumentParser(description="SurfEye WCA API server")
    parser.add_argument("--no-ngrok", action="store_true",
                        help="Disable ngrok tunnel (LAN / localhost only)")
    parser.add_argument("--port", type=int, default=None,
                        help="Override port (default: PORT from .env or 8000)")
    args = parser.parse_args()

    port = args.port if args.port is not None else DEFAULT_PORT

    print(f"[SurfEye] auto_detect.py loaded: {_HAVE_AUTO_DETECT}")

    if not args.no_ngrok:
        try:
            from pyngrok import conf, ngrok

            if NGROK_TOKEN:
                conf.get_default().auth_token = NGROK_TOKEN
            else:
                print(
                    "[SurfEye] WARNING: No ngrok auth token.\n"
                    "  Set NGROK_AUTHTOKEN in .env or environment.\n"
                    "  Tunnelling may fail without a token.\n"
                )

            tunnel     = ngrok.connect(port, "http")
            public_url = tunnel.public_url.replace("http://", "https://")

            print("\n" + "=" * 60)
            print("  SurfEye WCA API — ngrok tunnel active")
            print(f"  Public URL : {public_url}")
            print(f"  Local URL  : http://localhost:{port}")
            print("=" * 60)
            print("\n  *** Paste the Public URL into AppConfig.baseUrl ***\n")

        except ImportError:
            print("[SurfEye] pyngrok not installed — running locally only.\n"
                  "  Install with:  pip install pyngrok\n")
        except Exception as exc:
            print(f"[SurfEye] ngrok tunnel failed: {exc}\n  Running locally.\n")
    else:
        print(f"[SurfEye] ngrok disabled.  Server at http://localhost:{port}")

    uvicorn.run("server_wca:app", host="0.0.0.0", port=port, reload=False)
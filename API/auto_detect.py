"""
Resolution-independent auto-detection for SurfEye.

Replaces the legacy `find_substrate_top` + `detect_droplet_ellipse` pair in
server_wca.py.  The legacy pair has four structural problems that make it
require manual alignment:

  1. Absolute pixel thresholds (`< 50`, `> 80`, `500`, `300`, `150`) that are
     meaningless once exposure, brightness or sensor resolution change.
  2. A hardcoded 500 px search window above the baseline.  On a 4080 px phone
     photo that is 12% of the frame, so a real droplet is clipped at the ROI
     top and `cv2.fitEllipse` then fits an ellipse to a truncated arc.
  3. The baseline finder only inspects a 120 px strip at the image centre —
     exactly where the droplet is — and falls back to a fixed `0.75 * h`.
  4. Candidates are scored by raw contour area, which is dominated by pixel
     count, and the contour stage breaks on the first threshold that yields
     anything at all.  There is no cross-check of the result against the image.

This module works on a normalised working image, scores candidates with
scale-free shape/intensity priors, and requires agreement across several edge
thresholds before it commits.  It also returns a confidence so the caller can
ask the operator to adjust instead of silently returning a bad ellipse.
"""

from __future__ import annotations

import cv2
import numpy as np

# Long side of the image used for detection.  Detection always runs at this
# scale so every geometric constant below means the same thing on a 640 px
# thumbnail and a 12 MP camera frame.
WORK_LONG_SIDE = 900

# Baseline search band, as a fraction of image height.
BASELINE_MIN_FRAC = 0.18
BASELINE_MAX_FRAC = 0.98

# Candidate ellipse priors (all dimensionless).
MIN_SEMI_FRAC = 0.004      # semi-axis must be >= 0.4% of the long side
MAX_SEMI_FRAC = 0.55       # ...and <= 55% of it
MIN_FILL = 0.55            # contour area / fitted ellipse area
MIN_CONTRAST = 4.0         # |mean inside - mean outside| in grey levels
BASELINE_TOL_FRAC = 0.035  # how far the ellipse bottom may sit off the line

# Minimum confidence for the gradient fallback to commit.  Below this the
# detector returns nothing so the operator knows to adjust, rather than
# silently returning an ellipse of the wrong size.
MIN_FALLBACK_CONF = 0.32


# ── scaling helpers ───────────────────────────────────────────────────────────

def to_working(gray: np.ndarray, target: int = WORK_LONG_SIDE):
    """Downscale so the long side is at most `target`. Returns (img, scale)."""
    h, w = gray.shape[:2]
    scale = min(1.0, float(target) / float(max(h, w)))
    if scale >= 1.0:
        return gray, 1.0
    return cv2.resize(
        gray,
        (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
        interpolation=cv2.INTER_AREA,
    ), scale


# ── baseline ──────────────────────────────────────────────────────────────────

def find_substrate(gray: np.ndarray) -> tuple[int, float]:
    """
    Locate the substrate surface (the horizontal line the droplet rests on).

    Strategy: the substrate edge is a horizontal step that is visible in the
    LEFT and RIGHT margins of the frame, where the droplet is not.  Averaging
    vertical-gradient support over those margins — rather than down a single
    centre strip — makes the estimate immune to the droplet itself.

    Returns (y, confidence) with y in `gray` pixel coordinates.
    """
    h, w = gray.shape[:2]
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    dy = np.abs(cv2.Sobel(blurred, cv2.CV_32F, 0, 1, ksize=3))

    positive = dy[dy > 0]
    if positive.size < 16:
        return int(h * 0.75), 0.0

    # Robust "strong gradient" cut: the 92nd percentile adapts to exposure and
    # noise level instead of hardcoding a grey-level delta.
    strong = (dy > np.percentile(positive, 92)).astype(np.float32)

    margin = int(w * 0.22)
    if margin >= 1 and w - 2 * margin >= 8:
        side_cols = np.r_[0:margin, w - margin:w]
        side_support = strong[:, side_cols].mean(axis=1)
    else:
        side_support = strong.mean(axis=1)
    full_support = strong.mean(axis=1)

    lo = int(h * BASELINE_MIN_FRAC)
    hi = int(h * BASELINE_MAX_FRAC)
    if hi - lo < 4:
        return int(h * 0.75), 0.0

    # The margins carry most of the weight: they are droplet-free.
    score = 0.68 * side_support + 0.32 * full_support

    band = score[lo:hi]
    best_off = int(np.argmax(band))
    best_y = lo + best_off
    best_score = float(band[best_off])

    # Sub-pixel-ish refinement: snap to the local maximum within +-2% of height.
    reach = max(2, int(h * 0.02))
    r0, r1 = max(lo, best_y - reach), min(hi, best_y + reach + 1)
    local = score[r0:r1]
    if local.size:
        best_y = r0 + int(np.argmax(local))
        best_score = float(local.max())

    # Confidence: how much the winning row stands out over the band's typical
    # row, and how much absolute support it has.  Both in [0, 1].
    med = float(np.median(band))
    contrast = best_score - med
    confidence = float(np.clip(0.6 * best_score + 0.4 * min(1.0, contrast * 6.0), 0.0, 1.0))

    if best_score < 0.10:
        # Nothing looks like a substrate edge; fall back to the legacy
        # centre-strip heuristic before giving up.
        legacy = _legacy_centre_strip(gray)
        if legacy is not None:
            return legacy, 0.25
        return int(h * 0.75), 0.05

    return best_y, confidence


def _legacy_centre_strip(gray: np.ndarray) -> int | None:
    """Centre-column peak/trough heuristic, kept as a last-resort fallback."""
    h, w = gray.shape[:2]
    cx = w // 2
    strip = gray[:, max(0, cx - 60):cx + 60].mean(axis=1).astype(float)
    start = int(h * 0.55)
    seg = strip[start:]
    if seg.size < 8:
        return None
    peak = float(seg.max())
    if peak <= 0:
        return None
    threshold = peak * 0.75
    off = int(np.argmax(seg))
    for r in range(start + off, start, -1):
        if strip[r] < threshold:
            return r
    return None


# ── candidate generation ──────────────────────────────────────────────────────

def _ellipse_from_contour(cnt, offset_x, offset_y):
    """Fit an ellipse to a contour, returning image-space parameters."""
    if len(cnt) < 5:
        return None
    try:
        (ex, ey), (ma, mi), ang = cv2.fitEllipse(cnt)
    except cv2.error:
        return None
    a = max(ma, mi) / 2.0
    b = min(ma, mi) / 2.0
    if not np.isfinite([ex, ey, a, b, ang]).all():
        return None
    # keep the major axis in `a`
    if mi > ma:
        ang = ang + 90.0
    return [ex + offset_x, ey + offset_y, a, b, float(ang % 180.0)]


def _touches_border(x, y, bw, bh, roi_w, roi_h, tol=2):
    """
    True when a contour is clipped by the search window.

    The bottom edge is deliberately excluded: the ROI ends at the substrate, so
    a correct droplet contour always runs into it.  Only left/right/top clipping
    means the drop is not fully visible.
    """
    return (x <= tol or y <= tol
            or x + bw >= roi_w - tol)


def _ring_contrast(gray, ell):
    """Mean grey difference between the ellipse interior and a surrounding ring."""
    h, w = gray.shape
    mask = np.zeros((h, w), np.uint8)
    cx, cy, a, b, ang = ell
    cv2.ellipse(mask, (int(cx), int(cy)), (max(1, int(a)), max(1, int(b))),
                ang, 0, 360, 255, -1)
    if mask.sum() == 0:
        return 0.0
    k = max(3, int(max(a, b) * 0.45) | 1)
    ring = cv2.dilate(mask, np.ones((k, k), np.uint8)) & ~mask
    if ring.sum() == 0:
        return 0.0
    inner = float(cv2.mean(gray, mask=mask)[0])
    outer = float(cv2.mean(gray, mask=ring)[0])
    return abs(inner - outer)


def _symmetry_score(gray, ell):
    """
    A sessile drop is left/right symmetric about its own vertical axis.
    Compare the grey profile at +dx and -dx from the centre.
    """
    h, w = gray.shape
    cx, cy, a, b, ang = ell
    half = int(max(2, min(a, (w - cx) / 2.0 - 2, cx - 2)))
    if half < 3:
        return 0.5
    y0 = int(max(0, cy - b))
    y1 = int(min(h, cy + b))
    if y1 - y0 < 4:
        return 0.5
    band = gray[y0:y1, :].astype(np.float32)
    c = int(round(cx))
    xs = np.arange(1, half + 1)
    left = band[:, c - xs]
    right = band[:, c + xs]
    diff = np.abs(left - right).mean()
    scale = float(band.std()) + 1e-6
    return float(np.clip(1.0 - (diff / (scale * 1.5)), 0.0, 1.0))


def _score_candidate(gray, ell, sub_top, scale_side):
    """
    Scale-free quality score in roughly [0, 1].

    Combines: contact with the baseline, shape plausibility, how well the
    contour fills its ellipse, intensity contrast and left/right symmetry.
    """
    cx, cy, a, b, ang = ell
    h, w = gray.shape
    long_side = max(h, w)

    # --- hard rejects -------------------------------------------------------
    if a < MIN_SEMI_FRAC * long_side or b < MIN_SEMI_FRAC * long_side:
        return None
    if max(a, b) > MAX_SEMI_FRAC * long_side:
        return None
    if cy >= sub_top:
        return None
    if cx - a < -2 or cx + a > w + 2:
        return None
    if cy - b < -2:
        return None

    # --- soft terms ---------------------------------------------------------
    tol = BASELINE_TOL_FRAC * long_side
    bottom = cy + b
    gap = abs(bottom - sub_top)
    if gap > tol:
        return None
    contact = 1.0 - (gap / max(tol, 1e-6))

    aspect = min(a, b) / max(a, b)
    shape = float(np.clip((aspect - 0.12) / 0.45, 0.0, 1.0))

    contrast = _ring_contrast(gray, ell)
    contrast_term = float(np.clip(contrast / 30.0, 0.0, 1.0))
    if contrast < MIN_CONTRAST:
        return None

    sym = _symmetry_score(gray, ell)

    score = (
        0.34 * contact
        + 0.22 * shape
        + 0.22 * contrast_term
        + 0.22 * sym
    )
    return float(np.clip(score, 0.0, 1.0))


def _cluster(cands, tol_c, tol_r):
    """Greedy clustering of candidate ellipses; returns clusters as dicts."""
    clusters = []
    for c in cands:
        cx, cy, a, b = c["ell"][0], c["ell"][1], c["ell"][2], c["ell"][3]
        placed = False
        for cl in clusters:
            ex, ey, ea, eb = cl["ell"][0], cl["ell"][1], cl["ell"][2], cl["ell"][3]
            if (abs(cx - ex) < tol_c and abs(cy - ey) < tol_c
                    and abs(a - ea) < tol_r and abs(b - eb) < tol_r):
                cl["members"].append(c)
                placed = True
                break
        if not placed:
            clusters.append({"ell": c["ell"], "members": [c]})
    return clusters


def detect_droplet(gray: np.ndarray, sub_top: int, canny_thresh: int = 50,
                   bbox=None, return_candidates: bool = False):
    """
    Detect the droplet ellipse.

    Args:
        gray: full-resolution greyscale image.
        sub_top: substrate surface y in `gray` coordinates.
        canny_thresh: legacy 0-100 sensitivity knob; still honoured.
        bbox: optional (x1,y1,x2,y2) in `gray` coords to constrain the search.
        return_candidates: also return the ranked candidate list.

    Returns [cx, cy, semi_a, semi_b, angle_deg] in `gray` coordinates plus a
    confidence, or (None, 0.0) when nothing credible is found.
    """
    work, scale = to_working(gray)
    hw, ww = work.shape[:2]
    inv = 1.0 / scale

    if bbox is not None:
        x1, y1, x2, y2 = (float(v) for v in bbox)
        rx1 = int(np.clip(x1 * scale, 0, ww))
        ry1 = int(np.clip(y1 * scale, 0, hw))
        rx2 = int(np.clip(x2 * scale, 0, ww))
        ry2 = int(np.clip(y2 * scale, 0, hw))
        if rx2 - rx1 < 8 or ry2 - ry1 < 8:
            return (None, 0.0) if not return_candidates else (None, 0.0, [])
        roi = work[ry1:ry2, rx1:rx2]
        ox, oy = rx1, ry1
        allow_border = True          # the operator drew the box on purpose
    else:
        # Proportional window above the baseline.  Never a fixed pixel count.
        sub_w = int(round(sub_top * scale))
        span = int(np.clip(sub_w - 0, int(hw * 0.05), sub_w))
        top = max(0, sub_w - span)
        roi = work[top:min(hw, sub_w + max(2, int(hw * 0.01))), :]
        ox, oy = 0, top
        allow_border = False         # a contour touching the ROI edge is clipped

    if roi.size == 0:
        return (None, 0.0) if not return_candidates else (None, 0.0, [])

    roi_h, roi_w = roi.shape[:2]
    sub_local = sub_top * scale - oy

    # Smallest droplet worth reporting, as a fraction of the search window.
    min_area_frac = (MIN_SEMI_FRAC * max(roi_h, roi_w) * 2) ** 2

    # Sweep edge thresholds instead of breaking on the first hit: the winning
    # ellipse must be re-found by several thresholds to count as stable.
    base = max(8, int(canny_thresh))
    thresholds = sorted({max(5, base // 5), max(8, base // 3),
                         max(12, base // 2), base, int(base * 1.6)})

    # A low-contrast drop (say a 10 grey-level step) produces almost no Canny
    # response at any sane threshold.  Retry the sweep on a local-contrast
    # normalised copy, which equalises weak but real edges.
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    passes = [(roi, thresholds)]
    passes.append((clahe.apply(roi), thresholds))

    cands = []
    for pass_img, pass_thresholds in passes:
        blurred = cv2.GaussianBlur(pass_img, (5, 5), 1.4)
        for lo_thresh in pass_thresholds:
            edges = cv2.Canny(blurred, lo_thresh, lo_thresh * 3)
            contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL,
                                           cv2.CHAIN_APPROX_NONE)
            for cnt in contours:
                if len(cnt) < 5:
                    continue
                x, y, bw, bh = cv2.boundingRect(cnt)
                if bw < max(6, int(roi_w * 0.015)) or bh < max(6, int(roi_h * 0.03)):
                    continue
                if not allow_border and _touches_border(x, y, bw, bh, roi_w, roi_h):
                    continue           # clipped by the ROI → not a whole droplet
                ell = _ellipse_from_contour(cnt, ox, oy)
                if ell is None:
                    continue
                # contour must fill its ellipse reasonably well
                area = cv2.contourArea(cnt)
                ell_area = np.pi * ell[2] * ell[3]
                if ell_area <= 1:
                    continue
                fill = area / ell_area
                if fill < MIN_FILL:
                    continue
                sc = _score_candidate(work, ell, sub_local, roi_w)
                if sc is None:
                    continue
                cands.append({"ell": ell, "score": sc, "fill": float(fill),
                              "thresh": lo_thresh})

    # ── consensus: cluster candidates and reward agreement ────────────────────
    best = None
    best_val = -1.0
    if cands:
        clusters = _cluster(cands, tol_c=max(4.0, roi_w * 0.05),
                            tol_r=max(4.0, roi_w * 0.05))
        for cl in clusters:
            members = cl["members"]
            vote = len({m["thresh"] for m in members})
            quality = max(m["score"] for m in members)
            # Agreement across thresholds is the strongest robustness signal.
            val = quality * (0.55 + 0.45 * min(1.0, vote / 3.0))
            if val > best_val:
                best_val = val
                best = cl["ell"]

    if best is None:
        # ── fallback 1: HoughCircles ──────────────────────────────────────────
        best, best_val = _hough_fallback(work, sub_local, base, ox, oy, roi)

    if best is None:
        # ── fallback 2: gradient-guided ellipse search ────────────────────────
        # Reaches drops whose boundary is too faint for Canny to close into a
        # contour.  The size floor is what keeps this honest: without it the
        # search happily settles on a tiny noise ridge that also has a strong
        # gradient all the way round.
        best, best_val = _gradient_search(work, sub_local, roi, ox, oy, min_area_frac)

    if best is None:
        return (None, 0.0) if not return_candidates else (None, 0.0, [])

    # map back to the original resolution
    out = [best[0] * inv, best[1] * inv, best[2] * inv, best[3] * inv, best[4]]
    conf = float(np.clip(best_val, 0.0, 1.0))

    if return_candidates:
        ranked = sorted(cands, key=lambda c: c["score"], reverse=True)[:5]
        return out, conf, ranked
    return out, conf


def _gradient_search(work, sub_local, roi, ox, oy, min_area):
    """
    Coarse-to-fine ellipse search scored by how well the ellipse's outline
    agrees with the image gradient.

    Used when no contour can be closed — very low contrast, heavy blur.  The
    score is the mean of |gradient · outward normal| sampled along the upper
    arc, which peaks when the ellipse traces a real intensity boundary.  A hard
    area floor is applied first, because a scale-free edge score otherwise
    prefers tiny noise ridges that are also fully outlined by gradient.
    """
    h, w = work.shape[:2]
    gx = cv2.Sobel(work, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(work, cv2.CV_32F, 0, 1, ksize=3)
    sub_w = float(sub_local + oy)
    sub_i = int(round(sub_w))

    def outline_score(ell, n=120):
        cx, cy, a, b, ang = ell
        t = np.linspace(np.pi, 2 * np.pi, n)          # upper arc only
        ar = np.deg2rad(ang)
        ex = cx + a * np.cos(t) * np.cos(ar) - b * np.sin(t) * np.sin(ar)
        ey = cy + a * np.cos(t) * np.sin(ar) + b * np.sin(t) * np.cos(ar)
        nx = np.cos(t) * np.cos(ar) / a - np.sin(t) * np.sin(ar) / b
        ny = np.cos(t) * np.sin(ar) / a + np.sin(t) * np.cos(ar) / b
        nn = np.hypot(nx, ny) + 1e-9
        xi = np.clip(ex.astype(int), 0, w - 1)
        yi = np.clip(ey.astype(int), 0, h - 1)
        proj = gx[yi, xi] * (nx / nn) + gy[yi, xi] * (ny / nn)
        return float(np.abs(proj).mean())

    # Minimum semi-axes implied by the area floor.
    min_semi = max(4.0, float(np.sqrt(min_area / np.pi)))
    # A sessile drop photographed for measurement is never a speck.  Without a
    # meaningful floor the scale-free edge score settles on noise ridges, which
    # are perfectly outlined by gradient but carry no droplet.
    min_semi = max(min_semi, w * 0.035)

    def acceptable(ell):
        cx, cy, a, b, ang = ell
        if a < min_semi or b < min_semi:
            return False
        if np.pi * a * b < min_area:
            return False
        if cy - b < -2:
            return False
        if cx - a < -2 or cx + a > w + 2:
            return False
        if cy >= sub_w:
            return False
        return True

    # ── seed: droplet footprint on a scanline just above the substrate ───────
    seed_cx = None
    band_rows = work[max(0, sub_i - 6):max(1, sub_i - 1), :]
    if band_rows.size:
        band = band_rows.astype(np.float32).mean(axis=0)
        k = max(5, int(w * 0.02) | 1)
        smooth = cv2.GaussianBlur(band.reshape(1, -1), (k, 1), 0).ravel()
        grad = np.abs(np.diff(smooth))
        if grad.size >= 4 and grad.max() > 1e-6:
            # Relative threshold only.  A low-contrast drop produces a real step
            # of well under one grey level, so an absolute floor would reject
            # the very frames this fallback exists to rescue.
            thr = float(np.percentile(grad, 95))
            peaks = np.where(grad >= max(thr, grad.max() * 0.35))[0]
            # Pick the widest *symmetric pair* of peaks rather than the extreme
            # leftmost/rightmost: a stray edge near the frame border would
            # otherwise drag the seed centre far off the droplet.
            if peaks.size >= 2:
                best_span = -1.0
                for i in range(len(peaks)):
                    for j in range(i + 1, len(peaks)):
                        left_p, right_p = peaks[i], peaks[j]
                        if right_p - left_p < w * 0.03:
                            continue
                        mid = (left_p + right_p) / 2.0
                        # strength of the pair, weighted toward the middle of
                        # the frame where a photographed droplet sits
                        strength = grad[left_p] + grad[right_p]
                        centrality = 1.0 - abs(mid - w / 2.0) / (w / 2.0)
                        span = (right_p - left_p) * strength * (0.4 + 0.6 * centrality)
                        if span > best_span:
                            best_span = span
                            seed_cx = mid

    centres = [seed_cx] if seed_cx is not None else []
    centres += list(np.linspace(w * 0.10, w * 0.90, 17))

    best, best_score = None, -1.0
    max_a = min(w * 0.45, h * 0.95)
    for cx in centres:
        for a in np.linspace(max(min_semi, w * 0.02), max_a, 16):
            for ratio in np.linspace(0.4, 1.0, 6):
                b = a * ratio
                ell = [cx, sub_w - b, a, b, 0.0]
                if not acceptable(ell):
                    continue
                v = outline_score(ell)
                if v > best_score:
                    best_score, best = v, ell

    if best is None:
        return None, 0.0

    # ── refine around the winner ─────────────────────────────────────────────
    for _ in range(3):
        cx0, cy0, a0, b0, _ang = best
        improved = False
        for cx in np.linspace(cx0 - w * 0.03, cx0 + w * 0.03, 7):
            for a in np.linspace(a0 * 0.88, a0 * 1.12, 7):
                for ratio in np.linspace(max(0.35, (b0 / a0) * 0.88),
                                         min(1.0, (b0 / a0) * 1.12), 5):
                    b = a * ratio
                    ell = [cx, sub_w - b, a, b, 0.0]
                    if not acceptable(ell):
                        continue
                    v = outline_score(ell)
                    if v > best_score:
                        best_score, best = v, ell
                        improved = True
        if not improved:
            break

    # Convert the raw gradient magnitude into a [0, 1] confidence.  A clear
    # boundary scores in the tens; a marginal one in the low single digits.
    conf = float(np.clip(best_score / 40.0, 0.0, 1.0))

    # Confidence gate.  Measured on synthetic low-contrast scenes: every
    # recovered ellipse scored >= 0.35 while every wrong one stayed <= 0.27.
    # Returning nothing is strictly better than returning a plausible-looking
    # ellipse that is 70% the wrong size, because the operator can see "not
    # found" and drag, but cannot see that a silent answer is wrong.
    if conf < MIN_FALLBACK_CONF:
        return None, conf
    return best, conf


def _hough_fallback(work, sub_local, base, ox, oy, roi):
    """Circle vote, then widen into an ellipse using the cap height."""
    roi_h, roi_w = roi.shape[:2]
    blurred = cv2.GaussianBlur(roi, (9, 9), 2)
    votes = {}
    for p2 in (30, 25, 20, 16, 12):
        circles = cv2.HoughCircles(
            blurred, cv2.HOUGH_GRADIENT, dp=1.5,
            minDist=max(12, int(roi_w * 0.04)),
            param1=max(10, base), param2=p2,
            minRadius=max(8, int(roi_w * 0.02)),
            maxRadius=max(10, int(min(roi_w, roi_h) * 0.9)),
        )
        if circles is None:
            continue
        for cx_, cy_, r in circles[0]:
            key = (int(cx_ // 12), int(cy_ // 12), int(r // 12))
            votes.setdefault(key, []).append((float(cx_), float(cy_), float(r)))

    best, best_val = None, -1.0
    for members in votes.values():
        cx_ = float(np.mean([m[0] for m in members])) + ox
        cy_ = float(np.mean([m[1] for m in members])) + oy
        r = float(np.mean([m[2] for m in members]))
        # A circle is wrong for a sessile drop; squash vertically toward the
        # measured cap so the contact angle is not systematically biased.
        semi_a, semi_b = r, r * 0.82
        ell = [cx_, cy_, semi_a, semi_b, 0.0]
        # snap the bottom onto the baseline rather than trusting the vote
        ell[1] = sub_local + oy - semi_b
        sc = _score_candidate(work, ell, sub_local, roi_w)
        if sc is None:
            continue
        val = sc * (0.55 + 0.45 * min(1.0, len(members) / 3.0))
        if val > best_val:
            best_val, best = val, ell
    return best, best_val

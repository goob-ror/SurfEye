"""
SurfEye WCA API server — self-contained, powered by test2.py logic.

All detection and computation comes from the three helper functions in test2.py:
  • adjust_brightness_contrast()
  • find_substrate_top()       → baseline auto-detection
  • detect_droplet_ellipse()   → HoughCircles droplet fit
  • compute_wca()              → tangent-based contact angle

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
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse

# ── Try to load port / ngrok token from .env (optional) ───────────────────────
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # python-dotenv not required

DEFAULT_PORT = int(os.getenv("PORT", "8000"))
NGROK_TOKEN  = os.getenv("NGROK_AUTHTOKEN", "")

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="SurfEye WCA API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# ══════════════════════════════════════════════════════════════════════════════
#  CORE FUNCTIONS  (ported verbatim from test2.py)
# ══════════════════════════════════════════════════════════════════════════════

def adjust_brightness_contrast(gray: np.ndarray, brightness: int, contrast: float) -> np.ndarray:
    """brightness ∈ [-100, 100], contrast ∈ [0.5, 3.0]"""
    img = gray.astype(np.float32)
    img = img * contrast + brightness
    return np.clip(img, 0, 255).astype(np.uint8)


def find_substrate_top(gray: np.ndarray) -> int:
    """Scan centre column strip upward to find the substrate surface top edge."""
    h, w = gray.shape
    cx = w // 2
    strip = gray[:, max(0, cx - 60):cx + 60].mean(axis=1).astype(float)
    start = int(h * 0.55)

    # Find dark zone (mean < 50) near bottom → substrate is just above it
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

    # No dark zone (white substrate like Teflon): find peak then its upper edge
    seg = strip[start:]
    peak_offset = int(np.argmax(seg))
    peak_val    = seg[peak_offset]
    threshold   = peak_val * 0.75
    for r in range(start + peak_offset, start, -1):
        if strip[r] < threshold:
            return r
    return int(h * 0.75)


def detect_droplet_ellipse(
    gray_adj: np.ndarray,
    sub_top: int,
    canny_thresh: int,
    bbox: tuple[int, int, int, int] | None = None,
) -> list[float] | None:
    """
    Detect droplet using two-stage approach:
    1) Contour-based ellipse fitting (handles clear semi-circular droplets well)
    2) HoughCircles fallback

    Returns [cx, cy, semi_a, semi_b, angle_deg] in image-pixel coords,
    or None if nothing was found.

    bbox: optional (x1, y1, x2, y2) pixel crop to constrain search region.
    """
    h, w = gray_adj.shape

    # Restrict to bbox if provided, otherwise full width above substrate
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

    if roi.size == 0:
        return None

    roi_h, roi_w = roi.shape

    # ── Stage 1: Contour-based ellipse fitting ────────────────────────────────
    blurred = cv2.GaussianBlur(roi, (5, 5), 1.5)
    best_contour_result = None

    for lo_thresh in [max(10, canny_thresh // 3), max(5, canny_thresh // 5), 5]:
        hi_thresh = lo_thresh * 3
        edges = cv2.Canny(blurred, lo_thresh, hi_thresh)

        contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)

        for cnt in contours:
            if len(cnt) < 5:
                continue
            # Minimum area to avoid noise
            area = cv2.contourArea(cnt)
            if area < 200:
                continue

            # Check bounding box is reasonable (not too thin)
            rx, ry, rw, rh = cv2.boundingRect(cnt)
            if rw < 20 or rh < 15:
                continue

            try:
                (ecx, ecy), (ma, Mi), angle = cv2.fitEllipse(cnt)
            except Exception:
                continue

            semi_a = max(ma, Mi) / 2.0
            semi_b = min(ma, Mi) / 2.0

            # Convert to full-image coords
            ecx_full = ecx + x1
            ecy_full = ecy + roi_top_offset

            # Aspect ratio: semi-circular droplet should be roughly 0.3..3.0
            if semi_b < 1e-3:
                continue
            aspect = semi_a / semi_b
            if aspect > 5.0 or aspect < 0.2:
                continue

            # Droplet bottom must be near (but not below) the baseline
            bottom = ecy_full + semi_b
            if bottom > sub_top + max(10.0, semi_b * 0.15):
                continue
            dist_to_baseline = abs(bottom - sub_top)

            score = area - dist_to_baseline * 2.0
            if best_contour_result is None or score > best_contour_result[0]:
                best_contour_result = (score, [ecx_full, ecy_full, semi_a, semi_b, float(angle)])

        if best_contour_result is not None:
            break  # Found a good contour, skip looser thresholds

    if best_contour_result is not None:
        return best_contour_result[1]

    # ── Stage 2: HoughCircles fallback ────────────────────────────────────────
    blurred_h = cv2.GaussianBlur(roi, (9, 9), 2)
    candidate_circles: list[tuple[float, float, float]] = []
    for p2 in [30, 25, 20, 15, 10]:
        circles = cv2.HoughCircles(
            blurred_h, cv2.HOUGH_GRADIENT, dp=1.5,
            minDist=40, param1=canny_thresh, param2=p2,
            minRadius=15, maxRadius=max(roi_w, roi_h),
        )
        if circles is not None:
            for c in circles[0]:
                cx_roi, cy_roi, r = c
                candidate_circles.append((cx_roi + x1, cy_roi + roi_top_offset, r))

    if not candidate_circles:
        return None

    best       = None
    best_score = -1.0
    for cx, cy, r in candidate_circles:
        if cy + r > sub_top + max(10.0, r * 0.15):
            continue
        votes = sum(
            1 for cx2, cy2, r2 in candidate_circles
            if abs(cx2 - cx) < 25 and abs(cy2 - cy) < 25 and abs(r2 - r) < 25
        )
        dist  = abs((cy + r) - sub_top)
        score = votes * 10 - dist * 0.05
        if score > best_score:
            best_score = score
            best = (int(cx), int(cy), int(r))

    if best is None:
        return None

    cx, cy, r = best
    return [float(cx), float(cy), float(r), float(r), 0.0]


def compute_wca(
    ellipse: list[float],
    baseline_y: int,
) -> tuple | None:
    """
    Compute WCA from ellipse [cx, cy, semi_a, semi_b, angle_deg] and baseline_y.

    Returns:
        (left_wca, right_wca,
         contact_left (x,y), contact_right (x,y),
         left_tangent (dx,dy), right_tangent (dx,dy))
    or None if the ellipse does not cross the baseline at two points.
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


def _draw_annotated(
    image_orig: np.ndarray,
    ellipse: list[float],
    baseline_y: int,
    wca_result: tuple,
) -> np.ndarray:
    """
    Draw ellipse, baseline, tangent lines, dotted arcs, and angle labels
    onto a copy of the original image.  Matches test2.py _save_result() exactly.
    """
    out = image_orig.copy()
    h, w = out.shape[:2]

    # ── Baseline ──────────────────────────────────────────────────────────────
    cv2.line(out, (0, baseline_y), (w, baseline_y), (0, 0, 255), 2)

    # ── Ellipse ───────────────────────────────────────────────────────────────
    cx_i, cy_i, a_i, b_i, angle_deg = ellipse
    pts = []
    for t in np.linspace(0, 2 * np.pi, 300):
        ar = np.deg2rad(angle_deg)
        ex = int(cx_i + a_i * np.cos(t) * np.cos(ar) - b_i * np.sin(t) * np.sin(ar))
        ey = int(cy_i + a_i * np.cos(t) * np.sin(ar) + b_i * np.sin(t) * np.cos(ar))
        pts.append([ex, ey])
    pts_arr = np.array(pts, dtype=np.int32)
    cv2.polylines(out, [pts_arr], isClosed=True, color=(0, 255, 100), thickness=2)
    cv2.circle(out, (int(cx_i), int(cy_i)), 5, (0, 255, 100), -1)

    # ── WCA overlays ──────────────────────────────────────────────────────────
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
                px2 = int(cx + r * np.cos(t))
                py2 = int(cy - r * np.sin(t))   # y-flip: image coords
                cv2.circle(img, (px2, py2), 2, color, -1)

        for side, pt, tangent, wca in [
            ("left",  lpt, ltangent, left_wca),
            ("right", rpt, rtangent, right_wca),
        ]:
            px, py  = int(pt[0]), int(pt[1])
            dx, dy  = tangent
            mag     = np.hypot(dx, dy)
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
            cv2.putText(out, f"{wca:.1f}",
                        (lx2 - 15, ly2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, PURPLE_BGR, 2)

        cv2.putText(out, f"WCA avg: {avg:.1f}deg",
                    (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.9, PURPLE_BGR, 2)

    return out


def _classify(avg_angle: float) -> str:
    if avg_angle > 150:
        return "Superhydrophobic"
    if avg_angle > 90:
        return "Hydrophobic"
    return "Hydrophilic"


# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _load_gray(path: str) -> tuple[np.ndarray, np.ndarray]:
    """Return (bgr_orig, gray) for the image at path."""
    img = cv2.imread(path)
    if img is None:
        raise ValueError(f"Cannot read image: {path}")
    return img, cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)


def _save_webp(img: np.ndarray, path: str, quality: int = 85) -> None:
    cv2.imwrite(path, img, [cv2.IMWRITE_WEBP_QUALITY, quality])


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES
# ══════════════════════════════════════════════════════════════════════════════

# ── Web test client ────────────────────────────────────────────────────────────
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

async function detectDroplet(){
  const f = getFile(); if(!f) return;
  R.innerText = 'Detecting droplet…';
  const fd = new FormData();
  fd.append('file', f);
  const by = document.getElementById('by').value;
  if(by) fd.append('baseline_y', by);
  fd.append('brightness', document.getElementById('bri').value);
  fd.append('contrast', document.getElementById('con').value);
  fd.append('edge_sensitivity', document.getElementById('edge').value);
  try{
    const res = await fetch('/detect',{method:'POST',body:fd});
    const data = await res.json();
    R.innerText = 'HTTP '+res.status+'\n\n'+JSON.stringify(data,null,2);
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
  const fd = new FormData();
  fd.append('file', f);
  const by = document.getElementById('by').value;
  if(by) fd.append('baseline_y', by);
  fd.append('brightness', document.getElementById('bri').value);
  fd.append('contrast', document.getElementById('con').value);
  fd.append('edge_sensitivity', document.getElementById('edge').value);
  // ellipse params
  ['cx','cy','semi_a','semi_b','angle_deg'].forEach((k,i)=>{
    const ids = ['ecx','ecy','esa','esb','eang'];
    const v = document.getElementById(ids[i]).value;
    if(v) fd.append(k, v);
  });
  try{
    const res = await fetch('/analyze',{method:'POST',body:fd});
    const data = await res.json();
    R.innerText = 'HTTP '+res.status+'\n\n'+JSON.stringify(data,null,2);
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
async def detect_droplet(
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
    Step 1 — Detect the droplet and return ellipse parameters.

    The Flutter calibration screen calls this after the user presses
    "Deteksi Tetesan".  The returned cx/cy/semi_a/semi_b are in image-pixel
    coordinates so Flutter can overlay and drag the ellipse handles.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")

    file_ext  = os.path.splitext(file.filename)[1] or ".png"
    file_id   = str(uuid.uuid4())
    saved     = os.path.join(UPLOAD_DIR, f"{file_id}{file_ext}")

    try:
        with open(saved, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        img_orig, gray = _load_gray(saved)
        h, w = gray.shape

        # ── 1. Brightness / contrast adjustment ───────────────────────────────
        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)

        # ── 2. Baseline ───────────────────────────────────────────────────────
        if baseline_y is not None:
            sub_top = int(np.clip(baseline_y, 0, h - 1))
        else:
            sub_top = find_substrate_top(gray_adj)

        # ── 3. Detect ellipse ─────────────────────────────────────────────────
        bbox = None
        if all(v is not None for v in [droplet_x1, droplet_y1, droplet_x2, droplet_y2]):
            bbox = (droplet_x1, droplet_y1, droplet_x2, droplet_y2)

        ellipse = detect_droplet_ellipse(gray_adj, sub_top, edge_sensitivity, bbox)

        if ellipse is None:
            raise HTTPException(
                status_code=422,
                detail="No droplet detected. Try adjusting brightness, edge "
                       "sensitivity, or baseline position.",
            )

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
        })

    finally:
        if os.path.exists(saved):
            os.remove(saved)


# ── /analyze ───────────────────────────────────────────────────────────────────
@app.post("/analyze")
async def analyze_droplet(
    file: UploadFile = File(...),
    # Baseline
    baseline_y:       int   | None = Form(default=None),
    # Optional pre-drawn bbox (used to re-detect if no ellipse supplied)
    droplet_x1:       float | None = Form(default=None),
    droplet_y1:       float | None = Form(default=None),
    droplet_x2:       float | None = Form(default=None),
    droplet_y2:       float | None = Form(default=None),
    # Preprocessing
    brightness:       int          = Form(default=0),
    contrast:         float        = Form(default=1.0),
    edge_sensitivity: int          = Form(default=50),
    # Explicit ellipse params (from Flutter after user drags handles)
    cx:               float | None = Form(default=None),
    cy:               float | None = Form(default=None),
    semi_a:           float | None = Form(default=None),
    semi_b:           float | None = Form(default=None),
    angle_deg:        float        = Form(default=0.0),
    # Legacy fine-tune scalars (kept for backward-compat with old Flutter build)
    ellipse_scale_a:  float | None = Form(default=None),
    ellipse_scale_b:  float | None = Form(default=None),
    ellipse_angle:    float | None = Form(default=None),
):
    """
    Step 2 — Compute WCA and return angles + annotated image.

    The Flutter "Hitung WCA" button sends the (possibly user-adjusted) ellipse
    params alongside the image so the server can draw the annotated result.

    If no ellipse params are supplied the server runs auto-detection first
    (same as /detect), which gives the same result as pressing both buttons
    in sequence with default settings.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")

    file_ext = os.path.splitext(file.filename)[1] or ".png"
    file_id  = str(uuid.uuid4())
    saved    = os.path.join(UPLOAD_DIR, f"{file_id}{file_ext}")
    out_path = os.path.join(UPLOAD_DIR, f"{file_id}_annotated.webp")

    try:
        with open(saved, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        img_orig, gray = _load_gray(saved)
        h, w = gray.shape

        # ── Preprocessing ─────────────────────────────────────────────────────
        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)

        # ── Baseline ──────────────────────────────────────────────────────────
        if baseline_y is not None:
            sub_top = int(np.clip(baseline_y, 0, h - 1))
        else:
            sub_top = find_substrate_top(gray_adj)

        # ── Ellipse ───────────────────────────────────────────────────────────
        if cx is not None and cy is not None and semi_a is not None and semi_b is not None:
            # Flutter sent explicit params (after user dragged handles)
            eff_angle = ellipse_angle if ellipse_angle is not None else angle_deg
            eff_a     = semi_a * (ellipse_scale_a if ellipse_scale_a is not None else 1.0)
            eff_b     = semi_b * (ellipse_scale_b if ellipse_scale_b is not None else 1.0)
            ellipse   = [float(cx), float(cy), eff_a, eff_b, eff_angle]
        else:
            # Auto-detect (fallback / "Hitung WCA" pressed without detection step)
            bbox = None
            if all(v is not None for v in [droplet_x1, droplet_y1, droplet_x2, droplet_y2]):
                bbox = (droplet_x1, droplet_y1, droplet_x2, droplet_y2)

            ellipse = detect_droplet_ellipse(gray_adj, sub_top, edge_sensitivity, bbox)
            if ellipse is None:
                raise HTTPException(
                    status_code=422,
                    detail="No droplet detected. Please use Deteksi Tetesan first "
                           "or adjust preprocessing settings.",
                )

        # ── Compute WCA ───────────────────────────────────────────────────────
        wca_result = compute_wca(ellipse, sub_top)
        if wca_result is None:
            raise HTTPException(
                status_code=422,
                detail="Ellipse does not intersect baseline at two points. "
                       "Move the baseline or adjust the ellipse.",
            )

        left_wca, right_wca, lpt, rpt, ltangent, rtangent = wca_result
        avg_angle = (left_wca + right_wca) / 2.0

        # ── Annotated image ───────────────────────────────────────────────────
        annotated = _draw_annotated(img_orig, ellipse, sub_top, wca_result)
        _save_webp(annotated, out_path)

        return JSONResponse(content={
            # Angles
            "left_angle":           left_wca,
            "right_angle":          right_wca,
            "average_angle":        avg_angle,
            "classification":       _classify(avg_angle),
            # Contact points (pixel coords)
            "contact_left_x":       lpt[0],
            "contact_left_y":       lpt[1],
            "contact_right_x":      rpt[0],
            "contact_right_y":      rpt[1],
            # Ellipse used (so Flutter can confirm what was computed)
            "ellipse_cx":           ellipse[0],
            "ellipse_cy":           ellipse[1],
            "ellipse_semi_a":       ellipse[2],
            "ellipse_semi_b":       ellipse[3],
            "ellipse_angle_deg":    ellipse[4],
            # Geometry
            "detected_baseline_y":  sub_top,
            "droplet_width_px":     ellipse[2] * 2,
            "droplet_height_px":    ellipse[3] * 2,
            # Images
            "annotated_image_path": "/image/" + os.path.basename(out_path),
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
async def preview_preprocessing(
    file: UploadFile = File(...),
    brightness:       int          = Form(default=0),
    contrast:         float        = Form(default=1.0),
    edge_sensitivity: int          = Form(default=50),
    sharpness:        int          = Form(default=0),
    baseline_y:       int   | None = Form(default=None),
):
    """
    Generate a quick preview of preprocessing results (edges + baseline).
    Used by the Flutter calibration screen as the user moves sliders,
    so speed matters — returns WebP, no full analysis.
    """
    if sharpness != 0:
        edge_sensitivity = int(np.clip(50 + sharpness, 10, 150))
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")

    file_ext    = os.path.splitext(file.filename)[1] or ".png"
    file_id     = str(uuid.uuid4())
    saved       = os.path.join(UPLOAD_DIR, f"{file_id}{file_ext}")
    preview_out = os.path.join(UPLOAD_DIR, f"{file_id}_preview.webp")

    try:
        with open(saved, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        img_orig, gray = _load_gray(saved)
        h, w = gray.shape

        # ── Adjust brightness / contrast ──────────────────────────────────────
        gray_adj = adjust_brightness_contrast(gray, brightness, contrast)

        # ── Canny edges ───────────────────────────────────────────────────────
        canny_low  = max(10, 100 - edge_sensitivity)
        canny_high = max(20, 200 - edge_sensitivity)
        edges      = cv2.Canny(gray_adj, canny_low, canny_high)

        # ── Build preview ─────────────────────────────────────────────────────
        preview_bgr = cv2.cvtColor(gray_adj, cv2.COLOR_GRAY2BGR)

        # Green edge overlay
        edge_overlay                = np.zeros_like(preview_bgr)
        edge_overlay[edges > 0]     = (0, 255, 0)
        preview_bgr = cv2.addWeighted(preview_bgr, 0.75, edge_overlay, 0.25, 0)

        # Baseline
        if baseline_y is not None:
            by = int(np.clip(baseline_y, 0, h - 1))
        else:
            by = find_substrate_top(gray_adj)
        cv2.line(preview_bgr, (0, by), (w, by), (0, 255, 255), 2, cv2.LINE_AA)
        cv2.putText(preview_bgr, "baseline",
                    (5, max(by - 6, 12)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)

        _save_webp(preview_bgr, preview_out, quality=80)

        return JSONResponse(content={
            "preview_image_path":  "/image/" + os.path.basename(preview_out),
            "detected_baseline_y": by,
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

    # ── Optional ngrok tunnel ──────────────────────────────────────────────────
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
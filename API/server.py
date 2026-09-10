"""
SurfEye API server — FastAPI + pyngrok tunnel.

Usage:
    python server.py                      # uses .env for configuration
    python server.py --no-ngrok           # LAN only (no tunnel)

The public ngrok URL is printed to stdout so you can paste it into
AppConfig.baseUrl in the Flutter app.

Configuration:
    Settings are loaded from .env file in the API directory.
    See .env.example for available options.
"""

import argparse
import os
import shutil
import uuid

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pipeline import run
from config_loader import get_ngrok_token, is_ngrok_disabled, PORT

app = FastAPI(title="SurfEye API")

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)


# ── Web test client ────────────────────────────────────────────────────────────
@app.get("/")
async def serve_test_client():
    html_content = """<!DOCTYPE html>
<html>
<head>
  <title>SurfEye API Test</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body{font-family:sans-serif;padding:20px;max-width:640px;margin:0 auto;background:#f5f5f5}
    .card{background:#fff;padding:24px;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.1)}
    h2{margin-top:0}
    #result{background:#1e1e1e;color:#4af626;padding:16px;border-radius:8px;
            white-space:pre-wrap;font-family:monospace;overflow-x:auto;min-height:60px}
    img{max-width:100%;border-radius:8px;margin-top:12px}
    .btn{background:#2563eb;color:#fff;padding:12px 20px;border:none;border-radius:8px;
         cursor:pointer;font-size:15px;width:100%;margin-top:10px}
    .btn:hover{background:#1d4ed8}
    .btn:disabled{opacity:.5;cursor:not-allowed}
    label{font-weight:600;font-size:14px}
    input[type=file]{display:block;margin:8px 0 16px;width:100%}
    input[type=number]{width:80px;padding:6px;border:1px solid #ccc;border-radius:6px}
  </style>
</head>
<body>
<div class="card">
  <h2>SurfEye API Tester</h2>
  <form id="form">
    <label>Image</label>
    <input type="file" id="img" accept="image/*" required>
    <label>Baseline Y override (optional)</label>
    <input type="number" id="by" placeholder="auto">
    <button class="btn" type="submit">Analyze</button>
  </form>
  <div id="preview"></div>
  <h3>Result</h3>
  <div id="result">Waiting for upload…</div>
</div>
<script>
const form=document.getElementById('form');
const imgInput=document.getElementById('img');
const preview=document.getElementById('preview');
const resultDiv=document.getElementById('result');
imgInput.addEventListener('change',function(){
  if(this.files&&this.files[0]){
    const r=new FileReader();r.onload=e=>preview.innerHTML='<img src="'+e.target.result+'">';
    r.readAsDataURL(this.files[0]);
  }
});
form.addEventListener('submit',async e=>{
  e.preventDefault();
  const btn=form.querySelector('.btn');btn.disabled=true;btn.innerText='Analyzing…';
  resultDiv.innerText='Processing…';
  const fd=new FormData();
  fd.append('file',imgInput.files[0]);
  const by=document.getElementById('by').value;
  if(by)fd.append('baseline_y',by);
  const t0=performance.now();
  try{
    const res=await fetch('/analyze',{method:'POST',body:fd});
    const data=await res.json();
    const ms=((performance.now()-t0)/1000).toFixed(2);
    resultDiv.innerText='HTTP '+res.status+' ('+ms+'s)\\n\\n'+JSON.stringify(data,null,2);
  }catch(err){resultDiv.innerText='Error: '+err.message;}
  finally{btn.disabled=false;btn.innerText='Analyze';}
});
</script>
</body>
</html>"""
    return HTMLResponse(content=html_content)


# ── Preview endpoint ───────────────────────────────────────────────────────────
@app.post("/preview")
async def preview_preprocessing(
    file: UploadFile = File(...),
    brightness: int = Form(default=0),
    contrast: float = Form(default=1.0),
    edge_sensitivity: int = Form(default=50),
    baseline_y: int | None = Form(default=None),
):
    """
    Generate a preview of the preprocessed image with current settings.
    Returns annotated image showing edges and baseline without full analysis.
    Uses WebP format for fast transmission.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")

    file_ext = os.path.splitext(file.filename)[1] or ".png"
    file_id = str(uuid.uuid4())
    saved_path = os.path.join(UPLOAD_DIR, f"{file_id}{file_ext}")

    try:
        with open(saved_path, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        # Import necessary functions
        import cv2
        import numpy as np
        from core.preprocessor import preprocess, adjust_brightness_contrast

        # Preprocess with current settings
        canny_low = max(10, 100 - edge_sensitivity)
        canny_high = max(20, 200 - edge_sensitivity)
        
        img, edges, roi_bounds = preprocess(
            saved_path,
            apply_roi=True,
            brightness=brightness,
            contrast=contrast,
            canny_threshold_low=canny_low,
            canny_threshold_high=canny_high,
        )

        # Apply tilt correction
        from core.tilt_correction import correct_tilt
        img_corrected, edges_corrected, tilt_angle = correct_tilt(img, edges)

        # Crop to ROI
        from core.preprocessor import crop_to_roi
        if roi_bounds is not None:
            gray_corrected = cv2.cvtColor(img_corrected, cv2.COLOR_BGR2GRAY)
            from core.preprocessor import detect_roi_bounds
            roi_bounds = detect_roi_bounds(gray_corrected, padding=50)
            img_roi = crop_to_roi(img_corrected, roi_bounds)
            edges_roi = crop_to_roi(edges_corrected, roi_bounds)
            roi_y_offset = roi_bounds[1]
        else:
            img_roi = img_corrected
            edges_roi = edges_corrected
            roi_y_offset = 0

        h, w = img_roi.shape[:2]

        # Create preview visualization
        preview = img_roi.copy()

        # Draw edges overlay
        edges_colored = cv2.cvtColor(edges_roi, cv2.COLOR_GRAY2BGR)
        edges_colored[edges_roi > 0] = [0, 255, 0]  # Green edges
        preview = cv2.addWeighted(preview, 0.7, edges_colored, 0.3, 0)

        # Draw baseline if provided
        if baseline_y is not None:
            baseline_y_roi = baseline_y - roi_y_offset
            if 0 <= baseline_y_roi < h:
                cv2.line(preview, (0, baseline_y_roi), (w, baseline_y_roi), 
                        (0, 255, 255), 2, cv2.LINE_AA)

        # Convert to WebP for efficient transmission
        webp_path = os.path.join(UPLOAD_DIR, f"{file_id}_preview.webp")
        cv2.imwrite(webp_path, preview, [cv2.IMWRITE_WEBP_QUALITY, 85])

        # Clean up original file
        os.remove(saved_path)

        return JSONResponse(content={
            "preview_image_path": "/image/" + os.path.basename(webp_path),
            "tilt_angle": float(tilt_angle),
            "roi_bounds": roi_bounds,
        })

    except Exception as exc:
        # Clean up on error
        for p in [saved_path, os.path.join(UPLOAD_DIR, f"{file_id}_preview.webp")]:
            if os.path.exists(p):
                os.remove(p)
        raise HTTPException(status_code=500, detail=str(exc))


# ── Analysis endpoint ──────────────────────────────────────────────────────────
@app.post("/analyze")
async def analyze_droplet(
    file: UploadFile = File(...),
    baseline_y: int | None = Form(default=None),
    droplet_x1: float | None = Form(default=None),
    droplet_y1: float | None = Form(default=None),
    droplet_x2: float | None = Form(default=None),
    droplet_y2: float | None = Form(default=None),
    use_ellipse: bool = Form(default=True),
    brightness: int = Form(default=0),
    contrast: float = Form(default=1.0),
    edge_sensitivity: int = Form(default=50),
    ellipse_angle: float | None = Form(default=None),
    ellipse_scale_a: float | None = Form(default=None),
    ellipse_scale_b: float | None = Form(default=None),
):
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")

    file_ext = os.path.splitext(file.filename)[1] or ".png"
    file_id = str(uuid.uuid4())
    saved_path = os.path.join(UPLOAD_DIR, f"{file_id}{file_ext}")

    try:
        with open(saved_path, "wb") as buf:
            shutil.copyfileobj(file.file, buf)

        # Build droplet bounding box tuple if all coordinates provided
        droplet_bbox = None
        if all(coord is not None for coord in [droplet_x1, droplet_y1, droplet_x2, droplet_y2]):
            droplet_bbox = (droplet_x1, droplet_y1, droplet_x2, droplet_y2)

        # Build ellipse adjustments dictionary if any parameter is provided
        ellipse_adjustments = None
        if any(param is not None for param in [ellipse_angle, ellipse_scale_a, ellipse_scale_b]):
            ellipse_adjustments = {
                'angle': ellipse_angle,
                'scale_a': ellipse_scale_a,
                'scale_b': ellipse_scale_b,
            }

        result = run(
            saved_path,
            visualize=False,
            baseline_y_override=baseline_y,
            droplet_bbox=droplet_bbox,
            use_ellipse=use_ellipse,
            brightness=brightness,
            contrast=contrast,
            edge_sensitivity=edge_sensitivity,
            ellipse_adjustments=ellipse_adjustments,
        )

        # Convert absolute file-system paths → relative URL paths the app can
        # fetch via GET /image/<filename>
        for key in ("edge_image_path", "annotated_image_path"):
            raw = result.get(key)
            if raw:
                result[key] = "/image/" + os.path.basename(raw)

        return JSONResponse(content=result)

    except Exception as exc:
        for p in [saved_path,
                  os.path.splitext(saved_path)[0] + "_edges.webp",
                  os.path.splitext(saved_path)[0] + "_annotated.webp"]:
            if os.path.exists(p):
                os.remove(p)
        raise HTTPException(status_code=500, detail=str(exc))


# ── Image file server ──────────────────────────────────────────────────────────
@app.get("/image/{filename}")
async def get_image(filename: str):
    safe = os.path.basename(filename)          # block path traversal
    path = os.path.join(UPLOAD_DIR, safe)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Image not found")
    
    # Determine media type based on extension
    ext = os.path.splitext(safe)[1].lower()
    media_type = {
        '.webp': 'image/webp',
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
    }.get(ext, 'image/png')
    
    return FileResponse(path, media_type=media_type)


# ── Entry point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    parser = argparse.ArgumentParser(description="SurfEye API server")
    parser.add_argument("--no-ngrok", action="store_true",
                        help="Disable ngrok tunnel (LAN / localhost only)")
    parser.add_argument("--port", type=int, default=None,
                        help="Port to run server on (default: 8000 from .env)")
    args = parser.parse_args()

    PORT = args.port if args.port is not None else PORT

    if not args.no_ngrok and not is_ngrok_disabled():
        try:
            from pyngrok import ngrok, conf

            token = get_ngrok_token()
            if token:
                conf.get_default().auth_token = token
            else:
                print(
                    "[SurfEye] WARNING: No ngrok auth token provided.\n"
                    "  Set NGROK_AUTHTOKEN in .env file.\n"
                    "  Tunnelling may fail without a token on newer ngrok plans.\n"
                )

            tunnel = ngrok.connect(PORT, "http")
            public_url = tunnel.public_url
            # ngrok v2 tunnels always give http; swap to https for safety
            public_url = public_url.replace("http://", "https://")

            print("\n" + "=" * 60)
            print("  SurfEye ngrok tunnel active")
            print(f"  Public URL : {public_url}")
            print(f"  Local URL  : http://localhost:{PORT}")
            print("=" * 60)
            print("\n  *** Paste the Public URL into AppConfig.baseUrl ***\n")

        except ImportError:
            print(
                "[SurfEye] pyngrok not installed — running locally only.\n"
                "  Install with:  pip install pyngrok\n"
            )
        except Exception as exc:
            print(f"[SurfEye] ngrok tunnel failed: {exc}\n"
                  "  Running locally only.\n")
    else:
        print(f"[SurfEye] ngrok disabled. Server at http://localhost:{PORT}")

    uvicorn.run("server:app", host="0.0.0.0", port=PORT, reload=False)

from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse, HTMLResponse
import shutil
import os
import uuid
from pipeline import run

app = FastAPI(title="SurfEye API")

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

@app.get("/")
async def serve_test_client():
    html_content = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>SurfEye API Test</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            body { font-family: sans-serif; padding: 20px; max-width: 600px; margin: 0 auto; background: #f9f9f9; }
            .card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
            #result { background: #2d2d2d; color: #4af626; padding: 15px; border-radius: 5px; white-space: pre-wrap; font-family: monospace; overflow-x: auto; }
            img { max-width: 100%; height: auto; margin-top: 15px; border-radius: 5px; }
            .btn { background: #007bff; color: white; padding: 12px 20px; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; width: 100%; margin-top: 10px; }
            .btn:hover { background: #0056b3; }
            input[type="file"] { padding: 10px; border: 1px solid #ccc; border-radius: 5px; width: 90%; }
        </style>
    </head>
    <body>
        <div class="card">
            <h2>SurfEye API Web Tester</h2>
            <p>Upload a droplet image from your PC or phone to test the backend pipeline.</p>
            <form id="uploadForm">
                <input type="file" id="imageFile" accept="image/*" required>
                <button type="submit" class="btn">Analyze Droplet</button>
            </form>
            <div id="preview"></div>
            <h3>Result:</h3>
            <div id="result">Waiting for upload...</div>
        </div>

        <script>
            const form = document.getElementById('uploadForm');
            const fileInput = document.getElementById('imageFile');
            const preview = document.getElementById('preview');
            const resultDiv = document.getElementById('result');

            fileInput.addEventListener('change', function() {
                if (this.files && this.files[0]) {
                    const reader = new FileReader();
                    reader.onload = function(e) {
                        preview.innerHTML = '<img src="' + e.target.result + '">';
                    }
                    reader.readAsDataURL(this.files[0]);
                }
            });

            form.addEventListener('submit', async (e) => {
                e.preventDefault();
                const btn = form.querySelector('.btn');
                btn.innerText = "Analyzing...";
                btn.disabled = true;
                resultDiv.innerText = "Processing on server...";
                
                const formData = new FormData();
                formData.append("file", fileInput.files[0]);

                const startTime = performance.now();
                try {
                    const response = await fetch('/analyze', {
                        method: 'POST',
                        body: formData
                    });
                    const data = await response.json();
                    const endTime = performance.now();
                    const timeTaken = ((endTime - startTime) / 1000).toFixed(2);
                    
                    let resultText = "Status Code: " + response.status + "\\n";
                    resultText += "Time Taken: " + timeTaken + "s\\n\\n";
                    resultText += JSON.stringify(data, null, 2);
                    resultDiv.innerText = resultText;
                } catch (error) {
                    resultDiv.innerText = "Error: " + error.message;
                } finally {
                    btn.innerText = "Analyze Droplet";
                    btn.disabled = false;
                }
            });
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content)

@app.post("/analyze")
async def analyze_droplet(file: UploadFile = File(...)):
    if not file.filename:
        raise HTTPException(status_code=400, detail="No file uploaded")
    
    # Save the file temporarily
    file_ext = os.path.splitext(file.filename)[1]
    temp_path = os.path.join(UPLOAD_DIR, f"{uuid.uuid4()}{file_ext}")
    
    try:
        with open(temp_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        # Run the pipeline (headless mode)
        # We need to make sure pipeline.py doesn't show matplotlib windows.
        result = run(temp_path, visualize=False)
        return JSONResponse(content=result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        # Clean up
        if os.path.exists(temp_path):
            os.remove(temp_path)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

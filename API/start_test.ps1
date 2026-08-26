param(
    [string]$NgrokToken
)

if ($NgrokToken) {
    Write-Host "Setting ngrok authtoken..." -ForegroundColor Cyan
    ngrok config add-authtoken $NgrokToken
}

Write-Host "Starting SurfEye FastAPI server..." -ForegroundColor Green
Start-Process -NoNewWindow "python" -ArgumentList "server.py"

Write-Host "Waiting for server to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

Write-Host "Starting ngrok tunnel on port 8000..." -ForegroundColor Green
ngrok http 8000

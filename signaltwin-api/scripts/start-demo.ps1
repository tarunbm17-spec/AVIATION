# Starts the back end and a public tunnel for a demo, locked to your Vercel site.
#   powershell -ExecutionPolicy Bypass -File scripts\start-demo.ps1 -Site https://aviation-ruddy-zeta.vercel.app
# Prints the address to paste into the Back end dialog. The access key is kept in api-key.local.txt (never committed).
param([string]$Site = "https://aviation-ruddy-zeta.vercel.app")
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $PSScriptRoot
Set-Location $dir
$py = Join-Path $dir ".venv\Scripts\python.exe"
$keyFile = Join-Path $dir "api-key.local.txt"
if (-not (Test-Path $keyFile)) { [IO.File]::WriteAllText($keyFile, (& $py -c "import secrets; print(secrets.token_urlsafe(24))").Trim() + "`n") }
$key = (Get-Content $keyFile -Raw).Trim()

# stop anything already serving port 8000 or tunnelling
$c = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) { Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $c.OwningProcess -or $_.ProcessId -eq $c.OwningProcess } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2

$env:ALLOWED_ORIGINS = "$Site,http://localhost:5173,http://127.0.0.1:5173"
$env:API_KEY = $key
Start-Process -FilePath $py -ArgumentList "-m","uvicorn","signaltwin_api.main:app","--host","127.0.0.1","--port","8000" -WorkingDirectory $dir -WindowStyle Hidden -RedirectStandardOutput "$dir\api.log" -RedirectStandardError "$dir\api.err.log"
for ($i = 0; $i -lt 40; $i++) { try { if ((Invoke-RestMethod http://127.0.0.1:8000/v1/health -TimeoutSec 2).status) { break } } catch { Start-Sleep 1 } }

$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) { $cf = "C:\Program Files (x86)\cloudflared\cloudflared.exe" }
$log = "$dir\tunnel.log"; Remove-Item $log -ErrorAction SilentlyContinue
Start-Process -FilePath $cf -ArgumentList "tunnel","--url","http://127.0.0.1:8000","--no-autoupdate" -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$log.out"
$url = $null
for ($i = 0; $i -lt 40 -and -not $url; $i++) { Start-Sleep 2; if (Test-Path $log) { $m = Select-String -Path $log -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" | Select-Object -First 1; if ($m) { $url = $m.Matches[0].Value } } }
if (-not $url) { throw "The tunnel did not start. See $log" }
[IO.File]::WriteAllText("$dir\tunnel-url.local.txt", "$url`n")
Write-Host ""
Write-Host "Back end is running and public at:  $url"
Write-Host "Paste that address into the Back end dialog on $Site"
Write-Host "Access key is in:  $keyFile   (copy it with:  Get-Content '$keyFile' | Set-Clipboard)"

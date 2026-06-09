# VoiceCoder v4 — Windows Installer
# Run in PowerShell (Admin):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   irm https://voicecoder-site-production.up.railway.app/install.ps1 | iex
#
# Or download first:
#   Invoke-WebRequest -Uri https://voicecoder-site-production.up.railway.app/install.ps1 -OutFile install.ps1
#   .\install.ps1

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$InstallDir = "$env:USERPROFILE\VoiceCoder"
$VenvPath = "$env:USERPROFILE\.venv\voicecoder"
$RepoUrl = "https://github.com/ClungTsang/voicecoder.git"
$ModelDir = "$env:USERPROFILE\.cache\sherpa-onnx\sense-voice-zh"
$TaskName = "VoiceCoderService"
$TaskNameDaemon = "VoiceCoderDaemon"

function Write-Info($msg) { Write-Host "  `u{25B8} $msg" -ForegroundColor White }
function Write-Ok($msg)   { Write-Host "  `u{2713} $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  `u{26A0} $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  `u{2717} $msg" -ForegroundColor Red; exit 1 }

# ── Uninstall ──
if ($Uninstall) {
    Write-Host ""
    Write-Info "Uninstalling VoiceCoder..."
    schtasks /Delete /TN $TaskName /F 2>$null
    schtasks /Delete /TN $TaskNameDaemon /F 2>$null
    Write-Ok "Scheduled tasks removed"
    Write-Host ""
    Write-Host "  Repo and model not deleted:" -ForegroundColor DarkGray
    Write-Host "    $InstallDir" -ForegroundColor DarkGray
    Write-Host "    $ModelDir" -ForegroundColor DarkGray
    Write-Host "    $VenvPath" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "  VoiceCoder v4  — Windows Installer" -ForegroundColor Cyan
Write-Host "  ------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# ── 0. Pre-flight ──
Write-Info "Checking system..."

if ($env:OS -notmatch "Windows") {
    Write-Fail "This installer is for Windows only."
}

# Check Python
$pythonExe = $null
foreach ($cmd in @("python3", "python")) {
    try {
        $ver = & $cmd --version 2>$null
        if ($ver -match "3\.(\d+)") {
            $minor = [int]$Matches[1]
            if ($minor -ge 11) {
                $pythonExe = (Get-Command $cmd).Source
                break
            }
        }
    } catch {}
}
if (-not $pythonExe) {
    Write-Fail "Python 3.11+ required. Install from https://python.org"
}
Write-Info "Python $($ver.Trim()) found: $pythonExe"

# Check Git
try {
    git --version | Out-Null
} catch {
    Write-Fail "Git required. Install from https://git-scm.com"
}
Write-Info "Git found"

# ── 1. Clone repo ──
if (Test-Path "$InstallDir\.git") {
    Write-Info "Repository exists, pulling latest..."
    Push-Location $InstallDir
    git pull --ff-only 2>$null
    Pop-Location
} else {
    Write-Info "Cloning repository -> $InstallDir"
    git clone $RepoUrl $InstallDir --depth 1
}

# ── 2. Create venv ──
if (-not (Test-Path $VenvPath)) {
    Write-Info "Creating Python virtual environment..."
    & $pythonExe -m venv $VenvPath
}

$venvPython = "$VenvPath\Scripts\python.exe"
$venvPip = "$VenvPath\Scripts\pip.exe"

Write-Info "Installing dependencies..."
& $venvPip install --upgrade pip -q 2>$null
& $venvPip install sounddevice numpy sherpa-onnx httpx pynput pyperclip -q 2>$null

# ── 3. Download model ──
if (Test-Path "$ModelDir\model.int8.onnx") {
    Write-Ok "SenseVoice model already exists"
} else {
    Write-Info "Downloading SenseVoice Small model (~1.1 GB, first time only)..."
    New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
    & $venvPip install huggingface_hub -q 2>$null
    & $venvPython -c @"
from huggingface_hub import snapshot_download
snapshot_download(
    'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    local_dir=r'$ModelDir',
    local_dir_use_symlinks=False
)
"@
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Model download failed, will retry on first start"
    }
}

# ── 4. Create scheduled tasks (auto-start) ──
Write-Info "Configuring auto-start..."

# Remove old tasks if exist
schtasks /Delete /TN $TaskName /F 2>$null
schtasks /Delete /TN $TaskNameDaemon /F 2>$null

# Service task (background, auto-start)
$serviceAction = New-ScheduledTaskAction -Execute $venvPython -Argument "`"$InstallDir\voicecoder_service.py`" --model sensevoice --lang zh"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $serviceAction -Trigger $trigger -Settings $settings -Description "VoiceCoder transcription service" -Force | Out-Null

# Daemon task (hotkey listener)
$daemonAction = New-ScheduledTaskAction -Execute $venvPython -Argument "`"$InstallDir\voicecoder_daemon.py`""
Register-ScheduledTask -TaskName $TaskNameDaemon -Action $daemonAction -Trigger $trigger -Settings $settings -Description "VoiceCoder hotkey daemon" -Force | Out-Null

Write-Ok "Auto-start configured"

# ── 5. Start now ──
Write-Info "Starting VoiceCoder..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
Start-ScheduledTask -TaskName $TaskNameDaemon

# ── 6. Verify ──
Write-Info "Waiting for service to start (model loading ~25s)..."
Start-Sleep -Seconds 8

try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 19641)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $reader = New-Object System.IO.StreamReader($stream)
    $writer.WriteLine('{"action":"ping"}')
    $writer.Flush()
    $response = $reader.ReadLine()
    $client.Close()

    if ($response -match '"ok"') {
        Write-Ok "Service running"
    } else {
        Write-Warn "Service starting (may need 30s for model loading)"
    }
} catch {
    Write-Warn "Service still loading, will be ready shortly"
}

Write-Host ""
Write-Host "  ------------------------------------" -ForegroundColor Green
Write-Host "  VoiceCoder v4 installed!" -ForegroundColor Green
Write-Host "  ------------------------------------" -ForegroundColor Green
Write-Host ""
Write-Host "  Trigger:   Hold middle mouse button to speak, release to paste"
Write-Host "  Check:     $venvPython $InstallDir\voicecoder_client.py ping"
Write-Host "  Uninstall: $InstallDir\install.ps1 -Uninstall"
Write-Host ""

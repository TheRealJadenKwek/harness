# Harness installer (Windows) — sets up the companion server that the iOS "Harness" app drives.
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
# Idempotent: keeps an existing token, re-registers the scheduled task.
$ErrorActionPreference = "Stop"

$Dest  = "$env:USERPROFILE\.claude-harness"
$Port  = 8787
$Task  = "HarnessServer"

Write-Host "`n== Harness installer (Windows) ==" -ForegroundColor Cyan

# 1) Prerequisites -----------------------------------------------------------
$Py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Py) { $Py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $Py) { throw "python not found. Install Python 3 from python.org or the Microsoft Store." }

function Find-Cli($name) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @("$env:USERPROFILE\.local\bin\$name.exe", "$env:APPDATA\npm\$name.cmd")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
$Claude = Find-Cli "claude"
$Codex  = Find-Cli "codex"
Write-Host "  python : $Py"
Write-Host "  claude : $(if ($Claude) { $Claude } else { 'NOT FOUND - install: irm https://claude.ai/install.ps1 | iex' })"
Write-Host "  codex  : $(if ($Codex)  { $Codex }  else { 'NOT FOUND - install: npm i -g @openai/codex' })"
if (-not $Claude -and -not $Codex) { throw "Need at least one of the claude / codex CLIs installed and logged in." }

# 2) Files -------------------------------------------------------------------
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path "$Src\server.py")) { throw "server.py not found next to install.ps1" }
New-Item -ItemType Directory -Force -Path $Dest, "$Dest\threads", "$Dest\trash", "$Dest\uploads" | Out-Null
Copy-Item "$Src\server.py" "$Dest\server.py" -Force
Write-Host "  server.py -> $Dest\server.py"

# 3) Token + config ----------------------------------------------------------
$Config = "$Dest\config.env"
if ((Test-Path $Config) -and (Select-String -Path $Config -Pattern '^HARNESS_TOKEN=' -Quiet)) {
  $Token = (Select-String -Path $Config -Pattern '^HARNESS_TOKEN=(.+)$').Matches[0].Groups[1].Value
  Write-Host "  Reusing existing token."
} else {
  $Token = & $Py -c "import secrets;print(secrets.token_urlsafe(24))"
  @(
    "# Harness config - keep this file private."
    "HARNESS_TOKEN=$Token"
    "HARNESS_PORT=$Port"
    "CLAUDE_BIN=$Claude"
    "CODEX_BIN=$Codex"
    "JOB_TIMEOUT=1800"
    "MAX_MSG_CHARS=100000"
  ) | Set-Content -Path $Config -Encoding ascii
  Write-Host "  Generated a new access token."
}

# 4) Auto-start at logon (Task Scheduler) -------------------------------------
$Action  = New-ScheduledTaskAction -Execute $Py -Argument "`"$Dest\server.py`"" -WorkingDirectory $env:USERPROFILE
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 3650)
Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $Task -Action $Action -Trigger $Trigger -Settings $Settings | Out-Null
Start-ScheduledTask -TaskName $Task
Write-Host "  Scheduled task '$Task' registered (starts at logon, restarts on crash)."

# 5) Firewall (inbound 8787; harmless if it already exists) --------------------
try {
  if (-not (Get-NetFirewallRule -DisplayName "Harness server" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Harness server" -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $Port | Out-Null
    Write-Host "  Firewall rule added for port $Port."
  }
} catch {
  Write-Warning "Could not add a firewall rule (need admin). If the app can't connect, allow TCP $Port inbound."
}

# 6) Verify + connection details ----------------------------------------------
$ok = $false
foreach ($i in 1..15) {
  try { Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null; $ok = $true; break }
  catch { Start-Sleep 1 }
}
if (-not $ok) { throw "Server didn't come up - check $Dest\stderr.log / Task Scheduler history." }

$TsIp = "<your-pc-tailscale-ip>"
$Ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $Ts -and (Test-Path "C:\Program Files\Tailscale\tailscale.exe")) { $Ts = @{Source="C:\Program Files\Tailscale\tailscale.exe"} }
if ($Ts) { $ip = (& $Ts.Source ip -4 2>$null | Select-Object -First 1); if ($ip) { $TsIp = $ip } }

Write-Host "`n✅ Done. In the iOS app -> gear -> enter:" -ForegroundColor Green
Write-Host "   URL    http://${TsIp}:$Port" -ForegroundColor White
Write-Host "   Token  $Token" -ForegroundColor White
Write-Host "`nMake sure your iPhone is logged into the SAME Tailscale account.`n"

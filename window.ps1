# window.ps1 - scheduler window for the mouse guard (ASCII only on purpose)
# Usage:
#   powershell -ExecutionPolicy Bypass -File window.ps1 status
#   powershell -ExecutionPolicy Bypass -File window.ps1 on|off
#   powershell -ExecutionPolicy Bypass -File window.ps1 stop|resume
#   powershell -ExecutionPolicy Bypass -File window.ps1 set 00:00 09:00
param(
  [Parameter(Position = 0)][string]$Action = "status",
  [Parameter(Position = 1)][string]$Start,
  [Parameter(Position = 2)][string]$End
)

$ErrorActionPreference = "Stop"
$ws = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir = Join-Path $ws ".dsh-mouse"
$cfgPath = Join-Path $dir "window.json"
$stopPath = Join-Path $dir "STOP"
$consentPath = Join-Path $dir "consent.json"

function Read-Cfg {
  if (Test-Path $cfgPath) {
    try { return Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  return [pscustomobject]@{ enabled = $false; start = "00:00"; end = "09:00"; note = "" }
}

function Save-Cfg($cfg) {
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = $cfg | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function To-Min([string]$v) {
  if ($v -notmatch '^(\d{1,2}):(\d{2})$') { return -1 }
  $h = [int]$Matches[1]; $m = [int]$Matches[2]
  if ($h -gt 23 -or $m -gt 59) { return -1 }
  return $h * 60 + $m
}

function Test-Open($cfg) {
  $a = To-Min $cfg.start; $b = To-Min $cfg.end
  if ($a -lt 0 -or $b -lt 0) { return $false }
  $n = Get-Date
  $t = $n.Hour * 60 + $n.Minute
  if ($a -eq $b) { return $true }
  if ($a -lt $b) { return ($t -ge $a -and $t -lt $b) }
  return ($t -ge $a -or $t -lt $b)
}

switch ($Action.ToLower()) {
  "status" {
    $cfg = Read-Cfg
    $stop = Test-Path $stopPath
    $open = (Test-Open $cfg) -and ($cfg.enabled -eq $true) -and (-not $stop)
    $mode = "unknown"
    if (Test-Path $consentPath) {
      try { $mode = (Get-Content $consentPath -Raw -Encoding UTF8 | ConvertFrom-Json).mode } catch { }
    }
    "enabled     : $($cfg.enabled)"
    "window      : $($cfg.start) - $($cfg.end)"
    "open now    : $open"
    "STOP file   : $stop"
    "consent mode: $mode"
    "config      : $cfgPath"
  }
  "on" { $cfg = Read-Cfg; $cfg.enabled = $true; Save-Cfg $cfg; "enabled = true" }
  "off" { $cfg = Read-Cfg; $cfg.enabled = $false; Save-Cfg $cfg; "enabled = false" }
  "stop" {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($stopPath, "emergency stop", (New-Object System.Text.UTF8Encoding($false)))
    "STOP created: the guard denies everything until 'resume'"
  }
  "resume" {
    if (Test-Path $stopPath) { Remove-Item $stopPath -Force; "STOP removed" } else { "no STOP file" }
  }
  "set" {
    if (-not $Start -or -not $End) { "usage: window.ps1 set HH:MM HH:MM"; exit 1 }
    if ((To-Min $Start) -lt 0 -or (To-Min $End) -lt 0) { "bad time format"; exit 1 }
    $cfg = Read-Cfg
    $cfg.enabled = $true; $cfg.start = $Start; $cfg.end = $End
    Save-Cfg $cfg
    "window = $Start - $End, enabled = true"
  }
  default { "usage: window.ps1 status|on|off|stop|resume|set HH:MM HH:MM" }
}

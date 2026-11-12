# mg.ps1 —— 鼠标托管闸门（mouse guard）的命令行工具
#
# 干什么：让 agent、运载窗口、用户手工都能查/改「DSH 能不能碰鼠标」的状态，
#         以及往运载窗口投一条提示（比如「请求完全权限」）。
#
# 用法：
#   mg status                     看当前托管状态 + 识别到的当前会话
#   mg grant -Mode session|24h    授予托管
#   mg revoke                     收回托管（改回每次询问）
#   mg block -Minutes 10          禁止 DSH 碰鼠标（冷却 N 分钟，期间直接拒绝、不弹窗）
#   mg ask -Calls 8 -Reason "..." 手工弹一次授权窗（等价于 MCP 的 mouse_request 工具）
#   mg notify -Kind permission -Text "DSH 请求完全权限（danger-full-access）"
#                                 往运载窗口投一条黄红横幅提示
#   mg log                        看闸门日志尾部
#
# ⚠ 本文件必须存成 UTF-8 **带 BOM**（PowerShell 5.1 遇无 BOM 会按 GBK 读，中文全毁）。

param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'grant', 'revoke', 'block', 'ask', 'notify', 'log')]
  [string]$Action = 'status',
  [ValidateSet('session', '24h')] [string]$Mode = 'session',
  [int]$Minutes = 10,
  [int]$Calls = 0,
  [int]$TimeoutSec = 120,
  [string]$Reason = '',
  [string]$ToolName = '',
  [ValidateSet('info', 'permission', 'mouse-request', 'mouse-granted', 'mouse-blocked')]
  [string]$Kind = 'info',
  [string]$Text = ''
)

$ErrorActionPreference = 'Stop'
# 工作区根：优先 DSH_MOUSE_WS，否则按脚本位置推（本文件在 <工作区>\tools\mouse-guard\）
$ws      = if ($env:DSH_MOUSE_WS) { $env:DSH_MOUSE_WS } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$mgDir   = Join-Path $ws '.dsh-mouse'
$stateF  = Join-Path $mgDir 'consent.json'
$noticeF = Join-Path $mgDir 'notice.json'
$guardLog = Join-Path $mgDir 'guard.log'
New-Item -ItemType Directory -Force -Path $mgDir -ErrorAction SilentlyContinue | Out-Null

function Write-JsonAtomic([string]$path, $obj) {
  $tmp = $path + '.tmp'
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Read-State {
  if (-not (Test-Path $stateF)) {
    return [pscustomobject]@{ mode = 'idle'; sessionId = ''; expiresAt = $null; blockedUntil = $null; updatedAt = $null; source = 'none' }
  }
  try { return (Get-Content -LiteralPath $stateF -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {
    return [pscustomobject]@{ mode = 'idle'; sessionId = ''; expiresAt = $null; blockedUntil = $null; updatedAt = $null; source = 'unreadable' }
  }
}
# 当前会话 = ~/.dsh/sessions 下 mtime 最新的 session-*（不依赖 hook，会话切换会自动跟着变）
function Get-CurrentSession {
  $root = Join-Path $env:USERPROFILE '.dsh\sessions'
  $best = $null; $bestMs = 0
  if (-not (Test-Path $root)) { return '' }
  foreach ($wd in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    foreach ($sd in (Get-ChildItem -LiteralPath $wd.FullName -Directory -ErrorAction SilentlyContinue)) {
      if (-not $sd.Name.StartsWith('session-')) { continue }
      $f = Join-Path $sd.FullName 'session.v3.jsonl.zstd'
      if (-not (Test-Path $f)) { continue }
      $ms = (Get-Item -LiteralPath $f).LastWriteTime.Ticks
      if ($ms -gt $bestMs) { $bestMs = $ms; $best = $sd.Name.Substring('session-'.Length) }
    }
  }
  return [string]$best
}
function Set-State($mode, $extra = @{}) {
  $s = [ordered]@{
    mode = $mode; sessionId = ''; expiresAt = $null; blockedUntil = $null
    updatedAt = (Get-Date).ToString('o'); source = 'mg.ps1'
  }
  foreach ($k in $extra.Keys) { $s[$k] = $extra[$k] }
  Write-JsonAtomic $stateF ([pscustomobject]$s)
}
function Log([string]$m) {
  Add-Content -LiteralPath $guardLog -Value ('{0}  mg  {1}' -f (Get-Date).ToString('HH:mm:ss'), $m) -Encoding UTF8
}

switch ($Action) {
  'status' {
    $s = Read-State
    $cur = Get-CurrentSession
    $eff = '需要询问（弹窗）'
    if ($s.mode -eq 'full-24h' -and $s.expiresAt -and ([datetime]$s.expiresAt) -gt (Get-Date)) { $eff = '完全托管中（24 小时档，至 ' + ([datetime]$s.expiresAt).ToString('MM-dd HH:mm') + '）' }
    elseif ($s.mode -eq 'full-session' -and $s.sessionId -eq $cur) { $eff = '完全托管中（本会话）' }
    elseif ($s.mode -eq 'full-session') { $eff = '本会话托管已随会话切换失效 → 需要询问' }
    elseif ($s.mode -eq 'blocked' -and $s.blockedUntil -and ([datetime]$s.blockedUntil) -gt (Get-Date)) { $eff = '禁止中（用户在用鼠标，冷却至 ' + ([datetime]$s.blockedUntil).ToString('HH:mm:ss') + '）' }
    elseif ($s.mode -eq 'blocked') { $eff = '禁止冷却已过 → 需要询问' }
    [pscustomobject]@{
      mode = $s.mode; effective = $eff; sessionId = $s.sessionId
      currentSession = $cur; expiresAt = $s.expiresAt; blockedUntil = $s.blockedUntil
      updatedAt = $s.updatedAt; source = $s.source
    } | Format-List
  }
  'grant' {
    if ($Mode -eq '24h') {
      Set-State 'full-24h' @{ sessionId = (Get-CurrentSession); expiresAt = (Get-Date).AddHours(24).ToString('o') }
      Log '授予：完全托管 24 小时'
    } else {
      Set-State 'full-session' @{ sessionId = (Get-CurrentSession) }
      Log '授予：完全托管（本会话）'
    }
    Write-JsonAtomic $noticeF ([pscustomobject]@{ kind = 'mouse-granted'; text = $(if ($Mode -eq '24h') { '鼠标完全托管（24 小时）' } else { '鼠标完全托管（本会话）' }); at = (Get-Date).ToString('o'); expiresAt = $null })
    'ok'
  }
  'revoke' {
    Set-State 'idle' @{}
    Write-JsonAtomic $noticeF ([pscustomobject]@{ kind = 'info'; text = '鼠标托管已收回，下次用鼠标会重新询问'; at = (Get-Date).ToString('o'); expiresAt = $null })
    Log '收回托管'
    'ok'
  }
  'block' {
    Set-State 'blocked' @{ blockedUntil = (Get-Date).AddMinutes($Minutes).ToString('o') }
    Write-JsonAtomic $noticeF ([pscustomobject]@{ kind = 'mouse-blocked'; text = ('用户使用中：DSH 已停止碰鼠标（' + $Minutes + ' 分钟）'); at = (Get-Date).ToString('o'); expiresAt = $null })
    Log ('禁止 ' + $Minutes + ' 分钟')
    'ok'
  }
  'ask' {
    $ps1 = Join-Path $PSScriptRoot 'mouse-consent.ps1'
    $out = Join-Path $mgDir 'last-result.json'
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Calls $Calls -Reason $Reason -ToolName $ToolName -TimeoutSec $TimeoutSec -OutFile $out -Session (Get-CurrentSession)
    if (Test-Path $out) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 } else { '（没有结果文件）' }
  }
  'notify' {
    Write-JsonAtomic $noticeF ([pscustomobject]@{
      kind = $Kind; text = $Text; at = (Get-Date).ToString('o')
      expiresAt = $(if ($Kind -eq 'permission') { (Get-Date).AddMinutes(20).ToString('o') } else { $null })
    })
    Log ('通知：[' + $Kind + '] ' + $Text)
    'ok'
  }
  'log' {
    if (Test-Path $guardLog) { Get-Content -LiteralPath $guardLog -Tail 40 -Encoding UTF8 } else { '（还没有日志）' }
  }
}

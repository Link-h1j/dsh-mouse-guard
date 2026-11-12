# mouse-consent.ps1 —— 「DSH 要动你的鼠标了」授权弹窗
#
# 谁调它：wincu MCP server（dsh-computer-use-win 的 mcp\server.mjs）在拦到第一次
#         「会抢鼠标/键盘」的工具调用时，spawn 本脚本并同步等结果文件。
#         也可以手动 / 由 tools\mouse-guard\mg.ps1 调。
#
# 三个选项（用户 2026-09-25 定的语义，勿改）：
#   ① 用户使用        → 禁止 DSH 碰鼠标（写 mode=blocked，进冷却期，期间再调用直接拒绝、不弹窗）
#   ② 完全托管·本会话 → 本会话内放行（写 mode=full-session + sessionId）
#   ③ 完全托管·24小时 → 24 小时内跨会话放行（写 mode=full-24h + expiresAt）
# 无人应答（默认 120 秒）→ 按 ②（本会话托管）放行，结果里 timeout=true，日志与运载窗口都会写明。
#
# 视觉（2026-11-12 第二版：改成 DSH 自己的设计语言）
#   token 全部取自 DSH 前端包（app.asar）里的 --dsw-* 变量，不自己编颜色：
#     bg-base #fff / #1b1b1c       label-primary #0f1115 / #ebeef2
#     border-l2 #0000001f          brand deepseek-500 #4176e6
#     state: green #22c55e · amber #f59e0b · red #ef4444
#     radius: xs4 / sm8 / md12 / lg16 / xl20
#   浅色深色跟随系统（AppsUseLightTheme），可用 -Theme light|dark 强制覆盖。
#   布局按 DSH 的对话框来：标题行 + 说明 + 信息块 + 状态行 + 倒计时 + 右对齐按钮组。
#   相比旧版：去掉琥珀呼吸光（DSH 不这样），改成中性投影；弹窗仍然 Topmost + 响一声保证被看到。
#
# 输出：-OutFile 指定的 JSON —— { choice, timeout, at, calls, tool, reason, session, pid }
#       （原子写：先写 .tmp 再 Move-Item 覆盖，读方永远看不到半截文件）
#
# ⚠ 本文件必须存成 UTF-8 **带 BOM**：Windows PowerShell 5.1 会把无 BOM 的 .ps1 当 GBK 读，
#   中文乱码 → 整份脚本解析失败 → 一行都不执行（本机踩过多次）。
#   改完补 BOM：
#   [IO.File]::WriteAllText($p,[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8),(New-Object Text.UTF8Encoding($true)))
#
# -Simulate user|session|24h 供自测用：不弹窗，直接写结果（验收闸门逻辑时用）。
# -PreviewPath <png> 供改版预览用：不弹窗、不抢前台，把卡片离屏渲染成 PNG 后退出。

param(
  [int]$Calls = 0,
  [string]$Reason = '',
  [string]$ToolName = '',
  [int]$TimeoutSec = 120,
  [string]$OutFile = '',
  [string]$Session = '',
  [ValidateSet('', 'user', 'session', '24h')] [string]$Simulate = '',
  [ValidateSet('', 'auto', 'light', 'dark')] [string]$Theme = '',
  [string]$PreviewPath = '',
  [string]$PreviewTitle = ''
)

$ErrorActionPreference = 'Stop'

$ws        = if ($env:DSH_MOUSE_WS) { $env:DSH_MOUSE_WS } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$mgDir     = Join-Path $ws '.dsh-mouse'
$guardLog  = Join-Path $mgDir 'guard.log'
if (-not $OutFile) { $OutFile = Join-Path $mgDir 'last-result.json' }
New-Item -ItemType Directory -Force -Path $mgDir -ErrorAction SilentlyContinue | Out-Null

function Log([string]$m) {
  try { Add-Content -LiteralPath $guardLog -Value ('{0}  consent  {1}' -f (Get-Date).ToString('HH:mm:ss'), $m) -Encoding UTF8 } catch {}
}

function Write-JsonAtomic([string]$path, $obj) {
  try {
    $tmp = $path + '.tmp'
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
  } catch { Log ('写结果失败: ' + $_.Exception.Message) }
}

# 运载窗口的黄红横幅（.dsh-mouse\notice.json）由 MCP server 侧写：弹窗前写 mouse-request、
# 拿到结果后写 mouse-granted / mouse-blocked。本脚本只负责把用户的选择写进 -OutFile —— 单一职责，
# 两边不抢同一个文件。

$choiceLabels = @{
  'user'    = '用户使用（禁止 DSH 碰鼠标）'
  'session' = 'DSH 完全托管 · 本会话'
  '24h'     = 'DSH 完全托管 · 24 小时'
}

# ---------- 自测通道：不弹窗，直接出结果 ----------
if ($Simulate) {
  $res = [pscustomobject]@{
    choice = $Simulate; timeout = $false; at = (Get-Date).ToString('o')
    calls = $Calls; tool = $ToolName; reason = $Reason; session = $Session; pid = $PID
  }
  Write-JsonAtomic $OutFile $res
  Log ('[simulate] ' + $choiceLabels[$Simulate])
  exit 0
}

# ---------- 定时托管窗口状态（读 .dsh-mouse\window.json） ----------
function To-Min([string]$v) {
  if ($v -notmatch '^(\d{1,2}):(\d{2})$') { return -1 }
  $h = [int]$Matches[1]; $m = [int]$Matches[2]
  if ($h -gt 23 -or $m -gt 59) { return -1 }
  return $h * 60 + $m
}

function Get-WindowStatus {
  if (Test-Path (Join-Path $mgDir 'STOP')) {
    return [pscustomobject]@{ text = '定时托管已被急停（STOP 文件存在）'; tone = 'danger' }
  }
  $cfgPath = Join-Path $mgDir 'window.json'
  if (-not (Test-Path $cfgPath)) {
    return [pscustomobject]@{ text = '定时托管未配置'; tone = 'off' }
  }
  try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
    return [pscustomobject]@{ text = '定时托管配置读取失败'; tone = 'off' }
  }
  if ($cfg.enabled -ne $true) {
    return [pscustomobject]@{ text = ('定时托管已关闭（配置窗口 ' + $cfg.start + '–' + $cfg.end + '）'); tone = 'off' }
  }
  $a = To-Min $cfg.start; $b = To-Min $cfg.end
  if ($a -lt 0 -or $b -lt 0) {
    return [pscustomobject]@{ text = '定时托管配置无效（时间格式）'; tone = 'off' }
  }
  $now = Get-Date
  $t = $now.Hour * 60 + $now.Minute
  $open = if ($a -eq $b) { $true } elseif ($a -lt $b) { ($t -ge $a) -and ($t -lt $b) } else { ($t -ge $a) -or ($t -lt $b) }
  if ($open) {
    return [pscustomobject]@{ text = ('定时托管生效中 · ' + $cfg.start + '–' + $cfg.end + ' 免授权'); tone = 'ok' }
  }
  $until = ($a - $t + 1440) % 1440
  if ($until -eq 0) { $until = 1440 }
  $h = [int][Math]::Floor($until / 60); $m = [int]($until % 60)
  $when = if ($h -gt 0) { "$h 小时 $m 分" } else { "$m 分" }
  return [pscustomobject]@{ text = ('夜间窗口 ' + $cfg.start + '–' + $cfg.end + ' · 还有 ' + $when); tone = 'off' }
}

$toolFriendly = @{
  'windows_computer_use_click'           = '点击'
  'windows_computer_use_double_click'    = '双击'
  'windows_computer_use_move'            = '移动指针'
  'windows_computer_use_drag'            = '拖拽'
  'windows_computer_use_scroll'          = '滚轮'
  'windows_computer_use_type_text'       = '输入文字'
  'windows_computer_use_keypress'        = '按键'
  'windows_computer_use_activate_window' = '切换前台窗口'
  'windows_computer_use_focus'           = '聚焦窗口'
  'windows_computer_use_mouse_request'   = '申请授权'
}

# ---------- 真弹窗 ----------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# 主题：默认跟随系统（DSH 的 ui-theme 也是 system）
$useDark = $false
$themeMode = if ($Theme) { $Theme } else { 'auto' }
if ($themeMode -eq 'dark') { $useDark = $true }
elseif ($themeMode -eq 'light') { $useDark = $false }
else {
  try {
    $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    $useDark = ($p.AppsUseLightTheme -eq 0)
  } catch { $useDark = $false }
}

# token 全部来自 DSH app.asar 的 --dsw-* 变量
# ⚠ CSS 的 8 位色是 #RRGGBBAA，WPF 是 #AARRGGBB —— 直接喂给 WPF 会把「12% 白」当成不透明亮黄，
#   把「12% 黑」当成全透明。下面 To-WpfColor 负责换位；6 位色原样通过。
function To-WpfColor([string]$hex) {
  if ($hex -match '^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})$') { return '#' + $Matches[2] + $Matches[1] }
  return $hex
}

if ($useDark) {
  $T = @{
    bg = '#1B1B1C'; surface = '#232324'; surfaceAlt = '#2C2C2E'
    border = '#FFFFFF1F'; borderSoft = '#FFFFFF14'; divider = '#FFFFFF14'
    text = '#EBEEF2'; text2 = '#ADB2B8'; text3 = '#81858C'
    accent = '#4176E6'; accentHover = '#5686FE'; onAccent = '#FFFFFF'
    ghostBorder = '#FFFFFF29'; ghostText = '#EBEEF2'
    okBg = '#13261B'; okTx = '#4ED17E'; okDot = '#22C55E'
    offBg = '#2C2C2E'; offTx = '#979DA6'; offDot = '#979DA6'
    badBg = '#2A1416'; badTx = '#F25A5A'; badDot = '#EF4444'
    track = '#353638'; stage = '#0F1115'
  }
} else {
  $T = @{
    bg = '#FFFFFF'; surface = '#F9FAFB'; surfaceAlt = '#F5F7FA'
    border = '#0000001F'; borderSoft = '#0000000A'; divider = '#0000000A'
    text = '#0F1115'; text2 = '#61666B'; text3 = '#81858C'
    accent = '#4176E6'; accentHover = '#3B82F6'; onAccent = '#FFFFFF'
    ghostBorder = '#00000029'; ghostText = '#353638'
    okBg = '#E6FAED'; okTx = '#15803D'; okDot = '#22C55E'
    offBg = '#F5F7FA'; offTx = '#61666B'; offDot = '#979DA6'
    badBg = '#FEF2F2'; badTx = '#C81E1E'; badDot = '#EF4444'
    track = '#EBEEF2'; stage = '#F5F6F7'
  }
}

foreach ($k in @($T.Keys)) { $T[$k] = To-WpfColor $T[$k] }

$callsNum  = if ($Calls -gt 0) { [string]$Calls } else { '?' }
$callsUnit = if ($Calls -gt 0) { '次鼠标 / 键盘操作' } else { '次数未声明' }
$reasonLine = if ($Reason) { $Reason } else { '（没有说明理由）' }
$friendly  = if ($ToolName -and $toolFriendly.ContainsKey($ToolName)) { $toolFriendly[$ToolName] } else { '' }
$toolLine  = if ($friendly) { $friendly } elseif ($ToolName) { $ToolName } else { '（未指定）' }
$sessShort = if ($Session) { '会话 ' + $Session.Substring(0, [Math]::Min(8, $Session.Length)) } else { '会话未知' }
$winStatus = Get-WindowStatus
if ($PreviewTitle) { $reasonLine = $PreviewTitle }

$toneBg = @{ 'ok' = $T.okBg; 'off' = $T.offBg; 'danger' = $T.badBg }
$toneTx = @{ 'ok' = $T.okTx; 'off' = $T.offTx; 'danger' = $T.badTx }
$toneDot = @{ 'ok' = $T.okDot; 'off' = $T.offDot; 'danger' = $T.badDot }
$toneBorder = @{ 'ok' = $T.okDot; 'off' = $T.borderSoft; 'danger' = $T.badDot }

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 请求使用你的鼠标" Width="520" SizeToContent="Height"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="True" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="DlgBtn" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="MinWidth" Value="92"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- Margin 24 给中性投影留画布 -->
  <Border x:Name="Shell" Margin="24" CornerRadius="16" BorderThickness="1"
          Background="@@BG@@" BorderBrush="@@BORDER@@">
    <Border.Effect>
      <DropShadowEffect x:Name="Shadow" BlurRadius="28" ShadowDepth="6" Direction="270" Opacity="0.16" Color="#0F1115"/>
    </Border.Effect>

    <Grid>
      <StackPanel Margin="22,18,22,16">

        <!-- 标题行 -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Width="30" Height="30" CornerRadius="9" Background="@@ACCENT@@" VerticalAlignment="Center">
            <Grid Width="13" Height="17" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border CornerRadius="6.5" BorderBrush="#FFFFFF" BorderThickness="1.4"/>
              <Border Height="1.1" Background="#FFFFFF" VerticalAlignment="Top" Margin="0,5,0,0"/>
            </Grid>
          </Border>
          <StackPanel Grid.Column="1" Margin="11,0,8,0" VerticalAlignment="Center">
            <TextBlock Text="DSH 想使用你的鼠标" Foreground="@@TEXT@@" FontSize="15.5" FontWeight="SemiBold"/>
            <TextBlock x:Name="SubText" Text="" Foreground="@@TEXT3@@" FontSize="11.5" Margin="0,3,0,0"/>
          </StackPanel>
          <Border x:Name="StatusChip" Grid.Column="2" CornerRadius="7" BorderThickness="1"
                  Background="@@WARNBG@@" BorderBrush="@@WARNBORDER@@" Padding="8,4" VerticalAlignment="Center">
            <TextBlock x:Name="StatusChipText" Text="等待你决定" Foreground="@@WARNTX@@" FontSize="11"/>
          </Border>
        </Grid>

        <Border Height="1" Background="@@DIVIDER@@" Margin="0,14,0,0"/>

        <!-- 计划信息块 -->
        <Border x:Name="PlanCard" Background="@@SURFACE@@" CornerRadius="10" BorderBrush="@@BORDERSOFT@@"
                BorderThickness="1" Padding="14,12,14,13" Margin="0,14,0,0">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="CallsNum" Text="3" Foreground="@@ACCENT@@" FontSize="17" FontWeight="Bold"/>
              <TextBlock x:Name="CallsUnit" Text="次鼠标 / 键盘操作" Foreground="@@TEXT2@@" FontSize="11.5"
                         Margin="6,0,0,0" VerticalAlignment="Bottom"/>
              <Border Background="@@SURFACEALT@@" CornerRadius="5" Padding="7,2" Margin="10,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="ToolText" Text="点击" Foreground="@@TEXT2@@" FontSize="11"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="ReasonText" Text="—" Foreground="@@TEXT@@" FontSize="12.5" Margin="0,8,0,0"
                       TextWrapping="Wrap" MaxHeight="36" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>

        <!-- 定时托管状态 -->
        <Border x:Name="PillBorder" CornerRadius="8" BorderThickness="1" Background="@@OFFBG@@"
                BorderBrush="@@BORDERSOFT@@" Padding="10,7" Margin="0,10,0,0">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="PillDot" Width="6" Height="6" Fill="@@OFFDOT@@" VerticalAlignment="Center" Margin="0,0,7,0"/>
            <TextBlock x:Name="PillText" Text="" Foreground="@@OFFTX@@" FontSize="11.5" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- 倒计时 -->
        <Grid Margin="1,13,1,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="CountdownText" Text="" Foreground="@@TEXT3@@" FontSize="11.5"/>
          <TextBlock x:Name="LeftText" Text="" Foreground="@@TEXT2@@" FontSize="11.5" FontFamily="Consolas"
                     HorizontalAlignment="Right"/>
          <Border Grid.Row="1" Height="3" Background="@@TRACK@@" CornerRadius="2" Margin="0,8,0,0">
            <Border x:Name="CountFill" HorizontalAlignment="Left" Width="400" CornerRadius="2" Background="@@ACCENT@@"/>
          </Border>
        </Grid>

        <Border Height="1" Background="@@DIVIDER@@" Margin="0,15,0,0"/>

        <!-- 按钮组（DSH 风格：右对齐，主操作在右） -->
        <Grid Margin="0,13,0,0">
          <TextBlock x:Name="HintText" Text="1 / 2 / 3 选择 · Esc 跳过" Foreground="@@TEXT3@@"
                     FontSize="11" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnUser" Style="{StaticResource DlgBtn}" Background="Transparent"
                    BorderBrush="@@GHOSTBORDER@@" BorderThickness="1" Foreground="@@GHOSTTEXT@@"
                    Content="用户使用 (1)" Margin="0,0,8,0"
                    AutomationProperties.Name="选择：用户使用，禁止 DSH 碰鼠标"/>
            <Button x:Name="Btn24h" Style="{StaticResource DlgBtn}" Background="Transparent"
                    BorderBrush="@@GHOSTBORDER@@" BorderThickness="1" Foreground="@@GHOSTTEXT@@"
                    Content="24 小时 (3)" Margin="0,0,8,0"
                    AutomationProperties.Name="选择：DSH 完全托管 24 小时"/>
            <Button x:Name="BtnSession" Style="{StaticResource DlgBtn}" Background="@@ACCENT@@"
                    BorderBrush="@@ACCENT@@" BorderThickness="1" Foreground="@@ONACCENT@@"
                    FontWeight="SemiBold" Content="开始托管 (2)"
                    AutomationProperties.Name="选择：DSH 完全托管 本会话"/>
          </StackPanel>
        </Grid>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

# 把 token 注入 XAML（不靠字符串插值，避免 PowerShell 解析 $ 与 {} 的坑）
$map = @{
  '@@BG@@' = $T.bg; '@@SURFACE@@' = $T.surface; '@@SURFACEALT@@' = $T.surfaceAlt
  '@@BORDER@@' = $T.border; '@@BORDERSOFT@@' = $T.borderSoft; '@@DIVIDER@@' = $T.divider
  '@@TEXT@@' = $T.text; '@@TEXT2@@' = $T.text2; '@@TEXT3@@' = $T.text3
  '@@ACCENT@@' = $T.accent; '@@ONACCENT@@' = $T.onAccent
  '@@GHOSTBORDER@@' = $T.ghostBorder; '@@GHOSTTEXT@@' = $T.ghostText
  '@@WARNBG@@' = '#FEF5E7'; '@@WARNBORDER@@' = '#F7AD31'; '@@WARNTX@@' = '#DD8629'
  '@@OFFBG@@' = $T.offBg; '@@OFFTX@@' = $T.offTx; '@@OFFDOT@@' = $T.offDot
  '@@TRACK@@' = $T.track
}
if ($useDark) { $map['@@WARNBG@@'] = '#27241F'; $map['@@WARNBORDER@@'] = '#F7AD31'; $map['@@WARNTX@@'] = '#F7AD31' }
foreach ($k in $map.Keys) { $xaml = $xaml.Replace($k, $map[$k]) }

$xamlDoc = New-Object System.Xml.XmlDocument
$xamlDoc.LoadXml($xaml)
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))

function Brush([string]$hex) {
  [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

$CountFill     = $win.FindName('CountFill')
$CountdownText = $win.FindName('CountdownText')
$LeftText      = $win.FindName('LeftText')

$win.FindName('CallsNum').Text   = $callsNum
$win.FindName('CallsUnit').Text  = $callsUnit
$win.FindName('ReasonText').Text = $reasonLine
$win.FindName('ToolText').Text   = $toolLine
$win.FindName('SubText').Text    = $sessShort + ' · 请先别动鼠标'

$win.FindName('PillText').Text          = $winStatus.text
$win.FindName('PillText').Foreground    = Brush $toneTx[$winStatus.tone]
$win.FindName('PillBorder').Background  = Brush $toneBg[$winStatus.tone]
$win.FindName('PillBorder').BorderBrush = Brush $toneBorder[$winStatus.tone]
$win.FindName('PillDot').Fill           = Brush $toneDot[$winStatus.tone]

$script:choice  = ''
$script:timeout = $false
$script:left    = $TimeoutSec

function Finish([string]$c) {
  $script:choice = $c
  try { $win.Close() } catch {}
}

$win.FindName('BtnUser').Add_Click({ Finish 'user' })
$win.FindName('BtnSession').Add_Click({ Finish 'session' })
$win.FindName('Btn24h').Add_Click({ Finish '24h' })

# 键盘：1 / 2 / 3 直接选，Esc = 不选择（交给超时策略）
$win.Add_KeyDown({
  switch ($_.Key) {
    'D1'      { Finish 'user' }
    'NumPad1' { Finish 'user' }
    'D2'      { Finish 'session' }
    'NumPad2' { Finish 'session' }
    'D3'      { Finish '24h' }
    'NumPad3' { Finish '24h' }
    'Escape'  { try { $win.Close() } catch {} }
  }
})

# 倒计时：每秒刷新文字 + 进度条；颜色随剩余时间从 accent 烧到红；归零 = 自动按「本会话托管」放行
function Update-Countdown {
  $ratio = [Math]::Max(0, [Math]::Min(1, $script:left / [double]$TimeoutSec))
  $trackW = $CountFill.Parent.ActualWidth
  if ($trackW -le 0) { $trackW = 400 }
  $CountFill.Width = [Math]::Round($trackW * $ratio)
  $CountFill.Background = if ($ratio -gt 0.5) { Brush $T.accent }
                          elseif ($ratio -gt 0.25) { Brush '#F59E0B' }
                          else { Brush '#EF4444' }
  $LeftText.Text = if ($script:timeout) { '已超时' } else { ('{0}s' -f $script:left) }
  $CountdownText.Text = if ($script:timeout) { '已超时 → 正在按「完全托管 · 本会话」放行' }
                        else { '无人应答将自动按「完全托管 · 本会话」放行' }
  $win.FindName('StatusChipText').Text = if ($script:timeout) { '已超时 · 自动放行' } else { '等待你决定' }
  if ($script:timeout) {
    $win.FindName('StatusChip').Background  = Brush $T.badBg
    $win.FindName('StatusChip').BorderBrush = Brush $T.badDot
    $win.FindName('StatusChipText').Foreground = Brush $T.badTx
  }
}

# ---------- 预览：离屏渲染，不弹窗、不抢前台 ----------
if ($PreviewPath) {
  $card = $win.Content
  $win.Content = $null
  $stage = New-Object Windows.Controls.Grid
  $stage.Background = Brush $T.stage
  [void]$stage.Children.Add($card)
  $stage.Width = 568
  $stage.Measure([Windows.Size]::new(568, [double]::PositiveInfinity))
  $h = [Math]::Ceiling($stage.DesiredSize.Height)
  $stage.Height = $h
  $stage.Arrange([Windows.Rect]::new(0, 0, 568, $h))
  $stage.UpdateLayout()
  Update-Countdown
  $stage.UpdateLayout()
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(568, [int]$h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($stage)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [IO.File]::Create($PreviewPath)
  $enc.Save($fs)
  $fs.Close()
  Log ('[preview] ' + $PreviewPath)
  exit 0
}

# 抢焦点 + 响一声：用户要求「像请求权限那样突然弹出来」，所以必须主动前台化。
$win.Add_Loaded({
  try { $win.Activate() } catch {}
  try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
  try { Update-Countdown } catch {}
  $timer.Start()
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
  $script:left--
  if ($script:left -le 0) {
    $script:timeout = $true
    $timer.Stop()
    Update-Countdown
    Finish 'session'
    return
  }
  Update-Countdown
})

Log ('弹窗：预计 ' + $Calls + ' 次 · 工具=' + $ToolName + ' · 超时 ' + $TimeoutSec + 's')
try { [void]$win.ShowDialog() } catch { Log ('弹窗异常: ' + $_.Exception.Message) }
$timer.Stop()

if (-not $script:choice) { $script:timeout = $true; $script:choice = 'session' }

$res = [pscustomobject]@{
  choice = $script:choice; timeout = $script:timeout; at = (Get-Date).ToString('o')
  calls = $Calls; tool = $ToolName; reason = $Reason; session = $Session; pid = $PID
}
Write-JsonAtomic $OutFile $res
Log ('用户选择：' + $choiceLabels[$script:choice] + $(if ($script:timeout) { '（超时自动）' } else { '' }))
exit 0

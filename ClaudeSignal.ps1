# Claude Signal: Windows-Overlay (Signal-Punkt) für Claude-Code-Sessions in WSL.
# Läuft unter Windows PowerShell 5.1 (STA ist dort Standard), keine Installation nötig.
# Statusdateien: %LOCALAPPDATA%\ClaudeSignal\sessions\*.status  (schreibt report-status.sh aus WSL)

# --- Einzelinstanz ---
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeSignalSingleton')
if (-not $script:mutex.WaitOne(0)) { exit 0 }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    Add-Type -Namespace ClaudeSignal -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@

    $baseDir     = Join-Path $env:LOCALAPPDATA 'ClaudeSignal'
    $sessionsDir = Join-Path $baseDir 'sessions'
    $configPath  = Join-Path $baseDir 'config.json'
    New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

    # Logik neben dem Skript laden (funktioniert deployt UND direkt aus dem Repo/UNC)
    . (Join-Path $PSScriptRoot 'Signal.Logic.ps1')

    # Punktfarben folgen dem Nutzer-Farbschema der Tastatur (nicht dem klassischen Rot-Gelb-Gruen):
    # gray=keine Session (dunkelblau), red=arbeitet (hellblau), yellow=wartet (rot), green=fertig,
    # yellowbusy=wartet+Hintergrund arbeitet noch (rot, gleiche Farbe wie yellow)
    $colorMap = @{ gray = '#1050E0'; green = '#43A047'; red = '#2878FF'; yellow = '#E53935'; yellowbusy = '#E53935' }

    # Tastatur-Backend: Farbwechsel -> SignalRGB-Effekt (Spec-Erweiterung Tastatur-Backend)
    $sigMap = @{ gray = 'Claude Blau'; green = 'Claude Gruen'; red = 'Claude Blau Puls'; yellow = 'Claude Rot Puls'; yellowbusy = 'Claude Rot Lauf' }
    $script:sigHideTimer = $null
    function Invoke-SignalKeyboard([string]$color) {
        try {
            if (-not $sigMap.ContainsKey($color)) { return }
            $sig = Get-Process -Name SignalRgb -ErrorAction SilentlyContinue
            if (-not $sig) { return }
            $hadWindow = ($sig.MainWindowHandle -ne [IntPtr]::Zero)
            Start-Process ('signalrgb://effect/apply/' + [uri]::EscapeDataString($sigMap[$color]))
            if (-not $hadWindow) {
                # Deep-Link kann das SignalRGB-Fenster ungefragt hochholen — dann gleich wieder verstecken
                if ($script:sigHideTimer) { $script:sigHideTimer.Stop() }
                $script:sigHideTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:sigHideTimer.Interval = [TimeSpan]::FromMilliseconds(600)
                $script:sigHideTimer.Add_Tick({
                    try {
                        $script:sigHideTimer.Stop()
                        $p = Get-Process -Name SignalRgb -ErrorAction SilentlyContinue
                        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
                            [ClaudeSignal.Win32]::ShowWindowAsync($p.MainWindowHandle, 0) | Out-Null  # SW_HIDE
                        }
                    } catch { }
                })
                $script:sigHideTimer.Start()
            }
        } catch { }
    }

    function New-SignalBrush([string]$hex) {
        New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    }

    # --- Fenster ---
    $window = New-Object System.Windows.Window
    $window.WindowStyle        = 'None'
    $window.AllowsTransparency = $true
    $window.Background         = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost            = $true
    $window.ShowInTaskbar      = $false
    $window.ResizeMode         = 'NoResize'
    $window.Width  = 36
    $window.Height = 36

    $ellipse = New-Object System.Windows.Shapes.Ellipse
    $ellipse.Width  = 28
    $ellipse.Height = 28
    $ellipse.Stroke = New-SignalBrush '#55000000'
    $ellipse.StrokeThickness = 2
    $ellipse.Fill = New-SignalBrush $colorMap['gray']
    $window.Content = $ellipse

    function Set-DotPulse([string]$color) {
        # arbeitet (red/hellblau): sanft ~1,4 s Zyklus; wartet (yellow/rot): kräftig ~0,8 s; sonst statisch
        $anim = $null
        if ($color -eq 'red') {
            $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.4, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(700)))
        } elseif ($color -eq 'yellow' -or $color -eq 'yellowbusy') {
            $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.25, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(400)))
        }
        if ($anim) {
            $anim.AutoReverse = $true
            $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $ellipse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
        } else {
            $ellipse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $ellipse.Opacity = 1.0
        }
    }

    # --- Position: laden, auf sichtbaren Bereich klemmen ---
    $work = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $work.Right - 60
    $window.Top  = $work.Top + 12
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($null -ne $cfg.Left -and $null -ne $cfg.Top) {
                $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
                $vt = [System.Windows.SystemParameters]::VirtualScreenTop
                $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
                $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
                $left = [double]$cfg.Left; $top = [double]$cfg.Top
                if ($left -ge $vl -and $left -le ($vl + $vw - 36) -and
                    $top  -ge $vt -and $top  -le ($vt + $vh - 36)) {
                    $window.Left = $left; $window.Top = $top
                }
            }
        } catch { }
    }

    # --- Interaktion ---
    $window.Add_MouseLeftButtonDown({
        try {
            $window.DragMove()  # blockiert bis zum Loslassen
            @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json |
                Set-Content -LiteralPath $configPath -Encoding Ascii
        } catch { }
    })
    $window.Add_MouseRightButtonUp({ $window.Close() })

    # --- Poll-Timer: 500 ms ---
    $script:lastColor = ''
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        try {
            $state = Get-SignalState -SessionsDir $sessionsDir
            if ($state.Color -ne $script:lastColor) {
                $script:lastColor = $state.Color
                $ellipse.Fill = New-SignalBrush $colorMap[$state.Color]
                Invoke-SignalKeyboard $state.Color
                Set-DotPulse $state.Color
            }
            if ($state.Color -eq 'gray') {
                if ($window.IsVisible) { $window.Hide() }   # kein Punkt ohne Session
            } elseif (-not $window.IsVisible) { $window.Show() }
            if ($ellipse.ToolTip -ne $state.Tooltip) { $ellipse.ToolTip = $state.Tooltip }
        } catch {
            # Lesefehler: wie 'keine Session' behandeln — nächster Tick heilt
            if ($script:lastColor -ne 'gray') {
                $script:lastColor = 'gray'
                $ellipse.Fill = New-SignalBrush $colorMap['gray']
                Invoke-SignalKeyboard 'gray'
                Set-DotPulse 'gray'
            }
            if ($window.IsVisible) { $window.Hide() }
            $ellipse.ToolTip = 'Claude Signal: Statusdateien nicht lesbar'
        }
    })
    $timer.Start()
    # Kein initiales Show: der erste Tick blendet den Punkt nur ein, wenn eine Session existiert.
    $window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
    [System.Windows.Threading.Dispatcher]::Run()
    $timer.Stop()
    Invoke-SignalKeyboard 'gray'   # Tastatur beim Beenden auf Ruhezustand zurück
}
finally {
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
}

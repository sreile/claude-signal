# Claude Signal: Windows-Overlay (Signal-Punkt) für Claude-Code-Sessions in WSL.
# Läuft unter Windows PowerShell 5.1 (STA ist dort Standard), keine Installation nötig.
# Statusdateien: %LOCALAPPDATA%\ClaudeSignal\sessions\*.status  (schreibt report-status.sh aus WSL)

# --- Einzelinstanz ---
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeSignalSingleton')
if (-not $script:mutex.WaitOne(0)) { exit 0 }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $baseDir     = Join-Path $env:LOCALAPPDATA 'ClaudeSignal'
    $sessionsDir = Join-Path $baseDir 'sessions'
    $configPath  = Join-Path $baseDir 'config.json'
    $statePath   = Join-Path $baseDir 'state.txt'
    $orgbExe = Join-Path $baseDir 'tools\OpenRGB\OpenRGB Windows 64-bit\OpenRGB.exe'
    $animExe = Join-Path $baseDir 'SignalAnimator.exe'
    # Der Bildschirmpunkt ist standardmäßig AUS (die RGB-Geräte sind die Anzeige);
    # ShowDot=true in config.json blendet ihn ein. Wird nur beim Start gelesen.
    $script:showDot = $false
    New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

    # Logik neben dem Skript laden (funktioniert deployt UND direkt aus dem Repo/UNC)
    . (Join-Path $PSScriptRoot 'Signal.Logic.ps1')

    # Punktfarben folgen dem Nutzer-Farbschema der Tastatur (nicht dem klassischen Rot-Gelb-Gruen):
    # gray=keine Session (dunkelblau), red=arbeitet (hellblau), yellow=wartet (rot), green=fertig,
    # yellowbusy=wartet+Hintergrund arbeitet noch (rot, gleiche Farbe wie yellow),
    # limited=Session-/Nutzungslimit-Wartezeit (gelb, v6.2)
    $colorMap = @{ gray = '#1050E0'; green = '#43A047'; red = '#2878FF'; yellow = '#E53935'; yellowbusy = '#E53935'; limited = '#FFC800' }

    # RGB-Backend: SignalAnimator.exe (C#, SDK-Streaming über OpenRGB Port 6742)
    # rendert die Effekte selbst — das Overlay schreibt dafür nur den
    # aggregierten Zustand in state.txt (siehe Update 10 im Spec-Dokument).
    function Write-SignalState([string]$color) {
        try {
            # Atomar schreiben (tmp + Rename): der Animator liest laufend mit —
            # ein direktes Set-Content könnte er mitten im Schreiben erwischen.
            $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $tmp = $statePath + '.tmp'
            Set-Content -LiteralPath $tmp -Value ($color + ' ' + $ms) -Encoding Ascii
            Move-Item -LiteralPath $tmp -Destination $statePath -Force
        } catch { }
    }

    function New-SignalBrush([string]$hex) {
        New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    }

    # v6: Farbwert aus config.json validieren/normalisieren — akzeptiert
    # "#RRGGBB" und "RRGGBB", liefert $null bei ungültigem Wert (Aufrufer
    # behält dann den bisherigen $colorMap-Standard).
    function ConvertTo-SignalHex([string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        $t = $value.Trim().TrimStart('#')
        if ($t -notmatch '^[0-9A-Fa-f]{6}$') { return $null }
        return '#' + $t
    }

    # Server + Animator sicherstellen — läuft im Tick (siehe unten), nicht nur
    # einmal beim Start, damit beide auch neu starten, wenn sie über Nacht
    # sterben (SignalAnimator.exe beendet sich zudem bewusst nach 10 Minuten
    # durchgehendem Leerlauf, siehe Update 11 — das hier holt ihn zurück).
    function Assure-RgbBackend {
        try {
            if ((Test-Path -LiteralPath $orgbExe) -and -not (Get-Process -Name OpenRGB -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $orgbExe -ArgumentList @('--server','--startminimized') -WindowStyle Hidden
            }
        } catch { }
        try {
            if ((Test-Path -LiteralPath $animExe) -and -not (Get-Process -Name SignalAnimator -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $animExe -WindowStyle Hidden
            }
        } catch { }
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
            if ($cfg.ShowDot -eq $true) {
                $script:showDot = $true
            }
            # v6: Punktfarben folgen config.json (States-Block), sofern gültig —
            # nur beim Start gelesen (Animator liest denselben Block laufend neu,
            # der Punkt erst nach einem Neustart des Overlays). Ungültige/
            # fehlende Einträge lassen den jeweiligen $colorMap-Standard stehen.
            if ($cfg.States) {
                $stateKeyMap = @{ working = 'red'; waiting = 'yellow'; waitingbusy = 'yellowbusy'; done = 'green'; idle = 'gray'; limited = 'limited' }
                foreach ($configKey in $stateKeyMap.Keys) {
                    $entry = $cfg.States.$configKey
                    if ($null -eq $entry) { continue }
                    $hex = $null
                    if ($entry.effect -eq 'solid' -and $entry.color) {
                        $hex = ConvertTo-SignalHex $entry.color
                    } elseif ($entry.to) {
                        $hex = ConvertTo-SignalHex $entry.to
                    }
                    if ($hex) { $colorMap[$stateKeyMap[$configKey]] = $hex }
                }
            }
        } catch { }
    }

    # --- Interaktion ---
    $window.Add_MouseLeftButtonDown({
        try {
            $window.DragMove()  # blockiert bis zum Loslassen
            # Merge statt Überschreiben: bestehende Config-Schlüssel (States, ShowDot,
            # AllRgbDevices, ...) müssen den Positions-Save überleben
            $saveCfg = @{}
            try {
                if (Test-Path -LiteralPath $configPath) {
                    (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).PSObject.Properties |
                        ForEach-Object { $saveCfg[$_.Name] = $_.Value }
                }
            } catch { }
            $saveCfg['Left'] = $window.Left
            $saveCfg['Top']  = $window.Top
            $saveCfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding Ascii
        } catch { }
    })
    $window.Add_MouseRightButtonUp({ $window.Close() })

    # --- Poll-Timer: 500 ms ---
    $script:lastColor = ''
    $script:tickCounter = 0
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        try {
            $script:tickCounter++
            # Erster Tick sofort, danach alle 20 Ticks (~10 s) — hält Server/Animator am Leben.
            if ($script:tickCounter -eq 1 -or ($script:tickCounter % 20) -eq 0) { Assure-RgbBackend }
            $state = Get-SignalState -SessionsDir $sessionsDir
            if ($state.Color -ne $script:lastColor) {
                $script:lastColor = $state.Color
                $ellipse.Fill = New-SignalBrush $colorMap[$state.Color]
                Set-DotPulse $state.Color
            }
            Write-SignalState $state.Color   # jeden Tick schreiben — gibt dem Animator einen Herzschlag
            if ($state.Color -eq 'gray') {
                if ($window.IsVisible) { $window.Hide() }   # kein Punkt ohne Session
            } elseif (-not $window.IsVisible -and $script:showDot) { $window.Show() }
            if ($ellipse.ToolTip -ne $state.Tooltip) { $ellipse.ToolTip = $state.Tooltip }
        } catch {
            # Lesefehler: wie 'keine Session' behandeln — nächster Tick heilt
            if ($script:lastColor -ne 'gray') {
                $script:lastColor = 'gray'
                $ellipse.Fill = New-SignalBrush $colorMap['gray']
                Set-DotPulse 'gray'
            }
            Write-SignalState 'gray'
            if ($window.IsVisible) { $window.Hide() }
            $ellipse.ToolTip = 'Claude Signal: Statusdateien nicht lesbar'
        }
    })

    $timer.Start()
    # Kein initiales Show: der erste Tick blendet den Punkt nur ein, wenn eine Session existiert.
    $window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
    [System.Windows.Threading.Dispatcher]::Run()
    $timer.Stop()
    Write-SignalState 'gray'   # Animator beim Beenden auf Ruhezustand zurück
}
finally {
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
}

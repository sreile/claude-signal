# Claude-Ampel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Windows-Overlay (farbiger Ampel-Punkt), das den aggregierten Status aller Claude-Code-Sessions in WSL2 anzeigt (🟡 wartet auf Nutzer > 🔴 arbeitet > 🟢 fertig > ⚪ keine Session).

**Architecture:** Claude-Code-Hooks (WSL) rufen `report-status.sh` auf, das pro Session eine Statusdatei nach `%LOCALAPPDATA%\ClaudeAmpel\sessions\` schreibt. Ein PowerShell/WPF-Overlay pollt den Ordner alle 500 ms, aggregiert und färbt den Punkt. Spec: `docs/specs/2026-09-01-claude-ampel-design.md`.

**Tech Stack:** Bash (Hook-Skript), Windows PowerShell 5.1 + WPF (Overlay), python3 (settings.json-Merge). Keine Installationen nötig.

**Umgebungsfakten (verifiziert am 2026-09-01):**
- Windows-Benutzer: `<WindowsUser>` → Zielordner `/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel` (**Leerzeichen im Pfad — überall quoten!**)
- WSL-Distro: `Ubuntu-22.04` → UNC-Pfad für Tests: `\\wsl.localhost\Ubuntu-22.04\home\sreile\.claude\ampel\...`
- `jq` ist NICHT installiert; `python3` ist da. Session-ID-Extraktion daher per `sed`.
- PowerShell: `/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe` (5.1), funktioniert aus WSL. Vor Aufruf `cd /mnt/c`, sonst UNC-cwd-Warnungen.
- Repo/Arbeitsverzeichnis: `~/.claude/ampel` (eigenes git-Repo, Spec bereits committet).
- `~/.claude/settings.json` hat noch KEINEN `hooks`-Block; bestehende Keys (permissions, statusLine, enabledPlugins, autoMode, …) dürfen nicht verloren gehen.

---

### Task 1: Hook-Skript `report-status.sh` mit Tests

**Goal:** Bash-Skript, das von Claude-Code-Hooks aufgerufen wird und Statusdateien schreibt/löscht — fehlertolerant, blockiert nie.

**Files:**
- Create: `~/.claude/ampel/report-status.sh`
- Test: `~/.claude/ampel/tests/test-report-status.sh`

**Acceptance Criteria:**
- [ ] `working|waiting|done` schreibt `<status> <unix-ts>` nach `$AMPEL_DIR/sessions/<session_id>.status`
- [ ] `start` schreibt `done`-Status; Overlay-Spawn wird bei `AMPEL_NO_SPAWN=1` übersprungen
- [ ] `end` löscht die Statusdatei
- [ ] Session-ID wird per `sed` aus stdin-JSON gezogen und auf `[A-Za-z0-9_-]` gefiltert
- [ ] Exit-Code ist IMMER 0 (auch bei Müll auf stdin, fehlender session_id, fehlendem Zielordner)
- [ ] Fehlt das Elternverzeichnis des Ziels (z.B. `/mnt/c` nicht gemountet), passiert nichts

**Verify:** `bash ~/.claude/ampel/tests/test-report-status.sh` → alle Zeilen `ok - ...`, Ausgabe endet mit `ALLE TESTS OK`, Exit 0

**Steps:**

- [ ] **Step 1: Failing Test schreiben**

`~/.claude/ampel/tests/test-report-status.sh`:

```bash
#!/usr/bin/env bash
# Tests für report-status.sh — nutzt AMPEL_DIR-Override, braucht kein /mnt/c.
set -u
SCRIPT="$HOME/.claude/ampel/report-status.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # name erwartet bekommen
  if [ "$2" = "$3" ]; then echo "ok - $1"
  else echo "FAIL - $1: erwartet '$2', bekommen '$3'"; fails=$((fails+1)); fi
}

run() { # status json — ruft das Skript wie ein Hook auf
  printf '%s' "$2" | AMPEL_DIR="$TMP" AMPEL_NO_SPAWN=1 bash "$SCRIPT" "$1"
}

JSON='{"session_id":"abc-123","hook_event_name":"Stop","cwd":"/home/x"}'

# 1) working schreibt Statusdatei mit aktuellem Zeitstempel
run working "$JSON"
check "working: Exit 0" "0" "$?"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "working: Status" "working" "${line%% *}"
ts="${line##* }"; now=$(date +%s)
if [ "$ts" -ge $((now - 5)) ] 2>/dev/null && [ "$ts" -le "$now" ]; then
  echo "ok - working: Zeitstempel aktuell"
else
  echo "FAIL - working: Zeitstempel '$ts' nicht aktuell"; fails=$((fails+1))
fi

# 2) waiting überschreibt
run waiting "$JSON"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "waiting: Status" "waiting" "${line%% *}"

# 3) start schreibt done (Spawn per AMPEL_NO_SPAWN unterdrückt)
run start "$JSON"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "start: Status done" "done" "${line%% *}"

# 4) end löscht die Datei
run end "$JSON"
[ -e "$TMP/sessions/abc-123.status" ] && { echo "FAIL - end: Datei existiert noch"; fails=$((fails+1)); } || echo "ok - end: Datei gelöscht"

# 5) Session-ID wird bereinigt (Pfad-Injection unmöglich)
run working '{"session_id":"../evil/../x"}'
[ -e "$TMP/sessions/evilx.status" ] && echo "ok - Session-ID bereinigt" || { echo "FAIL - Session-ID-Bereinigung"; fails=$((fails+1)); }
[ -e "$TMP/evil" ] && { echo "FAIL - Pfad-Injection möglich!"; fails=$((fails+1)); } || echo "ok - keine Pfad-Injection"

# 6) Müll auf stdin → Exit 0, keine Datei
printf 'kein json' | AMPEL_DIR="$TMP" AMPEL_NO_SPAWN=1 bash "$SCRIPT" working
check "Müll-stdin: Exit 0" "0" "$?"

# 7) fehlende session_id → Exit 0, keine neue Datei
before=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
printf '{"foo":"bar"}' | AMPEL_DIR="$TMP" AMPEL_NO_SPAWN=1 bash "$SCRIPT" working
check "ohne session_id: Exit 0" "0" "$?"
after=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
check "ohne session_id: keine Datei" "$before" "$after"

# 8) Zielordner-Elternteil fehlt (simuliert fehlendes /mnt/c) → Exit 0, nichts angelegt
printf '%s' "$JSON" | AMPEL_DIR="/nonexistent-$$/ampel" AMPEL_NO_SPAWN=1 bash "$SCRIPT" working
check "fehlendes Ziel: Exit 0" "0" "$?"
[ -d "/nonexistent-$$" ] && { echo "FAIL - hat /nonexistent-$$ angelegt"; fails=$((fails+1)); } || echo "ok - fehlendes Ziel: nichts angelegt"

# 9) unbekannter Status → Exit 0, keine Datei
printf '%s' "$JSON" | AMPEL_DIR="$TMP" AMPEL_NO_SPAWN=1 bash "$SCRIPT" quatsch
check "unbekannter Status: Exit 0" "0" "$?"
[ -e "$TMP/sessions/abc-123.status" ] && { echo "FAIL - unbekannter Status schrieb Datei"; fails=$((fails+1)); } || echo "ok - unbekannter Status: keine Datei"

if [ "$fails" -eq 0 ]; then echo "ALLE TESTS OK"; exit 0
else echo "$fails TEST(S) FEHLGESCHLAGEN"; exit 1; fi
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `bash ~/.claude/ampel/tests/test-report-status.sh`
Expected: FAIL-Zeilen (Skript existiert nicht), Exit 1

- [ ] **Step 3: Implementierung schreiben**

`~/.claude/ampel/report-status.sh`:

```bash
#!/usr/bin/env bash
# Claude-Ampel: schreibt den Session-Status für das Windows-Overlay.
# Aufruf durch Claude-Code-Hooks: report-status.sh <start|end|working|waiting|done>
# Hook-JSON kommt auf stdin. Darf NIEMALS fehlschlagen oder blockieren.

main() {
  local status="${1:-}"
  local win_dir="${AMPEL_DIR:-/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel}"
  local sessions_dir="$win_dir/sessions"
  local ps_exe="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe"
  local overlay_win='C:\Users\<WindowsUser>\AppData\Local\ClaudeAmpel\ClaudeAmpel.ps1'

  # Ohne Windows-Mount (oder falschem Override-Pfad) still aussteigen,
  # sonst würde mkdir -p Verzeichnisse im WSL-Rootfs anlegen.
  [ -d "$(dirname "$win_dir")" ] || return 0

  local input session_id
  input=$(cat) || return 0
  session_id=$(printf '%s' "$input" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
  [ -n "$session_id" ] || return 0

  case "$status" in
    start)
      mkdir -p "$sessions_dir" || return 0
      printf 'done %s\n' "$(date +%s)" > "$sessions_dir/$session_id.status"
      if [ -z "${AMPEL_NO_SPAWN:-}" ] && [ -x "$ps_exe" ]; then
        # Overlay detached starten; beendet sich selbst, wenn schon eine Instanz läuft.
        ( cd /mnt/c && nohup /mnt/c/WINDOWS/System32/cmd.exe /c start "" \
            powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
            -File "$overlay_win" ) >/dev/null 2>&1 &
      fi
      ;;
    end)
      rm -f "$sessions_dir/$session_id.status"
      ;;
    working|waiting|done)
      mkdir -p "$sessions_dir" || return 0
      printf '%s %s\n' "$status" "$(date +%s)" > "$sessions_dir/$session_id.status"
      ;;
  esac
  return 0
}

main "$@" >/dev/null 2>&1 || true
exit 0
```

Danach: `chmod +x ~/.claude/ampel/report-status.sh`

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: `bash ~/.claude/ampel/tests/test-report-status.sh`
Expected: alle `ok - ...`, `ALLE TESTS OK`, Exit 0

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/ampel && git add report-status.sh tests/test-report-status.sh && git commit -m "feat: Hook-Skript report-status.sh mit Tests"
```

---

### Task 2: Aggregationslogik `Ampel.Logic.ps1` mit Tests

**Goal:** Testbare PowerShell-Funktion `Get-AmpelState`, die Statusdateien liest, Stale-Sessions aussortiert und Farbe + Tooltip liefert.

**Files:**
- Create: `~/.claude/ampel/Ampel.Logic.ps1`
- Test: `~/.claude/ampel/tests/Test-AmpelLogic.ps1`

**Acceptance Criteria:**
- [ ] Priorität: waiting→yellow > working→red > done→green > leer→gray
- [ ] `working`-Dateien älter als 3600 s werden ignoriert (abgestürzte Session)
- [ ] Dateien älter als 86400 s werden gelöscht
- [ ] Kaputte/leere Dateien werden übersprungen, kein Fehler
- [ ] Tooltip nennt Anzahl je Kategorie, z.B. `2 Session(s): 1 arbeitet, 0 wartet, 1 fertig`

**Verify:** `cd /mnt/c && /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File '\\wsl.localhost\Ubuntu-22.04\home\sreile\.claude\ampel\tests\Test-AmpelLogic.ps1'` → alle `ok - ...`, `ALLE TESTS OK`, Exit 0

**Steps:**

- [ ] **Step 1: Failing Test schreiben**

`~/.claude/ampel/tests/Test-AmpelLogic.ps1`:

```powershell
# Tests für Get-AmpelState. Läuft unter Windows PowerShell 5.1,
# aufrufbar aus WSL über den UNC-Pfad (\\wsl.localhost\...).
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Ampel.Logic.ps1')

$script:fails = 0
function Check($name, $expected, $actual) {
    if ("$expected" -eq "$actual") { Write-Output "ok - $name" }
    else { Write-Output "FAIL - ${name}: erwartet '$expected', bekommen '$actual'"; $script:fails++ }
}

$tmp = Join-Path $env:TEMP ("AmpelTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$now = [long]1900000000  # fester "Jetzt"-Zeitpunkt für deterministische Tests

function Write-Status($id, $content) {
    Set-Content -LiteralPath (Join-Path $tmp "$id.status") -Value $content -Encoding Ascii
}
function Clear-Dir { Get-ChildItem -LiteralPath $tmp -File | Remove-Item -Force }

# 1) leerer Ordner -> gray
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'leer: gray' 'gray' $s.Color
Check 'leer: Tooltip' 'Claude-Ampel: keine Session' $s.Tooltip

# 2) nicht existierender Ordner -> gray, kein Fehler
$s = Get-AmpelState -SessionsDir (Join-Path $tmp 'gibtsnicht') -NowUnix $now
Check 'fehlender Ordner: gray' 'gray' $s.Color

# 3) eine done -> green
Write-Status 'a' "done $($now - 10)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'done: green' 'green' $s.Color

# 4) done + working -> red
Write-Status 'b' "working $($now - 10)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'done+working: red' 'red' $s.Color

# 5) done + working + waiting -> yellow (höchste Priorität)
Write-Status 'c' "waiting $($now - 10)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'mit waiting: yellow' 'yellow' $s.Color
Check 'Tooltip-Zählung' '3 Session(s): 1 arbeitet, 1 wartet, 1 fertig' $s.Tooltip

# 6) stale working (> 3600 s) wird ignoriert
Clear-Dir
Write-Status 'a' "working $($now - 4000)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'stale working: gray' 'gray' $s.Color

# 7) stale working neben done -> green (stale zählt nicht)
Write-Status 'b' "done $($now - 10)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'stale working + done: green' 'green' $s.Color

# 8) Datei älter als 24 h wird gelöscht
Clear-Dir
Write-Status 'alt' "done $($now - 90000)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check '24h-Datei: gray' 'gray' $s.Color
Check '24h-Datei: gelöscht' 'False' (Test-Path -LiteralPath (Join-Path $tmp 'alt.status'))

# 9) kaputte Dateien werden übersprungen
Clear-Dir
Write-Status 'kaputt1' 'nur-ein-wort'
Write-Status 'kaputt2' 'working keinezahl'
Write-Status 'leer' ''
Write-Status 'ok' "done $($now - 10)"
$s = Get-AmpelState -SessionsDir $tmp -NowUnix $now
Check 'kaputte Dateien: green' 'green' $s.Color

Remove-Item -LiteralPath $tmp -Recurse -Force
if ($script:fails -eq 0) { Write-Output 'ALLE TESTS OK'; exit 0 }
else { Write-Output "$($script:fails) TEST(S) FEHLGESCHLAGEN"; exit 1 }
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `cd /mnt/c && /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File '\\wsl.localhost\Ubuntu-22.04\home\sreile\.claude\ampel\tests\Test-AmpelLogic.ps1'`
Expected: Fehler (Ampel.Logic.ps1 nicht gefunden), Exit ≠ 0

- [ ] **Step 3: Implementierung schreiben**

`~/.claude/ampel/Ampel.Logic.ps1`:

```powershell
# Claude-Ampel: Aggregationslogik, getrennt vom UI, damit testbar.
# Statusdateiformat: "<status> <unix-timestamp>" (eine Zeile), Status in working|waiting|done.

function Get-AmpelState {
    param(
        [Parameter(Mandatory)][string]$SessionsDir,
        [long]$NowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )
    $counts = @{ waiting = 0; working = 0; done = 0 }
    if (Test-Path -LiteralPath $SessionsDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $SessionsDir -Filter '*.status' -File -ErrorAction SilentlyContinue)) {
            try { $line = Get-Content -LiteralPath $f.FullName -TotalCount 1 -ErrorAction Stop } catch { continue }
            if (-not $line) { continue }
            $parts = "$line".Trim() -split '\s+'
            if ($parts.Count -lt 2) { continue }
            $status = $parts[0]
            $ts = 0L
            if (-not [long]::TryParse($parts[1], [ref]$ts)) { continue }
            $age = $NowUnix - $ts
            if ($age -gt 86400) {
                # Leiche einer hart beendeten Session — aufräumen
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
            if ($status -eq 'working' -and $age -gt 3600) { continue }  # abgestürzt
            if ($counts.ContainsKey($status)) { $counts[$status]++ }
        }
    }
    $color = 'gray'
    if     ($counts['waiting'] -gt 0) { $color = 'yellow' }
    elseif ($counts['working'] -gt 0) { $color = 'red' }
    elseif ($counts['done']    -gt 0) { $color = 'green' }

    $total = $counts['waiting'] + $counts['working'] + $counts['done']
    $tooltip = if ($total -eq 0) { 'Claude-Ampel: keine Session' }
        else { "$total Session(s): $($counts['working']) arbeitet, $($counts['waiting']) wartet, $($counts['done']) fertig" }

    [pscustomobject]@{ Color = $color; Tooltip = $tooltip; Counts = $counts }
}
```

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: wie in Step 2.
Expected: alle `ok - ...`, `ALLE TESTS OK`, Exit 0

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/ampel && git add Ampel.Logic.ps1 tests/Test-AmpelLogic.ps1 && git commit -m "feat: Aggregationslogik Get-AmpelState mit Tests"
```

---

### Task 3: Overlay-UI `ClaudeAmpel.ps1`

**Goal:** Randloses Always-on-top-WPF-Fenster mit farbigem Punkt: pollt alle 500 ms, verschiebbar mit Positionsspeicherung, Tooltip, Rechtsklick beendet, Einzelinstanz per Mutex.

**Files:**
- Create: `~/.claude/ampel/ClaudeAmpel.ps1`

**Acceptance Criteria:**
- [ ] Punkt erscheint oben rechts, immer im Vordergrund, ohne Taskleisten-Eintrag und ohne Konsolenfenster
- [ ] Farbe folgt den Statusdateien binnen ~1 s (gray/green/red/yellow)
- [ ] Tooltip zeigt die Session-Zusammenfassung
- [ ] Ziehen mit der Maus verschiebt; Position überlebt Neustart (config.json)
- [ ] Rechtsklick beendet das Overlay
- [ ] Zweiter Start beendet sich sofort still (Mutex)

**Verify:** manueller Smoke-Test (Steps 2–4) — Overlay aus dem Repo via UNC-Pfad starten, Statusdateien aus WSL manipulieren, Farbwechsel beobachten (Nutzer bestätigt).

**Steps:**

- [ ] **Step 1: Implementierung schreiben**

`~/.claude/ampel/ClaudeAmpel.ps1`:

```powershell
# Claude-Ampel: Windows-Overlay (Ampel-Punkt) für Claude-Code-Sessions in WSL.
# Läuft unter Windows PowerShell 5.1 (STA ist dort Standard), keine Installation nötig.
# Statusdateien: %LOCALAPPDATA%\ClaudeAmpel\sessions\*.status  (schreibt report-status.sh aus WSL)

# --- Einzelinstanz ---
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeAmpelSingleton')
if (-not $script:mutex.WaitOne(0)) { exit 0 }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $baseDir     = Join-Path $env:LOCALAPPDATA 'ClaudeAmpel'
    $sessionsDir = Join-Path $baseDir 'sessions'
    $configPath  = Join-Path $baseDir 'config.json'
    New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

    # Logik neben dem Skript laden (funktioniert deployt UND direkt aus dem Repo/UNC)
    . (Join-Path $PSScriptRoot 'Ampel.Logic.ps1')

    $colorMap = @{ gray = '#9E9E9E'; green = '#43A047'; red = '#E53935'; yellow = '#FDD835' }

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
    $ellipse.Stroke = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#55000000'))
    $ellipse.StrokeThickness = 2
    $ellipse.Fill = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($colorMap['gray']))
    $window.Content = $ellipse

    # --- Position: laden, auf sichtbaren Bereich klemmen ---
    $work = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $work.Right - 60
    $window.Top  = $work.Top + 12
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
            $vt = [System.Windows.SystemParameters]::VirtualScreenTop
            $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
            $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
            $left = [double]$cfg.Left; $top = [double]$cfg.Top
            if ($left -ge $vl -and $left -le ($vl + $vw - 36) -and
                $top  -ge $vt -and $top  -le ($vt + $vh - 36)) {
                $window.Left = $left; $window.Top = $top
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
            $state = Get-AmpelState -SessionsDir $sessionsDir
            if ($state.Color -ne $script:lastColor) {
                $script:lastColor = $state.Color
                $ellipse.Fill = New-Object System.Windows.Media.SolidColorBrush(
                    [System.Windows.Media.ColorConverter]::ConvertFromString($colorMap[$state.Color]))
            }
            $ellipse.ToolTip = $state.Tooltip
        } catch { }
    })
    $timer.Start()

    $null = $window.ShowDialog()
    $timer.Stop()
}
finally {
    $script:mutex.ReleaseMutex() 2>$null
    $script:mutex.Dispose()
}
```

- [ ] **Step 2: Smoke-Test — Overlay direkt aus dem Repo starten**

Run (aus WSL):
```bash
cd /mnt/c && nohup /mnt/c/WINDOWS/System32/cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '\\wsl.localhost\Ubuntu-22.04\home\sreile\.claude\ampel\ClaudeAmpel.ps1' >/dev/null 2>&1 &
```
Expected: grauer Punkt erscheint oben rechts (Sessions-Ordner ist leer). **Nutzer bestätigt Sichtbarkeit.**

- [ ] **Step 3: Farbwechsel durchspielen**

Run (aus WSL, mit Pausen zum Hinschauen):
```bash
S='/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel/sessions'
printf 'done %s\n' "$(date +%s)"    > "$S/test1.status"; sleep 3   # -> grün
printf 'working %s\n' "$(date +%s)" > "$S/test2.status"; sleep 3   # -> rot
printf 'waiting %s\n' "$(date +%s)" > "$S/test1.status"; sleep 3   # -> gelb (Priorität)
rm "$S/test1.status" "$S/test2.status"                             # -> grau
```
Expected: Punkt wechselt grün → rot → gelb → grau; Tooltip zeigt jeweils die Zählung. **Nutzer bestätigt.**

- [ ] **Step 4: Verschieben, Doppelstart, Beenden prüfen**

1. Punkt mit Maus verschieben → per Rechtsklick beenden → erneut starten (Befehl aus Step 2) → Punkt erscheint an der gemerkten Position.
2. Bei laufendem Overlay den Startbefehl nochmal ausführen → es erscheint KEIN zweiter Punkt.
3. Rechtsklick → Punkt verschwindet.
Expected: alles wie beschrieben. **Nutzer bestätigt.**

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/ampel && git add ClaudeAmpel.ps1 && git commit -m "feat: WPF-Overlay ClaudeAmpel.ps1"
```

---

### Task 4: Installation — Deploy + Hook-Registrierung

**Goal:** `install.sh` kopiert die PS-Dateien nach `%LOCALAPPDATA%\ClaudeAmpel` und trägt die 6 Hooks idempotent in `~/.claude/settings.json` ein (mit Backup).

**Files:**
- Create: `~/.claude/ampel/install.sh`
- Modify: `~/.claude/settings.json` (nur `hooks`-Block ergänzen, Rest unangetastet)

**Acceptance Criteria:**
- [ ] `ClaudeAmpel.ps1` + `Ampel.Logic.ps1` liegen in `/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel/`
- [ ] `settings.json` enthält alle 6 Hook-Events mit den richtigen Kommandos; `PreToolUse` mit `"matcher": "*"`
- [ ] Bestehende settings.json-Keys unverändert; Backup `settings.json.bak.<timestamp>` existiert
- [ ] Zweiter `install.sh`-Lauf erzeugt KEINE doppelten Hook-Einträge

**Verify:** `bash ~/.claude/ampel/install.sh && bash ~/.claude/ampel/install.sh && python3 -c "import json,os;s=json.load(open(os.path.expanduser('~/.claude/settings.json')));h=s['hooks'];assert sorted(h)==sorted(['SessionStart','UserPromptSubmit','PreToolUse','Notification','Stop','SessionEnd']),h.keys();assert all(len(h[e])==1 for e in h),'Duplikate!';assert s['permissions']['defaultMode']=='auto';print('OK')"` → `OK`

**Steps:**

- [ ] **Step 1: install.sh schreiben**

`~/.claude/ampel/install.sh`:

```bash
#!/usr/bin/env bash
# Claude-Ampel installieren: PS-Dateien nach Windows kopieren, Hooks registrieren.
set -euo pipefail

SRC="$HOME/.claude/ampel"
WIN_DIR="/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel"

[ -d "$(dirname "$WIN_DIR")" ] || { echo "FEHLER: $WIN_DIR nicht erreichbar (WSL-Mount?)"; exit 1; }

mkdir -p "$WIN_DIR/sessions"
cp "$SRC/ClaudeAmpel.ps1" "$SRC/Ampel.Logic.ps1" "$WIN_DIR/"
echo "Dateien kopiert nach: $WIN_DIR"

python3 - <<'PY'
import json, os, time

path = os.path.expanduser('~/.claude/settings.json')
with open(path) as f:
    settings = json.load(f)

backup = f"{path}.bak.{time.strftime('%Y%m%d%H%M%S')}"
with open(backup, 'w') as f:
    json.dump(settings, f, indent=2)

script = os.path.expanduser('~/.claude/ampel/report-status.sh')
events = {
    'SessionStart': 'start',
    'UserPromptSubmit': 'working',
    'PreToolUse': 'working',
    'Notification': 'waiting',
    'Stop': 'done',
    'SessionEnd': 'end',
}
hooks = settings.setdefault('hooks', {})
added = 0
for event, arg in events.items():
    command = f'bash "{script}" {arg}'
    entries = hooks.setdefault(event, [])
    exists = any(h.get('command') == command
                 for e in entries for h in e.get('hooks', []))
    if not exists:
        entry = {'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}
        if event == 'PreToolUse':
            entry['matcher'] = '*'
        entries.append(entry)
        added += 1

with open(path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
print(f'Hooks: {added} neu eingetragen, Backup: {backup}')
PY

echo "Fertig. Hooks gelten für NEUE Claude-Sessions (laufende Sessions laden sie nicht nach)."
```

Danach: `chmod +x ~/.claude/ampel/install.sh`

- [ ] **Step 2: Installieren (zweimal, prüft Idempotenz) und verifizieren**

Run: der komplette **Verify**-Befehl oben.
Expected: `OK` — und `ls "/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel/"` zeigt beide .ps1-Dateien.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude/ampel && git add install.sh && git commit -m "feat: install.sh — Deploy und Hook-Registrierung"
```

---

### Task 5: Ende-zu-Ende-Test + README

**Goal:** Nachweis mit einer echten Claude-Session, dass die Hooks feuern und die Ampel korrekt schaltet; Dokumentation für Nutzung/Deinstallation.

**Files:**
- Create: `~/.claude/ampel/README.md`

**Acceptance Criteria:**
- [ ] Headless-Session (`claude -p`) erzeugt und entfernt ihre Statusdatei; Overlay läuft danach
- [ ] Interaktive Session: Ampel geht bei Prompt auf Rot, bei Fertigstellung auf Grün (Nutzer bestätigt)
- [ ] README erklärt Funktionsweise, Farben, Installation, Deinstallation, bekannte Grenzen

**Verify:** Headless-Check aus Step 1 zeigt die erwartete Dateiabfolge; Nutzer bestätigt den interaktiven Test.

**Steps:**

- [ ] **Step 1: Headless-E2E**

Run (aus WSL):
```bash
S='/mnt/c/Users/<WindowsUser>/AppData/Local/ClaudeAmpel/sessions'
ls "$S" > /tmp/ampel-before.txt
claude -p 'Antworte nur mit OK' --model haiku
sleep 2; ls "$S" > /tmp/ampel-after.txt
diff /tmp/ampel-before.txt /tmp/ampel-after.txt && echo "Statusdatei sauber entfernt"
```
Expected: Während des Laufs entsteht eine `<session-id>.status` (SessionStart-Hook), nach Ende ist sie weg (SessionEnd-Hook) → `diff` leer, Meldung `Statusdatei sauber entfernt`. Falls das Overlay noch nicht lief: es läuft jetzt (grauer Punkt).

- [ ] **Step 2: Interaktiver E2E (Nutzer)**

Nutzer öffnet ein neues Terminal, startet `claude`, und beobachtet: Start → Grün; Prompt senden → Rot; nach Antwort → Grün; ggf. Berechtigungsfrage → Gelb; `exit` → Grau. **Nutzer bestätigt.**

- [ ] **Step 3: README schreiben**

`~/.claude/ampel/README.md` — Inhalt: Was ist das (2 Sätze); Farbtabelle (gelb/rot/grün/grau mit Priorität); Architektur-Einzeiler (Hooks → Statusdateien → Overlay); Installation (`bash install.sh`); Bedienung (verschieben per Ziehen, Tooltip per Hover, Beenden per Rechtsklick, Autostart über SessionStart-Hook); Deinstallation (Hooks-Block aus `~/.claude/settings.json` entfernen bzw. Backup zurückspielen, Ordner `%LOCALAPPDATA%\ClaudeAmpel` löschen); bekannte Grenzen (aus Spec-Abschnitt "Bekannte Grenzen" übernehmen).

- [ ] **Step 4: Commit**

```bash
cd ~/.claude/ampel && git add README.md && git commit -m "docs: README für Claude-Ampel"
```

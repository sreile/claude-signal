# Tests für Get-SignalState. Läuft unter Windows PowerShell 5.1,
# aufrufbar aus WSL über den UNC-Pfad (\\wsl.localhost\...).
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Signal.Logic.ps1')

$script:fails = 0
function Check($name, $expected, $actual) {
    if ("$expected" -ceq "$actual") { Write-Output "ok - $name" }
    else { Write-Output "FAIL - ${name}: erwartet '$expected', bekommen '$actual'"; $script:fails++ }
}

$tmp = Join-Path $env:TEMP ("SignalTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$now = [long]1900000000  # fester "Jetzt"-Zeitpunkt für deterministische Tests

function Write-Status($id, $content) {
    Set-Content -LiteralPath (Join-Path $tmp "$id.status") -Value $content -Encoding Ascii
}
function Clear-Dir { Get-ChildItem -LiteralPath $tmp -File | Remove-Item -Force }

try {

# 1) leerer Ordner -> gray
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'leer: gray' 'gray' $s.Color
Check 'leer: Tooltip' 'Claude Signal: keine Session' $s.Tooltip

# 2) nicht existierender Ordner -> gray, kein Fehler
$s = Get-SignalState -SessionsDir (Join-Path $tmp 'gibtsnicht') -NowUnix $now
Check 'fehlender Ordner: gray' 'gray' $s.Color

# 3) eine done -> green
Write-Status 'a' "done $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'done: green' 'green' $s.Color

# 4) done + working -> red
Write-Status 'b' "working $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'done+working: red' 'red' $s.Color

# 5) done + working + waiting -> yellowbusy (wartet hat höchste Priorität,
#    aber "working" läuft nebenher -> eigener Zustand statt reinem yellow)
Write-Status 'c' "waiting $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'mit waiting: yellowbusy' 'yellowbusy' $s.Color
Check 'Tooltip-Zählung' '3 Session(s): 1 arbeitet, 1 wartet, 1 fertig' $s.Tooltip

# 6) stale working (> 3600 s) wird ignoriert
Clear-Dir
Write-Status 'a' "working $($now - 4000)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'stale working: gray' 'gray' $s.Color

# 7) stale working neben done -> green (stale zählt nicht)
Write-Status 'b' "done $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'stale working + done: green' 'green' $s.Color

# 8) Datei älter als 24 h wird gelöscht
Clear-Dir
Write-Status 'alt' "done $($now - 90000)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check '24h-Datei: gray' 'gray' $s.Color
Check '24h-Datei: gelöscht' 'False' (Test-Path -LiteralPath (Join-Path $tmp 'alt.status'))

# 9) kaputte Dateien werden übersprungen
Clear-Dir
Write-Status 'kaputt1' 'nur-ein-wort'
Write-Status 'kaputt2' 'working keinezahl'
Write-Status 'leer' ''
Write-Status 'ok' "done $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'kaputte Dateien: green' 'green' $s.Color
Check 'kaputte Dateien: nur 1 gezählt' '1 Session(s): 0 arbeitet, 0 wartet, 1 fertig' $s.Tooltip
Check 'kaputte Dateien: nicht gelöscht' '4' (Get-ChildItem -LiteralPath $tmp -File).Count

# 10) Grenzwerte: "älter als" ist strikt
Clear-Dir
Write-Status 'g1' "working $($now - 3600)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'working exakt 3600s: zählt (red)' 'red' $s.Color
Clear-Dir
Write-Status 'g2' "working $($now - 3601)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'working 3601s: ignoriert (gray)' 'gray' $s.Color
Clear-Dir
Write-Status 'g3' "done $($now - 86400)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'done exakt 86400s: bleibt (green)' 'green' $s.Color
Check 'done exakt 86400s: nicht gelöscht' 'True' (Test-Path -LiteralPath (Join-Path $tmp 'g3.status'))
Clear-Dir
Write-Status 'g4' "done $($now - 86401)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'done 86401s: gray' 'gray' $s.Color
Check 'done 86401s: gelöscht' 'False' (Test-Path -LiteralPath (Join-Path $tmp 'g4.status'))

# 11) Zukunfts-Zeitstempel (Uhren-Schieflage): ignorieren, aber NICHT löschen
Clear-Dir
Write-Status 'zukunft' "working $($now + 999999)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'Zukunft: gray' 'gray' $s.Color
Check 'Zukunft: nicht gelöscht' 'True' (Test-Path -LiteralPath (Join-Path $tmp 'zukunft.status'))

# 12) waitingbusy: allein -> yellowbusy; zählt als wartend im Tooltip
Clear-Dir
Write-Status 'a' "waitingbusy $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'waitingbusy allein: yellowbusy' 'yellowbusy' $s.Color
Check 'waitingbusy Tooltip' '1 Session(s): 0 arbeitet, 1 wartet, 0 fertig' $s.Tooltip

# 13) waiting + working (getrennte Sessions) -> yellowbusy
Clear-Dir
Write-Status 'a' "waiting $($now - 10)"
Write-Status 'b' "working $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'waiting+working: yellowbusy' 'yellowbusy' $s.Color

# 14) waiting allein -> weiterhin yellow
Clear-Dir
Write-Status 'a' "waiting $($now - 10)"
$s = Get-SignalState -SessionsDir $tmp -NowUnix $now
Check 'waiting allein: yellow' 'yellow' $s.Color

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fails -eq 0) { Write-Output 'ALLE TESTS OK'; exit 0 }
else { Write-Output "$($script:fails) TEST(S) FEHLGESCHLAGEN"; exit 1 }

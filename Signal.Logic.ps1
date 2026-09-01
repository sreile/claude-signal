# Claude Signal: Aggregationslogik, getrennt vom UI, damit testbar.
# Statusdateiformat: "<status> <unix-timestamp>" (eine Zeile), Status in working|waiting|done|waitingbusy.
# waitingbusy: ein Hintergrund-Agent hat versucht, ein "waiting" zu überschreiben — Warten
# gewinnt trotzdem, aber es läuft nebenher noch etwas. Die Farbe dafür heißt 'yellowbusy'
# (Punkt/Tastatur: rot, aber laufend statt pulsierend — eigener Anzeige-Zustand).
# Seiteneffekt: Get-SignalState löscht beim Aufruf Statusdateien, die älter als 24 h sind (Aufräumen).

function Get-SignalState {
    param(
        [Parameter(Mandatory)][string]$SessionsDir,
        [long]$NowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )
    $counts = @{ waiting = 0; working = 0; done = 0; waitingbusy = 0 }
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
            if ($age -lt -300) { continue }  # Uhren-Schieflage WSL/Windows — Datei ignorieren, nicht löschen
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
    if (($counts['waiting'] -gt 0) -or ($counts['waitingbusy'] -gt 0)) {
        # Wartet auf Nutzer. Läuft nebenher noch etwas -> eigener Zustand (rotes Laufen)
        if (($counts['waitingbusy'] -gt 0) -or ($counts['working'] -gt 0)) { $color = 'yellowbusy' }
        else { $color = 'yellow' }
    }
    elseif ($counts['working'] -gt 0) { $color = 'red' }
    elseif ($counts['done']    -gt 0) { $color = 'green' }

    $waitingTotal = $counts['waiting'] + $counts['waitingbusy']
    $total = $waitingTotal + $counts['working'] + $counts['done']
    $tooltip = if ($total -eq 0) { 'Claude Signal: keine Session' }
        else { "$total Session(s): $($counts['working']) arbeitet, $waitingTotal wartet, $($counts['done']) fertig" }

    [pscustomobject]@{ Color = $color; Tooltip = $tooltip; Counts = $counts }
}

# Claude Signal

Zeigt dir auf einen Blick, was deine Claude-Code-Sessions (WSL2) gerade
treiben — als schwebender Farbpunkt auf dem Windows-Desktop und zusätzlich
auf der RGB-Tastatur.

## Farben

Punkt und Tastatur sprechen dieselbe Farbsprache — bis auf den Leerlauf:
dort ist der Punkt ausgeblendet, während die Tastatur ruhig blau bleibt.

### Overlay-Punkt

| Farbe | Bedeutung |
|---|---|
| ⚫ kein Punkt (ausgeblendet) | Keine (lebende) Session |
| 🔵 Helles Blau (`#2878FF`), sanft pulsierend | Mindestens eine Session arbeitet |
| 🔴 Rot (`#E53935`), schnell pulsierend | Mindestens eine Session wartet auf dich (Berechtigung/Eingabe) |
| 🔴 Rot (`#E53935`), schnell pulsierend | Wartet auf dich, UND ein Hintergrund-Agent arbeitet noch weiter (optisch gleich wie „nur wartet" — der Unterschied zeigt sich auf der Tastatur) |
| 🟢 Grün (`#43A047`) | Mindestens eine Session offen, alle fertig |

Priorität bei mehreren Sessions: **wartet > arbeitet > fertig > keine Session**
— „wartet auf dich" gewinnt, weil das die einzige Info ist, auf die du
reagieren musst. Das gilt auch, wenn parallel ein Hintergrund-Agent noch
arbeitet: Ein offenes „waiting" wird **nie** von einem Agenten überschrieben,
nur von der Hauptkette selbst aufgelöst (siehe Update 3 im Spec-Dokument).
Beim Absenden einer Antwort springt die Anzeige sofort auf „arbeitet"
(PostToolUse-Hook) — gilt ab der nächsten neuen Session.

### Tastatur (Turtle Beach Vulcan II via SignalRGB)

| Zustand | Optik |
|---|---|
| Keine Session | Ruhiges Blau, konstant |
| Arbeitet | Blau mit Lauf-/Atemeffekt |
| Wartet auf dich | Rot, kräftig pulsierend |
| Wartet auf dich, Hintergrund arbeitet noch | Rot, laufend (schnell) |
| Fertig | Grün, konstant |

Puls vs. Laufen: Pulsieren („Claude Rot Puls") heißt reines Warten — nichts
läuft mehr nebenher. Laufen („Claude Rot Lauf", eine schnellere Welle) heißt
zusätzlich, dass im Hintergrund noch ein Agent aktiv ist, während du gefragt
wirst.

## Architektur

Claude-Code-Hooks in `~/.claude/settings.json` rufen bei sieben Ereignissen
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`,
`Stop`, `SessionEnd`) `report-status.sh` auf. Das Skript schreibt pro Session eine
Statusdatei nach `<LOCALAPPDATA>\ClaudeSignal\sessions\` — welcher konkrete
Windows-Pfad sich hinter `<LOCALAPPDATA>` verbirgt, ermittelt `install.sh`
einmalig zur Installationszeit (per PowerShell + `wslpath`) und hinterlegt ihn
in `signal.env` neben den Skripten; `report-status.sh` liest diese Datei bei
jedem Aufruf. `ClaudeSignal.ps1` (WPF, Polling alle 500 ms) liest die
Statusdateien, aggregiert sie nach der Prioritätsregel oben, färbt den Punkt —
und feuert bei jedem Farbwechsel zusätzlich einen
`signalrgb://effect/apply/<Effekt>`-Deep-Link, der die Tastatur umschaltet.

```
Claude Code Hooks (WSL)                Windows
┌──────────────────────┐   schreibt   ┌─────────────────────────────┐
│ report-status.sh     │ ───────────► │ <LOCALAPPDATA>\ClaudeSignal\│
│ (pro Hook-Ereignis,   │              │   sessions\<id>.status      │
│  liest Ziel aus       │              └──────────────┬──────────────┘
│  signal.env)          │                   pollt alle 500 ms
└──────────────────────┘              ┌──────────────▼──────────────┐
                                      │ ClaudeSignal.ps1 (WPF)      │
                                      │ aggregiert → färbt Punkt    │
                                      └──────────────┬──────────────┘
                                            bei Farbwechsel
                                      ┌──────────────▼──────────────┐
                                      │ signalrgb://effect/apply/…  │
                                      │ (nur falls SignalRGB läuft) │
                                      └──────────────┬──────────────┘
                                                      ▼
                                      SignalRGB → Turtle Beach Vulcan II
```

## Installation

```bash
bash ~/.claude/claude-signal/install.sh
```

Idempotent — mehrfaches Ausführen schadet nicht. Ermittelt bei jedem Lauf
automatisch die aktuellen Windows-Pfade für `%LOCALAPPDATA%` und das
Dokumente-Verzeichnis (per PowerShell + `wslpath`) und hinterlegt sie in
`signal.env` neben den Skripten — keine hartkodierten Benutzerpfade. Legt bei
Bedarf ein Backup von `~/.claude/settings.json` an, trägt fehlende Hooks nach
(und entfernt dabei veraltete Hook-Einträge, die noch auf einen älteren
Installationsort zeigen), deployt das Overlay sowie die fünf
SignalRGB-Effektdateien nach Windows.

**Voraussetzung:** `python3` muss in WSL installiert sein — `install.sh`
prüft das und bricht sonst mit Fehlermeldung ab.

**Wichtig:** Hooks gelten erst für **neue** Claude-Sessions. Bereits laufende
Sessions laden `settings.json` nicht nach.

## Installation auf einem neuen Rechner

**Voraussetzungen:**
- Windows mit WSL2
- Claude Code (in WSL installiert)
- `python3` in WSL
- Optional, für die Tastatur-Kopplung: SignalRGB sowie eine von SignalRGB
  unterstützte RGB-Tastatur

**Einrichtung:**

```bash
git clone https://github.com/sreile/claude-signal.git ~/.claude/claude-signal
bash ~/.claude/claude-signal/install.sh
```

Das Repo-Verzeichnis kann dabei an einer beliebigen Stelle liegen —
`install.sh` ermittelt alle Pfade relativ zu seinem eigenen Speicherort, nicht
zu einem festen Namen oder Benutzer.

Danach:
- Hooks gelten erst für **neue** Claude-Code-Sessions — bereits laufende
  Sessions laden `settings.json` nicht nach, also neu starten.
- Für die Tastatur-Kopplung: SignalRGB einmal starten und unter Einstellungen
  → „Bei der Anmeldung starten" aktivieren (steht standardmäßig auf AUS).
- Turtle-Beach-Vulcan-II-Nutzer: Tastatur muss auf Onboard-**Profil 1** stehen
  (`FN+F1`) — nur dort gibt die Firmware die LED-Kontrolle an Software frei.
- Ohne SignalRGB läuft nur der Bildschirm-Punkt (bewusster Guard, kein
  Fehler) — die Tastatur-Kopplung bleibt dann einfach inaktiv.

## Betriebsvoraussetzungen

1. **Tastatur muss auf Onboard-Profil 1 stehen** (`FN+F1`). Nur auf Profil 1
   gibt die Firmware die LED-Kontrolle an Software frei — auf Profil 2–4
   ignoriert sie Beleuchtungs-Befehle stumm (heute empirisch ermittelt, kein
   Fehler, keine Meldung, einfach nichts).
2. **SignalRGB muss laufen.** Empfehlung: in SignalRGB unter Einstellungen →
   „Bei der Anmeldung starten" aktivieren (steht standardmäßig auf AUS).
3. **Turtle Beach Swarm II darf nicht parallel laufen** — beide Tools kämpfen
   sonst um die Beleuchtung.

Läuft SignalRGB nicht, macht die Tastatur-Kopplung schlicht nichts (bewusster
Guard, kein Fehler) — der Overlay-Punkt funktioniert davon unabhängig weiter.

## Bedienung

- **Punkt verschieben:** einfach mit der Maus ziehen, Position wird gemerkt.
- **Hover:** Tooltip mit Session-Zählung (z. B. „2 Session(s): 1 arbeitet, 0 wartet, 1 fertig").
- **Ohne Session unsichtbar:** Der Punkt blendet sich automatisch aus, sobald
  keine Session mehr lebt, und erscheint bei der nächsten wieder von selbst.
- **Rechtsklick:** beendet das Overlay und setzt die Tastatur dabei auf
  Ruhe-Blau zurück. Deinen eigenen SignalRGB-Lieblingseffekt musst du danach
  manuell wieder anwählen. Funktioniert nur, während der Punkt sichtbar ist —
  ist er gerade ausgeblendet, beendest du den Prozess stattdessen so:
  ```bash
  cd /mnt/c && powershell.exe -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*ClaudeSignal.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
  ```
  (oder du lässt ihn einfach laufen — er startet ohnehin automatisch mit).
- **Effekte anpassen:** Dateien in `signalrgb-effects/` editieren, dann
  `bash ~/.claude/claude-signal/install.sh`, danach SignalRGB neu starten — es
  liest neue oder geänderte Effektdateien erst nach einem Neustart ein.
  **Wichtig:** Effektdateien dürfen kein `<!doctype>`, `<meta charset>` oder
  `<style>` enthalten — SignalRGBs Indexer verweigert sie sonst.

## Troubleshooting

**Tastatur reagiert nicht:**
- Steht die Tastatur auf Profil 1?
- Läuft der Prozess `SignalRgb`?
- Ist Swarm II beendet?
- Nach einer Effekt-Änderung: wurde SignalRGB neu gestartet?

**`report-status.sh` von Hand testen:**
stdin muss gepipt sein — ein Aufruf mit Terminal-stdin ist absichtlich ein
No-op. Nach der Installation liest das Skript sein Ziel automatisch aus
`signal.env` neben den Skripten:

```bash
echo '{"session_id":"test"}' | bash ~/.claude/claude-signal/report-status.sh working
```

Danach aufräumen (den Windows-Pfad zeigt `install.sh` bei der Installation an
— steht auch in `signal.env` als `CLAUDE_SIGNAL_WIN_DIR`; alternativ in
PowerShell `echo $env:LOCALAPPDATA` ausführen):

```bash
rm '<LOCALAPPDATA>\ClaudeSignal\sessions\test.status'
```

**Punkt bleibt dauerhaft grau trotz laufender Session:**
Die Session wurde vor der Hook-Installation gestartet und kennt die Hooks
nicht. Neue Session öffnen.

**Overlay verschwunden:**
Startet automatisch mit der nächsten neuen Claude-Session (`SessionStart`-
Hook). Manuell starten geht auch — `<LOCALAPPDATA>` durch den bei der
Installation angezeigten Pfad ersetzen:

```bash
cd /mnt/c && setsid nohup powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
  -File '<LOCALAPPDATA>\ClaudeSignal\ClaudeSignal.ps1' >/dev/null 2>&1 &
```

**Abgestürzte Sessions:**
„Arbeitet"-Einträge, deren Zeitstempel älter als 60 Minuten ist, werden bei
der Aggregation ignoriert (gelten als stale). Statusdateien, die älter als
24 Stunden sind, werden automatisch gelöscht.

## Deinstallation

1. Den `hooks`-Block aus `~/.claude/settings.json` entfernen. **Nicht**
   einfach ein `settings.json.bak.*` zurückspielen — die vorhandenen Backups
   enthalten die Hooks bereits.
2. Ordner `<LOCALAPPDATA>\ClaudeSignal` löschen (Windows-Pfad wie oben
   ermitteln).
3. Die fünf `Claude *.html`-Dateien aus `Documents\WhirlwindFX\Effects`
   löschen (im Explorer als „Dokumente" angezeigt).
4. Optional: SignalRGB deinstallieren (`winget uninstall WhirlwindFX.SignalRgb`).

## Bekannte Grenzen

- Ein einzelner Tool-Aufruf, der länger als 60 Minuten läuft, gilt als stale —
  der Punkt kann dann fälschlich auf Grau/Grün zurückfallen (in der Praxis
  selten).
- Sessions, die hart abstürzen, hinterlassen bis zur Stale-/24h-Bereinigung
  eine Datei; solche `done`-Leichen zeigen bis dahin Grün statt Grau.
- Gilt für alle Sessions dieses WSL-Users; mehrere Distros oder Windows-User
  sind außerhalb des Umfangs.
- Die `PreToolUse`- und `PostToolUse`-Hooks kosten pro Tool-Aufruf ein paar
  Millisekunden zusätzlich.
- Das Tastatur-Schema greift nur bei dieser konkreten Konstellation: Turtle
  Beach Vulcan II + SignalRGB. OpenRGB wurde probiert, scheiterte aber an der
  Firmware-Revision dieser Tastatur (`10F5:501B`) — siehe Repo-Verlauf.

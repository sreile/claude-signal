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

### RGB-Geräte (via OpenRGB)

Die Kopplung läuft komplett lautlos über [OpenRGB](https://openrgb.org/) —
kein Fenster, kein Effektwechsel, keine Sandbox-Beschränkungen. Ein
persistenter `OpenRGB.exe --server`-Prozess läuft im Hintergrund und hält die
zuletzt gesetzte Farbe; das Overlay schickt bei jedem Zustandswechsel (bzw.
beim Blinken alle 500 ms) einen kurzen Wegwerf-Aufruf
(`OpenRGB.exe --device 0 --mode direct --color …`), der sich automatisch mit
dem laufenden Server verbindet und die Farbe umschaltet.

| Zustand | Optik |
|---|---|
| Keine Session | Ruhiges Blau, konstant |
| Arbeitet | Helleres Blau, konstant |
| Wartet auf dich | Rot, blinkt ca. 1×/Sekunde |
| Wartet auf dich, Hintergrund arbeitet noch | Rot, blinkt schneller (ca. 2×/Sekunde) |
| Fertig | Grün, konstant |

**Wellen-/Puls-Animationen gibt es in v4 nicht mehr:** OpenRGBs
Kommandozeile kann nur einzelne Farben setzen, keine Lauf- oder Atem-Effekte.
Statt sanftem Pulsieren blinkt die Tastatur beim Warten zwischen der
Zustandsfarbe und einem sehr dunklen Rot. Bewusster Trade-off zugunsten von
Lautlosigkeit (kein Fenster, kein Deep-Link, keine Effekt-Sandbox) —
weichere Animationen wären über OpenRGBs SDK-Streaming-Protokoll möglich,
sind aber (noch) nicht umgesetzt.

**Profil 1 ist Pflicht (Turtle Beach Vulcan II):** Die Tastatur muss auf
Onboard-**Profil 1** stehen (`FN+F1`). Das ist die entscheidende, selbst
herausgefundene Erkenntnis, die OpenRGB überhaupt erst funktionieren ließ —
auf Profil 2–4 gibt die Firmware die LED-Kontrolle nicht an Software ab.
Frühere Fehlversuche mit OpenRGB scheiterten daran (plus an Testläufen gegen
eine zwischenzeitlich gelöschte Programmdatei) — nicht an OpenRGB selbst.

**Alle Geräte statt nur der Tastatur:** Standardmäßig steuert das Overlay nur
Gerät 0 (die Tastatur). Um wirklich **alle** von OpenRGB erkannten Geräte
mitfärben zu lassen (Lüfter, AIO-Kühler, RAM-Module, …), lege eine
`config.json` im Deploy-Ordner an
(`<LOCALAPPDATA>\ClaudeSignal\config.json`, Inhalt `{"AllRgbDevices": true}`)
— beim nächsten Verschieben des Punkts schreibt das Overlay diese Einstellung
zusammen mit der Position automatisch fort. Hinweis: Mainboard-/RAM-RGB über
OpenRGB braucht meist zusätzlich den PawnIO-Treiber und einmalig
Admin-Rechte bei der Ersteinrichtung; USB-Lüfter-Hubs in der Regel nicht.

**SignalRGB: nicht mehr benötigt.** Frühere Versionen nutzten SignalRGB samt
Deep-Links bzw. einem selbst-pollenden Effekt — beides erwies sich als
unzuverlässig (Fenster poppt ungefragt hoch bzw. die Effekt-Sandbox blockiert
Datei-/HTTP-Zugriffe komplett). SignalRGB wird jetzt nicht mehr gebraucht:
Der Autostart-Dienst kann auf „Manuell" gestellt werden, optional lässt sich
SignalRGB komplett deinstallieren (`winget uninstall WhirlwindFX.SignalRgb`).
**Wichtig:** SignalRGB darf **niemals** parallel zu OpenRGB laufen — beide
kämpfen um dieselbe Gerätekontrolle.

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
und schickt bei jedem Zustandswechsel (bzw. beim Blinken) einen kurzen
`OpenRGB.exe`-Kommandozeilenaufruf, der die zuvor per `--server` gestartete
OpenRGB-Instanz auf die neue Farbe umschaltet. Kein Effektwechsel, kein
Deep-Link, kein Fenster — die frühere SignalRGB-Lösung ist komplett ersetzt
(siehe Update 8 im Spec-Dokument).

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
                                        Farbwechsel / Blinken (500 ms)
                                      ┌──────────────▼──────────────┐
                                      │ OpenRGB.exe --device 0      │
                                      │  --mode direct --color …    │
                                      │ (Wegwerf-Client-Aufruf)     │
                                      └──────────────┬──────────────┘
                                          verbindet sich automatisch zu
                                      ┌──────────────▼──────────────┐
                                      │ OpenRGB.exe --server        │
                                      │ (persistent, hält die Farbe)│
                                      └──────────────┬──────────────┘
                                                      ▼
                                      angeschlossene RGB-Geräte
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
Installationsort zeigen), deployt das Overlay und lädt bei Bedarf OpenRGB
automatisch herunter (Windows-Build, entpackt nach
`<LOCALAPPDATA>\ClaudeSignal\tools\OpenRGB\`; schlägt der Download fehl,
ist das nicht fatal — die Installation läuft durch, nur die Geräte-Kopplung
bleibt dann inaktiv). Räumt außerdem alle Effektdateien früherer Versionen
aus `Documents\WhirlwindFX\Effects` sowie veraltete v3-Artefakte auf, falls
noch vorhanden.

**Voraussetzung:** `python3` muss in WSL installiert sein — `install.sh`
prüft das und bricht sonst mit Fehlermeldung ab.

**Wichtig:** Hooks gelten erst für **neue** Claude-Sessions. Bereits laufende
Sessions laden `settings.json` nicht nach.

## Installation auf einem neuen Rechner

**Voraussetzungen:**
- Windows mit WSL2
- Claude Code (in WSL installiert)
- `python3` in WSL (`curl` wird für den automatischen OpenRGB-Download
  empfohlen, ist aber nicht zwingend — fehlt es, bleibt die Geräte-Kopplung
  einfach inaktiv, der Rest funktioniert normal)
- Optional, für die Geräte-Kopplung: mindestens ein von OpenRGB
  unterstütztes RGB-Gerät (OpenRGB selbst lädt `install.sh` automatisch
  herunter)

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
- Für die Geräte-Kopplung ist nichts weiter zu tun — das Overlay startet den
  OpenRGB-Server beim ersten Start selbst, lautlos im Hintergrund.
- Turtle-Beach-Vulcan-II-Nutzer: Tastatur muss auf Onboard-**Profil 1** stehen
  (`FN+F1`) — nur dort gibt die Firmware die LED-Kontrolle an Software frei.
- Läuft noch eine ältere SignalRGB-Installation: beenden bzw. deinstallieren
  (`winget uninstall WhirlwindFX.SignalRgb`) — parallel zu OpenRGB kämpfen
  beide um die Geräte.
- Ohne OpenRGB (z. B. weil der automatische Download fehlschlug) läuft nur
  der Bildschirm-Punkt (bewusster Guard, kein Fehler) — die Geräte-Kopplung
  bleibt dann einfach inaktiv.

## Betriebsvoraussetzungen

1. **Nur bei der Turtle Beach Vulcan II:** Die Tastatur muss auf
   Onboard-Profil 1 stehen (`FN+F1`). Nur auf Profil 1 gibt deren Firmware die
   LED-Kontrolle an Software frei — auf Profil 2–4 ignoriert sie
   Beleuchtungs-Befehle stumm (empirisch ermittelt, kein Fehler, keine
   Meldung, einfach nichts — das war auch der Grund, warum frühere Versuche
   mit OpenRGB scheiterten, nicht OpenRGB selbst). Andere Geräte brauchen
   keinen solchen Trick — alles, was OpenRGB steuern kann, funktioniert
   direkt.
2. **SignalRGB darf nicht parallel laufen**, falls noch installiert — beide
   Tools kämpfen sonst um dieselbe Beleuchtung. Am saubersten: den
   SignalRGB-Autostart deaktivieren oder SignalRGB deinstallieren.
3. **Turtle Beach Swarm II darf nicht parallel laufen** — derselbe Konflikt
   wie bei SignalRGB.

Der OpenRGB-Server startet automatisch mit dem Overlay — nichts ist manuell
zu starten oder zu konfigurieren. Fehlt OpenRGB (z. B. weil der Download bei
der Installation fehlschlug), macht die Geräte-Kopplung schlicht nichts
(bewusster Guard, kein Fehler) — der Overlay-Punkt funktioniert davon
unabhängig weiter.

## Bedienung

- **Punkt verschieben:** einfach mit der Maus ziehen, Position wird gemerkt.
- **Hover:** Tooltip mit Session-Zählung (z. B. „2 Session(s): 1 arbeitet, 0 wartet, 1 fertig").
- **Ohne Session unsichtbar:** Der Punkt blendet sich automatisch aus, sobald
  keine Session mehr lebt, und erscheint bei der nächsten wieder von selbst.
- **Rechtsklick:** beendet das Overlay und schickt den Geräten vorher noch
  einen letzten stillen Befehl auf Ruhe-Blau zurück. Funktioniert nur,
  während der Punkt sichtbar ist — ist er gerade ausgeblendet, beendest du
  den Prozess stattdessen so:
  ```bash
  cd /mnt/c && powershell.exe -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*ClaudeSignal.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
  ```
  (oder du lässt ihn einfach laufen — er startet ohnehin automatisch mit).
- **Farben anpassen:** `$kbMap` in `ClaudeSignal.ps1` enthält die Hex-Farben
  pro Zustand (ohne `#`, OpenRGB-Format) — direkt editieren, dann
  `bash ~/.claude/claude-signal/install.sh` erneut ausführen.

## Troubleshooting

**RGB-Geräte reagieren nicht:**
- Steht die Tastatur (bei Turtle Beach Vulcan II) auf Profil 1?
- Existiert
  `<LOCALAPPDATA>\ClaudeSignal\tools\OpenRGB\OpenRGB Windows 64-bit\OpenRGB.exe`?
  Falls nicht: `install.sh` erneut ausführen (lädt OpenRGB nach) oder es
  manuell von https://openrgb.org besorgen und dorthin entpacken.
- Läuft der Prozess `OpenRGB` (Taskmanager)? Er startet automatisch mit der
  nächsten neuen Claude-Session — bei Bedarf eine neue Session öffnen.
- Läuft SignalRGB oder Swarm II noch parallel? Beenden — beide kämpfen mit
  OpenRGB um dieselben Geräte.

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
   ermitteln) — entfernt Overlay, Statusdateien und die mitgelieferte
   OpenRGB-Installation in einem Schritt.
3. Optional, falls noch vorhanden: alte `Claude *.html`-Effektdateien aus
   `Documents\WhirlwindFX\Effects` löschen sowie SignalRGB deinstallieren
   (`winget uninstall WhirlwindFX.SignalRgb`) — wird von aktuellen Versionen
   dieses Tools nicht mehr benötigt.

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
- Keine Wellen-/Puls-Animationen mehr auf der Tastatur — OpenRGBs
  Kommandozeile kann nur Farben setzen, „wartet" zeigt sich daher als
  Blinken statt als weicher Puls (siehe RGB-Geräte-Abschnitt oben).
- Die Geräte-Kopplung setzt OpenRGB voraus und funktioniert mit jedem dort
  unterstützten Gerät. Frühere Fehlversuche mit OpenRGB lagen am aktiven
  Tastatur-Profil (4 statt 1), nicht an OpenRGB selbst — siehe Repo-Verlauf.

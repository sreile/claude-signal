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

### RGB-Geräte (via SignalRGB)

Die Kopplung funktioniert mit **jedem Gerät, das SignalRGB unterstützt** —
Tastaturen, Mäuse, LED-Strips, Lüfter: alle angeschlossenen Geräte wechseln
gemeinsam die Farbe. Getestet mit einer Turtle Beach Vulcan II (die eine
Eigenheit hat, siehe Betriebsvoraussetzungen).

Ein einziger, dauerhaft installierter Effekt namens **„Claude Signal"** zeigt
den Status — er liest die Statusdatei selbst (mehrmals pro Sekunde) und
zeichnet sich entsprechend um. Es gibt keinen Effektwechsel mehr, der
SignalRGB ins Vordergrundfenster holen könnte.

| Zustand | Optik |
|---|---|
| Keine Session | Ruhiges Blau, konstant |
| Arbeitet | Blau mit Lauf-/Atemeffekt |
| Wartet auf dich | Rot, kräftig pulsierend |
| Wartet auf dich, Hintergrund arbeitet noch | Rot, laufend (schnell) |
| Fertig | Grün, konstant |

Puls vs. Laufen: Pulsieren heißt reines Warten — nichts läuft mehr nebenher.
Laufen (eine schnellere Welle) heißt zusätzlich, dass im Hintergrund noch ein
Agent aktiv ist, während du gefragt wirst.

**Einmalig aktivieren:** In SignalRGB unter Bibliothek/Effekte „Claude
Signal" auswählen. Alternativ genügt einmalig der Link
`signalrgb://effect/apply/Claude%20Signal`. Danach läuft alles automatisch —
du kannst jederzeit zu einem anderen SignalRGB-Effekt wechseln und später
ganz normal über SignalRGB wieder zurück zu „Claude Signal".

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
und schreibt den aktuellen Zustand zusätzlich in `state.txt` (Format
`<zustand> <epochMs>`). Der dauerhaft installierte SignalRGB-Effekt „Claude
Signal" liest diese Datei selbständig mehrmals pro Sekunde
(`requestAnimationFrame`-Loop — `setInterval` wird von SignalRGBs Renderer
gedrosselt) und rendert seinen Zustand direkt; das Overlay muss dazu keinen
Effektwechsel mehr anstoßen (die frühere Deep-Link-Lösung holte SignalRGBs
Fenster gelegentlich ungefragt in den Vordergrund, siehe Update 6/7 im
Spec-Dokument).

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
                                          schreibt bei jedem Tick
                                      ┌──────────────▼──────────────┐
                                      │ state.txt (<Zustand> <ms>)  │
                                      └──────────────┬──────────────┘
                                        liest sich selbst, alle ~600 ms
                                      ┌──────────────▼──────────────┐
                                      │ SignalRGB-Effekt            │
                                      │ „Claude Signal" (rAF-Loop)  │
                                      └──────────────┬──────────────┘
                                                      ▼
                                      SignalRGB → angeschlossene Geräte
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
Installationsort zeigen), deployt das Overlay sowie den SignalRGB-Effekt
„Claude Signal" nach Windows (generiert aus einer Vorlage mit dem echten
`state.txt`-Pfad) und entfernt dabei die fünf alten Einzel-Effekte, falls sie
noch von einer älteren Installation vorhanden sind.

**Voraussetzung:** `python3` muss in WSL installiert sein — `install.sh`
prüft das und bricht sonst mit Fehlermeldung ab.

**Wichtig:** Hooks gelten erst für **neue** Claude-Sessions. Bereits laufende
Sessions laden `settings.json` nicht nach.

## Installation auf einem neuen Rechner

**Voraussetzungen:**
- Windows mit WSL2
- Claude Code (in WSL installiert)
- `python3` in WSL
- Optional, für die Geräte-Kopplung: SignalRGB sowie mindestens ein von
  SignalRGB unterstütztes RGB-Gerät

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
- Für die Geräte-Kopplung: SignalRGB einmal starten und unter Einstellungen
  → „Bei der Anmeldung starten" aktivieren (steht standardmäßig auf AUS), dann
  einmalig unter Bibliothek/Effekte den Effekt „Claude Signal" auswählen —
  danach läuft alles automatisch.
- Turtle-Beach-Vulcan-II-Nutzer: Tastatur muss auf Onboard-**Profil 1** stehen
  (`FN+F1`) — nur dort gibt die Firmware die LED-Kontrolle an Software frei.
- Ohne SignalRGB läuft nur der Bildschirm-Punkt (bewusster Guard, kein
  Fehler) — die Geräte-Kopplung bleibt dann einfach inaktiv.

## Betriebsvoraussetzungen

1. **Nur bei der Turtle Beach Vulcan II:** Die Tastatur muss auf
   Onboard-Profil 1 stehen (`FN+F1`). Nur auf Profil 1 gibt deren Firmware die
   LED-Kontrolle an Software frei — auf Profil 2–4 ignoriert sie
   Beleuchtungs-Befehle stumm (empirisch ermittelt, kein Fehler, keine
   Meldung, einfach nichts). Andere Geräte brauchen keinen solchen Trick —
   alles, was SignalRGB steuern kann, funktioniert direkt.
2. **SignalRGB muss laufen.** Empfehlung: in SignalRGB unter Einstellungen →
   „Bei der Anmeldung starten" aktivieren (steht standardmäßig auf AUS).
3. **Turtle Beach Swarm II darf nicht parallel laufen** — beide Tools kämpfen
   sonst um die Beleuchtung.

Läuft SignalRGB nicht, macht die Geräte-Kopplung schlicht nichts (der Effekt
liest state.txt einfach nicht) — der Overlay-Punkt funktioniert davon
unabhängig weiter.

## Bedienung

- **Punkt verschieben:** einfach mit der Maus ziehen, Position wird gemerkt.
- **Hover:** Tooltip mit Session-Zählung (z. B. „2 Session(s): 1 arbeitet, 0 wartet, 1 fertig").
- **Ohne Session unsichtbar:** Der Punkt blendet sich automatisch aus, sobald
  keine Session mehr lebt, und erscheint bei der nächsten wieder von selbst.
- **Rechtsklick:** beendet das Overlay und schreibt vorher noch einmal
  „gray" nach `state.txt` — läuft der Effekt „Claude Signal" gerade, zeigt er
  das binnen ~600 ms als Ruhe-Blau. Da das Overlay nie mehr aktiv einen
  Effekt wechselt, bleibt dabei alles unangetastet, was du sonst in SignalRGB
  eingestellt hast. Funktioniert nur, während der Punkt sichtbar ist — ist er
  gerade ausgeblendet, beendest du den Prozess stattdessen so:
  ```bash
  cd /mnt/c && powershell.exe -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.ProcessId -ne $PID -and $_.CommandLine -like "*-File*ClaudeSignal.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
  ```
  (oder du lässt ihn einfach laufen — er startet ohnehin automatisch mit).
- **Effekt anpassen:** `signalrgb-effects/Claude Signal.html.template`
  editieren (den Platzhalter `{{STATE_URL}}` unverändert lassen —
  `install.sh` ersetzt ihn durch den echten `state.txt`-Pfad), dann
  `bash ~/.claude/claude-signal/install.sh`, danach SignalRGB neu starten — es
  liest neue oder geänderte Effektdateien erst nach einem Neustart ein.
  **Wichtig:** Effektdateien dürfen kein `<!doctype>`, `<meta charset>` oder
  `<style>` enthalten — SignalRGBs Indexer verweigert sie sonst.

## Troubleshooting

**RGB-Geräte reagieren nicht:**
- Ist der Effekt „Claude Signal" in SignalRGB aktiv ausgewählt (nicht
  irgendein anderer)?
- Steht die Tastatur (bei Turtle Beach Vulcan II) auf Profil 1?
- Läuft der Prozess `SignalRgb`?
- Ist Swarm II beendet?
- Nach einer Effekt-Änderung in `signalrgb-effects/`: wurde SignalRGB neu
  gestartet?

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
3. Die Datei `Claude Signal.html` aus `Documents\WhirlwindFX\Effects` löschen
   (im Explorer als „Dokumente" angezeigt).
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
- Der SignalRGB-Effekt zeigt bis zu 10 s nach dem letzten Overlay-Herzschlag
  (z. B. weil das Overlay beendet wurde) weiterhin den letzten Zustand, bevor
  er selbständig auf Grau zurückfällt (Stale-Fallback in `state.txt`).
- Die Geräte-Kopplung setzt SignalRGB voraus; sie funktioniert mit jedem dort
  unterstützten Gerät. OpenRGB wurde als schlankere Alternative probiert,
  scheiterte aber an der Firmware-Revision der Test-Tastatur (Turtle Beach
  Vulcan II, `10F5:501B`) — siehe Repo-Verlauf.

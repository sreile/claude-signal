# Claude Signal

Zeigt dir auf einen Blick, was deine Claude-Code-Sessions gerade
treiben — auf deinen RGB-Geräten (Tastatur, Lüfter, AIO, …), optional
zusätzlich als schwebender Farbpunkt auf dem Windows-Desktop (`ShowDot`).

> **Voraussetzungen:** 🪟 **Windows** mit **Claude Code in WSL2** ·
> 🌈 RGB-Steuerung über **[OpenRGB](https://openrgb.org)** (Open Source,
> wird vom Installer automatisch mitgeliefert — Version ist gepinnt).
> Andere Setups (Claude Code nativ auf Windows, Linux/macOS) werden
> derzeit **nicht** unterstützt.

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
| 🟡 Gelb (`#FFC800`) | Session-/Nutzungslimit erreicht — Claude wartet automatisch weiter (siehe „Session-/Nutzungslimit erkennen" unten) |
| 🟢 Grün (`#43A047`) | Mindestens eine Session offen, alle fertig |

Priorität bei mehreren Sessions: **wartet > limitiert > arbeitet > fertig >
keine Session** — „wartet auf dich" gewinnt, weil das die einzige Info ist,
auf die du reagieren musst. Das gilt auch, wenn parallel ein Hintergrund-Agent
noch arbeitet: Ein offenes „waiting" wird **nie** von einem Agenten
überschrieben, nur von der Hauptkette selbst aufgelöst (siehe Update 3 im
Spec-Dokument). „Limitiert" steht vor „arbeitet", weil ein Limit kontoweit
gilt, nicht pro Session. Beim Absenden einer Antwort springt die Anzeige
sofort auf „arbeitet" (PostToolUse-Hook) — gilt ab der nächsten neuen Session.

### RGB-Geräte (via OpenRGB)

Ein kleiner Hintergrunddienst — `SignalAnimator.exe` (C#, von `install.sh`
mit dem in jedem .NET Framework mitgelieferten `csc.exe` kompiliert, keine
zusätzliche Abhängigkeit) — verbindet sich mit
[OpenRGBs](https://openrgb.org/) SDK-Server (Port 6742) und **streamt echte
Wellen-/Puls-Animationen direkt auf die einzelnen LEDs**, bis zu 20 Bilder
pro Sekunde. Das Overlay selbst spricht OpenRGB nicht mehr direkt an — es
schreibt nur den aktuellen Zustand nach `state.txt`, den der Animator bei
jedem Bild neu ausliest. Ein Zustandswechsel zeigt sich dadurch nach
höchstens ~0,6 s auf den Geräten (der 500-ms-Poll-Takt des Overlays plus
ein Animator-Bild). Für jedes Bild öffnet der Animator eine eigene, kurz
lebende Verbindung zum OpenRGB-Server statt eine dauerhafte offen zu
halten (siehe Architektur unten) — und überspringt unveränderte Bilder
(ruhende Zustände wie „keine Session"/„fertig" senden dadurch nur etwa
1×/Sekunde als Lebenszeichen, statt bei jedem Bild neu).

| Zustand | Optik |
|---|---|
| Keine Session | Ruhiges Blau, konstant |
| Arbeitet | Blaue Welle mit sanftem Atmen |
| Wartet auf dich | Rotes Pulsieren (~0,8 s, alle Tasten gleichzeitig — „flächiger Alarm") |
| Wartet auf dich, Hintergrund arbeitet noch | Rote Welle (~1,0 s) — Rot = Aufmerksamkeit, Welle = es läuft noch etwas: „du bist gefragt UND es läuft noch was" |
| Session-/Nutzungslimit erreicht | Langsame gelbe Welle (~2,5 s) — deutlich ruhiger und anders eingefärbt als „arbeitet"/„wartet", damit ein Limit auf den ersten Blick erkennbar ist |
| Fertig | Grün, konstant |

**Profil 1 ist Pflicht (Turtle Beach Vulcan II):** Die Tastatur muss auf
Onboard-**Profil 1** stehen (`FN+F1`). Das ist die entscheidende, selbst
herausgefundene Erkenntnis, die OpenRGB überhaupt erst funktionieren ließ —
auf Profil 2–4 gibt die Firmware die LED-Kontrolle nicht an Software ab.

**Warum eine gepinnte OpenRGB-Version:** `install.sh` installiert bewusst
die stabile Version **1.0rc3.1**, nicht den tagesaktuellen Nightly-Build.
Der Nightly-Build stürzte beim SDK-Streaming auf dieser Tastatur
reproduzierbar mit einer nativen Schutzverletzung ab (siehe Update 10 im
Spec-Dokument für die volle Diagnose); die gepinnte stabile Version hat
dieses Problem nicht. `install.sh` erkennt und ersetzt eine ältere/andere
OpenRGB-Installation automatisch.

**Alle Geräte statt nur der Tastatur:** Standardmäßig steuert der Animator
nur Gerät 0 (die Tastatur). Um wirklich **alle** von OpenRGB erkannten Geräte
mitanimieren zu lassen (Lüfter, AIO-Kühler, RAM-Module, …), lege eine
`config.json` im Deploy-Ordner an
(`<LOCALAPPDATA>\ClaudeSignal\config.json`, Inhalt `{"AllRgbDevices": true}`)
— beim nächsten Verschieben des Punkts schreibt das Overlay diese Einstellung
zusammen mit der Position automatisch fort. Der Animator liest Änderungen an
`config.json` automatisch binnen ~5 s neu ein (kein manueller Neustart nötig,
siehe „Farben & Effekte anpassen" unten) und fragt bei einer Änderung von
`AllRgbDevices` automatisch die Geräteliste neu ab. Hinweis: Mainboard-/
RAM-RGB über OpenRGB braucht meist zusätzlich den PawnIO-Treiber und
einmalig Admin-Rechte bei der Ersteinrichtung; USB-Lüfter-Hubs in der Regel
nicht. Je mehr Geräte gleichzeitig animiert werden, desto niedriger die
Bildrate pro Gerät (die Gesamtrate ist gedeckelt, siehe Architektur unten) —
bei sehr vielen Geräten wirkt das Bild dadurch spürbar ruckeliger.

**SignalRGB: nicht mehr benötigt.** Frühere Versionen nutzten SignalRGB samt
Deep-Links bzw. einem selbst-pollenden Effekt — beides erwies sich als
unzuverlässig (Fenster poppt ungefragt hoch bzw. die Effekt-Sandbox blockiert
Datei-/HTTP-Zugriffe komplett). SignalRGB wird jetzt nicht mehr gebraucht:
Der Autostart-Dienst kann auf „Manuell" gestellt werden, optional lässt sich
SignalRGB komplett deinstallieren (`winget uninstall WhirlwindFX.SignalRgb`).
**Wichtig:** SignalRGB darf **niemals** parallel zu OpenRGB laufen — beide
kämpfen um dieselbe Gerätekontrolle.

### Session-/Nutzungslimit erkennen

Läuft dir mal ein Session- oder Nutzungslimit rein, wartet Claude Code
üblicherweise automatisch weiter — ohne dass währenddessen weitere
Hook-Ereignisse feuern. Ohne Erkennung bliebe die Anzeige die ganze Wartezeit
über auf dem letzten Stand hängen (meist die blaue „arbeitet"-Welle). Deshalb
wertet `report-status.sh` bei jedem `Notification`-Ereignis (Hook-Status
`waiting`) den Nachrichtentext aus: enthält er (unabhängig von Groß-/
Kleinschreibung) einen Ausdruck wie „usage limit", „session limit",
„rate limit", „continuing automatically", „limit reached" oder „resets
<Uhrzeit>", wird daraus **statt** „wartet auf dich" der eigene Zustand
„limitiert" (langsame gelbe Welle, siehe Tabelle oben).

Die Leerlauf-Meldung „Claude is waiting for your input" (feuert ~60 s nach
jedem Zug-Ende, solange der Prompt unbenutzt ist) wird dagegen komplett
**ignoriert** — sie heißt nur „Eingabefeld frei", nicht „Claude fragt dich
etwas", und würde sonst jede fertige Session nach einer Minute fälschlich
rot färben (live beobachtet und behoben am 2026-09-02).

**Am echten Limit verifiziert (2026-09-02):** Beim Limit-**Eintritt** feuert
Claude Code kein eigenes Hook-Ereignis. Aber: Der **Stop-Hook des dadurch
beendeten Zugs** feuert kurz danach — und `report-status.sh` prüft dabei das
Transcript-Ende auf einen **frischen Limit-Fehler** (strukturell über den
JSON-Schlüssel `isApiErrorMessage`, nicht per Text-Suche — Gespräche *über*
Limits lösen keinen Fehlalarm aus; „frisch" = jünger als 10 Minuten). Wird
einer gefunden, meldet der Stop `limitiert` statt `fertig` — die gesamte
Wartezeit zeigt dann die gelbe Welle. Endet ein Zug dagegen sauber, bevor das
Limit zuschlägt (kein frischer Fehler im Transcript), bleibt die letzte
ehrliche Farbe stehen. Beim
Limit-**Ende** kommt dagegen verlässlich `„Usage limit reset — Claude is
continuing your task"` — das wird als `working` klassifiziert (es geht ja
weiter), nicht als Limit. Jede `Notification`-Nachricht wird weiterhin nach
`<LOCALAPPDATA>\ClaudeSignal\notifications.log` mitgeschnitten (letzte 50
Zeilen) — dort lassen sich neue Meldungstexte jederzeit nachschlagen.

## Farben & Effekte anpassen

Alle sechs Zustände lassen sich in `config.json`
(`<LOCALAPPDATA>\ClaudeSignal\config.json`) einzeln umgestalten — ein
optionaler `States`-Block neben `Left`/`Top`/`AllRgbDevices`/`ShowDot`. Ohne
diesen Block (oder ganz ohne `config.json`) verhält sich alles exakt wie mit
den eingebauten Standardwerten, die unten als Beispiel stehen.

**Overlay-Punkt (standardmäßig AUS):** Die RGB-Geräte sind die primäre
Anzeige. Wer zusätzlich einen kleinen Statuspunkt auf dem Desktop möchte,
setzt `"ShowDot": true` in der `config.json` — er erscheint dann bei
Aktivität oben rechts (verschiebbar, Rechtsklick beendet das Overlay).
Gilt ab dem nächsten Overlay-Start (neue Claude-Session). Ohne sichtbaren
Punkt beendet man das Overlay über den `Stop-Process`-Einzeiler aus dem
Bedienungs-Abschnitt. Das Verschieben des Punkts überschreibt die übrigen
Config-Schlüssel nicht (Merge-Save).

```json
{
  "States": {
    "working":     { "effect": "wave",  "from": "#061C6E", "to": "#2878FF", "period_ms": 1400, "breath": true },
    "waiting":     { "effect": "pulse", "from": "#3C0000", "to": "#FF0000", "period_ms": 800 },
    "waitingbusy": { "effect": "wave",  "from": "#280000", "to": "#FF0000", "period_ms": 1000 },
    "done":        { "effect": "solid", "color": "#00B000" },
    "idle":        { "effect": "solid", "color": "#1050E0" },
    "limited":     { "effect": "wave",  "from": "#3A2A00", "to": "#FFC800", "period_ms": 2500 }
  }
}
```

**Zustände:** `working` = arbeitet, `waiting` = wartet auf dich,
`waitingbusy` = wartet + Hintergrund arbeitet noch, `done` = fertig,
`idle` = keine Session, `limited` = Session-/Nutzungslimit erreicht (siehe
„Session-/Nutzungslimit erkennen" oben).

**Effekte:**

| Effekt | Pflichtfelder | Optional | Wirkung |
|---|---|---|---|
| `solid` | `color` | — | konstante Farbe |
| `pulse` | `from`, `to` | `period_ms` (Standard 1000) | alle LEDs gleichzeitig, sinusförmig zwischen `from` und `to`, `period_ms` = volle Zyklusdauer |
| `wave` | `from`, `to` | `period_ms` (Standard 1000), `breath` (Standard `false`) | Lauflicht über die LEDs von `from`- nach `to`-Farbe, `period_ms` = Zeit für einen vollen Durchlauf; `breath: true` legt zusätzlich ein sanftes Ein-/Ausatmen (~1,8 s) über die Helligkeit |

Farben als `"#RRGGBB"` oder `"RRGGBB"` (beide Schreibweisen gehen).
`period_ms` zwischen 50 und 60000.

**Hinweis zu Farbtönen:** Auf dieser Art LEDs wirken helle Mischtöne aus Rot
mit etwas Grün/Blau-Anteil leicht pink statt rein rot. Für kräftige Warn-/
Alarmfarben lieber reines Rot (`#FF0000`) oder reines Blau/Grün als
Zielfarbe (`to`/`color`) verwenden statt gemischter Töne.

**Ungültige Einzeleinträge sind unkritisch:** Fehlt ein Pflichtfeld, ist eine
Farbe kein gültiges Hex oder `effect` unbekannt, fällt **nur dieser eine
Zustand** auf seinen eingebauten Standard zurück (siehe Tabelle oben) — der
Rest der Konfiguration bleibt wirksam. `animator.log` protokolliert das
(„Konfiguration: Zustand '…' ungültig -- Standard verwendet"). Eine komplett
kaputte oder fehlende `config.json` bedeutet einfach: alles auf Standard.

**Wann Änderungen wirken:**
- **Tastatur/Geräte:** `SignalAnimator.exe` liest `config.json` automatisch
  alle ~5 s neu ein (Live-Reload, kein Neustart nötig) — `animator.log`
  zeigt „Konfiguration neu geladen".
- **Bildschirm-Punkt:** liest `config.json` nur beim eigenen Start (für die
  reine Zielfarbe, ohne Animation). Nach einer Änderung übernimmt der Punkt
  die neue Farbe erst nach einem Neustart des Overlays (siehe „Overlay
  verschwunden" unter Troubleshooting für den manuellen Start-Befehl, oder
  einfach eine neue Claude-Session öffnen).

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
und schreibt den aggregierten Zustand zusätzlich in `state.txt` (Format
`<zustand> <epochMs>`, atomar per tmp+rename). Alle ~10 s prüft das Overlay
außerdem, ob der OpenRGB-Server und `SignalAnimator.exe` noch laufen, und
startet sie bei Bedarf neu (Absturz-/Über-Nacht-Schutz). `SignalAnimator.exe`
(C#, eigener Hintergrundprozess) liest `state.txt` bei jedem Bild neu (bis zu
20×/Sekunde, je nach Zahl der angesteuerten Geräte) und rendert direkt auf
die LEDs. Für jedes gesendete Bild öffnet er eine frische, kurzlebige
TCP-Verbindung zu OpenRGBs SDK-Server statt eine dauerhafte offen zu halten
(eine dauerhafte Verbindung schließt der Server nach 1–2 Paketen sauber
wieder) und überspringt dabei unveränderte Bilder (nur ~1×/s Lebenszeichen
im Ruhezustand) — das hält die Verbindungsrate niedrig, auch bei vielen
Geräten gleichzeitig. Bleibt der Zustand 10 Minuten durchgehend „keine
Session", beendet sich der Animator von selbst (die Tick-Überwachung des
Overlays startet ihn bei Bedarf neu) — kein Fenster, kein Effektwechsel,
kein Deep-Link. Die frühere SignalRGB-Lösung sowie das kurzlebige
v4/v4.1-Modell mit Kommandozeilenaufrufen sind komplett ersetzt (siehe
Update 8–11 im Spec-Dokument).

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
                                      │ (prüft alle ~10 s: laufen   │
                                      │  Server + Animator noch?)   │
                                      └──────────────┬──────────────┘
                                        schreibt bei jedem Tick
                                      ┌──────────────▼──────────────┐
                                      │ state.txt (<Zustand> <ms>)  │
                                      └──────────────┬──────────────┘
                                        liest bei jedem Bild neu
                                      ┌──────────────▼──────────────┐
                                      │ SignalAnimator.exe (C#)     │
                                      │ rendert Welle/Puls,         │
                                      │ ≤ 20 FPS (je nach Geräten), │
                                      │ 1 kurze Verbindung/Bild,    │
                                      │ überspringt unveränderte    │
                                      └──────────────┬──────────────┘
                                        SDK-Streaming, Port 6742
                                      ┌──────────────▼──────────────┐
                                      │ OpenRGB.exe --server        │
                                      │ (persistent, gepinnt 1.0rc3.1)│
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
Installationsort zeigen), deployt das Overlay, lädt bei Bedarf die gepinnte
stabile OpenRGB-Version 1.0rc3.1 automatisch herunter und kompiliert
`SignalAnimator.exe` neu aus `SignalAnimator.cs` (mit dem in jedem .NET
Framework mitgelieferten `csc.exe` — keine zusätzliche Abhängigkeit). Der
OpenRGB-Download wird sicher getauscht: erst komplett in einen separaten
Ordner herunterladen und entpacken, dort verifizieren, **erst dann** die
alte Installation ersetzen — schlägt der Download fehl oder bricht ab,
bleibt die bisherige (funktionierende) Installation unangetastet unter
`<LOCALAPPDATA>\ClaudeSignal\tools\OpenRGB\` stehen; nicht fatal, die
Geräte-Kopplung bleibt in dem Fall einfach inaktiv, der Rest der
Installation läuft normal durch. Räumt außerdem alle Effektdateien
früherer Versionen aus `Documents\WhirlwindFX\Effects` auf, falls noch
vorhanden.

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
  herunter). `SignalAnimator.exe` wird ebenfalls automatisch kompiliert —
  `csc.exe` gehört zu jeder Windows-.NET-Framework-Installation dazu, keine
  separate Installation nötig.

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
  OpenRGB-Server und `SignalAnimator.exe` beim ersten Start selbst, lautlos
  im Hintergrund.
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
- **Farben/Effekte anpassen:** normalerweise per `config.json`, siehe
  „Farben & Effekte anpassen" oben (kein Neukompilieren nötig). Wer die
  Effekt-Mathematik selbst erweitern will (neue Effekttypen o. Ä.):
  `SignalAnimator.cs` (Funktion `BuildFrame`) editieren, dann
  `bash ~/.claude/claude-signal/install.sh` erneut ausführen (kompiliert
  neu). Läuft bereits eine ältere Animator-Version, meldet `install.sh` das
  und du startest sie einmal manuell neu (`Stop-Process -Name
  SignalAnimator`).

## Troubleshooting

**RGB-Geräte reagieren nicht oder zeigen keine Animation:**
- Steht die Tastatur (bei Turtle Beach Vulcan II) auf Profil 1?
- Existiert
  `<LOCALAPPDATA>\ClaudeSignal\tools\OpenRGB\OpenRGB Windows 64-bit\OpenRGB.exe`?
  Falls nicht: `install.sh` erneut ausführen (lädt OpenRGB nach) oder es
  manuell von https://openrgb.org besorgen und dorthin entpacken.
- Läuft der Prozess `OpenRGB` (Taskmanager)? Er startet automatisch mit der
  nächsten neuen Claude-Session — bei Bedarf eine neue Session öffnen; das
  Overlay prüft außerdem alle ~10 s selbst nach und startet ihn bei Bedarf
  neu, ohne auf eine neue Session zu warten.
- Läuft der Prozess `SignalAnimator`? Genauso automatischer (Neu-)Start —
  er beendet sich zudem bewusst nach 10 Minuten durchgehendem Leerlauf
  (keine Session) und wird bei Bedarf vom Overlay wieder hochgefahren.
- **`<LOCALAPPDATA>\ClaudeSignal\animator.log`** ist die erste Anlaufstelle:
  zeigt Verbindungsstatus, erkannte Geräte samt LED-Zahl, Zustandswechsel und
  Fehler (überlebt einen Neustart des Animators, auf die letzten ~200 Zeilen
  begrenzt).
- Läuft SignalRGB oder Swarm II noch parallel? Beenden — beide kämpfen mit
  OpenRGB um dieselben Geräte.

**Limit-Zustand wird nicht erkannt (Anzeige bleibt bei „arbeitet"/„wartet"
statt auf die gelbe Welle zu wechseln):** Schau in
`<LOCALAPPDATA>\ClaudeSignal\notifications.log`, welcher Text beim
tatsächlichen Limit-Ereignis ankam, und gleiche ihn mit dem Muster in
`report-status.sh` ab (Abschnitt „Notification-Nachricht klassifizieren").
Passt der Text nicht zu den bisherigen Stichwörtern, das Muster dort
ergänzen — gerne auch als Rückmeldung/Issue, damit der Standard für alle
passt.

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
- Die Geräte-Kopplung setzt OpenRGB voraus und funktioniert mit jedem dort
  unterstützten Gerät. Frühere Fehlversuche mit OpenRGB lagen am aktiven
  Tastatur-Profil (4 statt 1) sowie an einem Absturz-Bug im Nightly-Build
  (siehe Update 10 im Spec-Dokument) — nicht an OpenRGB selbst; die gepinnte
  stabile Version 1.0rc3.1 umgeht beides.
- Der SDK-Streaming-Kanal öffnet für jedes Bild pro angesteuertem Gerät eine
  kurzlebige, frische TCP-Verbindung statt einer dauerhaften — eine
  dauerhafte Verbindung wird von OpenRGB nach 1–2 Paketen sauber
  geschlossen (kein Absturz, aber kein Streaming). Der Verbindungsaufbau
  über Loopback dauert unter 1 ms. Bei sehr vielen Geräten gleichzeitig
  (z. B. `AllRgbDevices` mit vielen Zonen) wird die Bildrate pro Gerät
  automatisch gedrosselt, damit die Gesamt-Verbindungsrate 40/Sekunde nicht
  übersteigt (Port-Erschöpfung vorbeugen) — unveränderte Bilder werden
  zusätzlich übersprungen (nur ~1×/s Lebenszeichen im Ruhezustand).
- `SignalAnimator.exe` beendet sich nach 10 Minuten durchgehendem Leerlauf
  selbst (Ressourcen sparen) und wird vom Overlay bei Bedarf automatisch neu
  gestartet (spätestens nach ~10 s) — kurzzeitig läuft dadurch keine
  Geräte-Kopplung, das ist beabsichtigt und unkritisch.

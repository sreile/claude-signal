# Claude-Ampel — Design-Spezifikation

**Datum:** 2026-09-01
**Status:** Vom Nutzer freigegeben

## Ziel

Ein schwebendes Windows-Overlay (farbiger Punkt, „Ampel"), das den Zustand aller
laufenden Claude-Code-Sessions (in WSL2) anzeigt:

| Farbe | Bedeutung |
|---|---|
| 🟡 Gelb | Mindestens eine Session wartet auf den Nutzer (Berechtigung/Eingabe) |
| 🔴 Rot | Sonst: mindestens eine Session arbeitet gerade |
| 🟢 Grün | Sonst: mindestens eine Session offen, alle fertig/untätig |
| ⚪ Grau | Keine (lebende) Session |

**Priorität bei Konflikt:** Gelb > Rot > Grün > Grau. Gelb gewinnt, weil
„wartet auf dich" die einzige Info ist, auf die der Nutzer reagieren kann.

## Architektur

Drei Einheiten, verbunden über Statusdateien im Windows-Dateisystem:

```
Claude Code Hooks (WSL)                Windows
┌──────────────────────┐   schreibt   ┌─────────────────────────────┐
│ report-status.sh     │ ───────────► │ %LOCALAPPDATA%\ClaudeAmpel\ │
│ (pro Hook-Ereignis)  │              │   sessions\<id>.status      │
└──────────────────────┘              └──────────────┬──────────────┘
                                            pollt alle 500 ms
                                      ┌──────────────▼──────────────┐
                                      │ ClaudeAmpel.ps1 (WPF)       │
                                      │ aggregiert → färbt Punkt    │
                                      └─────────────────────────────┘
```

### 1. Hook-Skript (WSL): `~/.claude/ampel/report-status.sh`

Aufruf: `report-status.sh <status>` mit `<status>` ∈ `working | waiting | done | start | end`.
Liest das Hook-JSON von stdin und extrahiert `session_id`.

- `start` → schreibt `done`-Status **und** startet das Overlay, falls es nicht läuft
  (Start detached via `powershell.exe`, damit der Hook sofort zurückkehrt).
- `end` → löscht die Statusdatei der Session.
- sonst → schreibt `<status> <unix-timestamp>` in `sessions/<session_id>.status`.

**Robustheit:** Das Skript darf Claude nie blockieren oder Fehler hochreichen —
alle Fehler werden verschluckt, Exit-Code immer 0. Ist `/mnt/c` nicht
erreichbar, tut es nichts.

### 2. Hook-Konfiguration: `~/.claude/settings.json`

| Hook-Ereignis | Aufruf |
|---|---|
| `SessionStart` | `report-status.sh start` |
| `UserPromptSubmit` | `report-status.sh working` |
| `PreToolUse` (matcher `*`) | `report-status.sh working` (refresht Zeitstempel) |
| `PostToolUse` (matcher `*`) | `report-status.sh working` |
| `Notification` | `report-status.sh waiting` |
| `Stop` | `report-status.sh done` |
| `SessionEnd` | `report-status.sh end` |

Die bestehenden Einträge in `settings.json` (permissions, statusLine, plugins, …)
bleiben unverändert; es kommt nur der `hooks`-Block hinzu.

### 3. Overlay (Windows): `%LOCALAPPDATA%\ClaudeAmpel\ClaudeAmpel.ps1`

PowerShell + WPF, keine Installation nötig.

- Randloses, transparentes Always-on-top-Fenster mit einem Kreis (~28 px),
  Startposition oben rechts.
- Timer pollt alle 500 ms den `sessions\`-Ordner und aggregiert nach der
  Prioritätsregel oben.
- **Stale-Erkennung:** Eine `working`-Datei, deren Zeitstempel älter als
  60 Minuten ist, gilt als abgestürzte Session und wird ignoriert
  (Tool-Aufrufe refreshen den Zeitstempel laufend, daher ist 60 min großzügig).
  Dateien älter als 24 h werden gelöscht.
- Per Maus verschiebbar; Position wird in `%LOCALAPPDATA%\ClaudeAmpel\config.json`
  gespeichert und beim Start wiederhergestellt.
- Tooltip beim Hover: Zusammenfassung, z.B. „2 Sessions: 1 arbeitet, 1 fertig".
- Rechtsklick beendet das Overlay.
- **Einzelinstanz:** Lock über eine benannte Mutex; ein zweiter Start beendet
  sich sofort still.
- Läuft mit `-WindowStyle Hidden`, kein Konsolenfenster.

## Fehlerbehandlung

- Hook-Seite: niemals blockieren, niemals Fehler melden (siehe oben).
- Overlay-Seite: Lesefehler einzelner Dateien (z.B. Schreibkollision) werden
  ignoriert — nächster Poll in 500 ms korrigiert es.
- Kaputte/leere Statusdateien zählen nicht in die Aggregation.

## Bekannte Grenzen (bewusst akzeptiert)

- Ein einzelner Tool-Aufruf, der länger als 60 min läuft, würde als „stale"
  gelten und der Punkt fiele ggf. auf Grau/Grün zurück — in der Praxis selten.
- Sessions, die hart abstürzen, hinterlassen bis zur Stale-/24h-Bereinigung
  eine Datei; `done`-Leichen zeigen bis dahin Grün statt Grau.
- Gilt für alle Sessions dieses WSL-Users; mehrere Distros/Windows-User sind
  außerhalb des Umfangs.

## Test

1. **Overlay isoliert:** Statusdateien von Hand anlegen/ändern
   (`working`/`waiting`/`done`, verschiedene Kombinationen, stale Zeitstempel)
   und Farbe + Tooltip prüfen. Grau bei leerem Ordner.
2. **Hook-Skript isoliert:** Mit Beispiel-JSON auf stdin aufrufen, Dateiinhalte
   prüfen; Verhalten bei fehlendem `/mnt/c`-Ziel prüfen (kein Fehler, Exit 0).
3. **Ende-zu-Ende:** Neue Claude-Session starten → Overlay erscheint grau→grün,
   Prompt senden → rot, Berechtigungsfrage → gelb, fertig → grün,
   Session beenden → grau.

## Erweiterung (2026-09-01): Tastatur-Backend über SignalRGB

Zusätzlich zum Bildschirm-Overlay schaltet die Ampel die RGB-Tastatur
(Turtle Beach Vulcan II, `10F5:501B`) über SignalRGB-Deep-Links um.

**Vom Nutzer festgelegtes Farbschema (weicht bewusst von der Ampel-Metapher ab):**

| Interner Zustand | SignalRGB-Effekt | Optik |
|---|---|---|
| `yellow` (wartet auf Nutzer) | `Ampel Rot Puls` | rot, kräftig pulsierend |
| `red` (arbeitet) | `Ampel Blau Puls` | blau mit Lauf-/Atemeffekt |
| `green` (fertig) | `Ampel Gruen` | grün, konstant |
| `gray` (keine Session) | `Ampel Blau` | ruhiges Blau, konstant |

**Mechanik:**
- Die vier Effekte sind eigene HTML-Effektdateien; Quelle im Repo unter
  `signalrgb-effects/`, installiert nach `Documents\WhirlwindFX\Effects\`.
  SignalRGB liest neue Effektdateien erst nach einem Neustart ein.
- `ClaudeAmpel.ps1` feuert bei jedem Farbwechsel (nur bei Änderung)
  `signalrgb://effect/apply/<Effektname>` per `Start-Process`.
- Guard: Deep-Link nur, wenn der Prozess `SignalRgb` läuft — sonst würde der
  Protokoll-Handler SignalRGB ungewollt starten.
- Fehler beim Umschalten werden verschluckt (Overlay darf nie sterben).

**Betriebsvoraussetzungen (README-Pflicht):**
- Die Tastatur MUSS auf Onboard-**Profil 1** stehen (FN+F1) — nur dort gibt die
  Firmware die LED-Kontrolle an Software frei (auf Profil 2–4 ignoriert sie alles).
- SignalRGB muss laufen (Autostart empfohlen); Swarm II darf nicht parallel
  laufen, sonst kämpfen beide um die Beleuchtung.

**Update (2026-09-01, nach Nutzer-Feedback):** Der Overlay-Punkt zeigt dasselbe
Farbschema wie die Tastatur — dunkles Blau = keine Session, helles Blau =
arbeitet, Rot = wartet auf Nutzer, Grün = fertig (siehe Update 2: ohne Session
wird der Punkt ausgeblendet). Die interne Zustandslogik
(gray/red/yellow/green in `Get-AmpelState`) bleibt unverändert; nur die
Anzeige-Hexwerte in `$colorMap` wurden getauscht.

**Update 2 (2026-09-01):** Der Punkt pulsiert analog zur Tastatur (hellblau
sanft ~1,4 s bei „arbeitet", rot kräftig ~0,8 s bei „wartet") und wird ohne
Session komplett ausgeblendet (Fensterlebenszyklus über Dispatcher::Run statt
ShowDialog, damit Hide() die App nicht beendet).

**Update 3 (2026-09-01):** Fünfter Zustand `waitingbusy`: Hook-Events von
Hintergrund-Agenten (erkennbar am Feld `agent_id` im Hook-JSON) dürfen ein
`waiting` nie überschreiben — sie werten es zu `waitingbusy` auf. Anzeige:
Tastatur „Ampel Rot Lauf" (rote Laufwelle ~1,0 s), Punkt rot schnell pulsierend.
Aggregat: wartet irgendeine Session UND arbeitet irgendetwas (working oder
waitingbusy) → `yellowbusy`; reines Warten → `yellow`. Aufgelöst wird Warten
nur durch Hauptketten-Events (working/done/end), nie durch Agenten.

**Update 4 (2026-09-01):** Die Effektdateien dürfen KEIN `<!doctype html>`,
kein `<meta charset>` und keinen `<style>`-Block enthalten — SignalRGBs
Effekt-Indexer lehnt solche Dateien ab („Failed to open …, because it isn't
installed", empirisch bewiesen). Format bleibt bewusst das schlichte
`<html><head><title>…` der Erstversion; Quirks-Mode-Rendering ist dort korrekt.

**Update 5 (2026-09-01):** Zusätzlicher `PostToolUse`-Hook (→ `working`):
Beantwortet der Nutzer eine Frage, feuert das Tool-Ergebnis sofort PostToolUse
und löst das Warte-Rot im Moment des Absendens auf — statt erst beim nächsten
Tool-Aufruf (der bei langen Denkphasen Minuten später kommen kann). Die
agent_id-Schutzlogik gilt unverändert: PostToolUse von Hintergrund-Agenten
kann ein Warten weiterhin nur zu `waitingbusy` aufwerten, nie löschen.

**Update 6 (2026-09-01):** Umbenennung Claude-Ampel → **claude-signal** (Dateien:
ClaudeSignal.ps1, Signal.Logic.ps1; Windows-Ordner ClaudeSignal; Effekte
„Claude Blau/Blau Puls/Gruen/Rot Puls/Rot Lauf"; Mutex ClaudeSignalSingleton).
Portabilisierung: install.sh erkennt LOCALAPPDATA/Documents zur Installationszeit
(PowerShell + wslpath) und schreibt sie nach `signal.env`; report-status.sh liest
diese Datei — keine hartkodierten Benutzerpfade mehr. install.sh entfernt beim
Registrieren veraltete Hook-Einträge (alter Pfad/Name). Verteilung als privates
GitHub-Repo sreile/claude-signal.

**Update 7 (2026-09-01):** Deep-Links abgeschafft — sie holten SignalRGBs
Fenster manchmal ungefragt in den Vordergrund (auch nach dem Auto-Verstecken
aus Update 6 bei weiteren Tests noch unzuverlässig/störend). Die
REST-API-Alternative ist Pro-only (403 bei kostenloser Lizenz), daher neuer
Ansatz: `ClaudeSignal.ps1` schreibt den aggregierten Zustand bei jedem Tick
(alle 500 ms) zusätzlich in `state.txt` neben den Statusdateien, Format
`<zustand> <epochMs>` (epochMs = Unix-Zeit in Millisekunden). Ein einziger,
dauerhaft installierter SignalRGB-Effekt „Claude Signal" pollt diese Datei
selbst per XHR (`file://…/state.txt?nc=<cachebuster>`, alle ~600 ms) und
rendert seinen Zustand direkt — kein Effektwechsel mehr nötig, SignalRGBs
Fenster wird nie mehr angefasst. Zeitgeber-Pflicht: **ausschließlich
`requestAnimationFrame`** — `setInterval` wird von SignalRGBs Renderer
gedrosselt (empirisch erhärtet: die bisherigen Wellen-Effekte liefen
zuverlässig, weil sie bereits rAF nutzten). Ist `state.txt` älter als 10 s
(Overlay beendet/abgestürzt), fällt der Effekt selbständig auf Grau zurück.
`install.sh` generiert die Effektdatei aus der Vorlage
`signalrgb-effects/Claude Signal.html.template` (Platzhalter `{{STATE_URL}}`
→ der echte `file:///…/ClaudeSignal/state.txt`-Pfad, aus dem zur
Installationszeit erkannten `%LOCALAPPDATA%` gebildet: Backslashes → `/`,
Leerzeichen → `%20`) und entfernt beim Deploy die fünf alten Einzel-Effekte
sowie Testartefakte, falls noch vorhanden.

**Update 8 (2026-09-01):** v4 — OpenRGB statt SignalRGB. Grund: Der
SignalRGB-Effekt aus Update 7 lief in einer Sandbox, die Datei- und
HTTP-Zugriffe blockiert (kein `state.txt`-Lesen möglich, Deep-Links poppten
weiterhin gelegentlich ein Fenster). Durchbruch: OpenRGB steuert die Turtle
Beach Vulcan II sehr wohl — alle früheren Fehlschläge lagen daran, dass die
Tastatur auf Onboard-Profil 4 statt Profil 1 stand (Software-LED-Kontrolle
gibt die Firmware nur auf Profil 1 frei), plus an späteren Testläufen gegen
eine zwischenzeitlich gelöschte OpenRGB-Programmdatei (Phantomläufe). Live
verifiziert: ein persistenter `OpenRGB.exe --server --startminimized
--device 0 --mode direct --color <hex>` hält die Farbe; ein zweiter,
wegwerfbarer Client-Aufruf `OpenRGB.exe --device 0 --mode direct --color
<hex>` verbindet sich automatisch zum laufenden Server und schaltet die
Farbe lautlos um — kein Fenster, kein Popup. `ClaudeSignal.ps1` startet den
Server einmalig beim Hochfahren (falls kein `OpenRGB`-Prozess läuft) und
schickt danach bei jedem Tick einen Wegwerf-Aufruf; ein `lastKbSent`-Guard
unterdrückt redundante Aufrufe bei unverändertem Zustand. `state.txt` und
der selbst-pollende Effekt aus Update 7 sind komplett entfernt — der
`signalrgb-effects/`-Ordner entfällt. Neue Option `config.json` →
`{"AllRgbDevices": true}` färbt statt nur Gerät 0 (Tastatur) alle von
OpenRGB erkannten Geräte. Statt der bisherigen Wellen-/Puls-Animationen
(die OpenRGBs reine Farbsetz-Kommandozeile nicht kann) blinkt „wartet"
jetzt zwischen Zustandsfarbe und dunklem Rot: einmal pro Sekunde
(`yellow`), doppelt so schnell bei zusätzlich aktivem Hintergrund-Agenten
(`yellowbusy`). `install.sh` lädt den offiziellen Windows-Build automatisch
von der GitLab-CI (`master`-Pipeline-Artefakt) herunter und entpackt ihn
nach `%LOCALAPPDATA%\ClaudeSignal\tools\OpenRGB\`, falls noch nicht
vorhanden; schlägt der Download fehl, ist das nicht fatal (nur Warnung,
Geräte-Kopplung bleibt inaktiv). Beim Deploy werden zusätzlich alle
Effektdateien aus `Documents\WhirlwindFX\Effects` sowie veraltete
v3-Artefakte (`testsrv.ps1`, `state.txt` im Deploy-Ordner) entfernt, falls
vorhanden.

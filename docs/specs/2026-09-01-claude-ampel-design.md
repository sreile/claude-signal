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

**Update 9 (2026-09-01):** v4.1-Hotfix. Gemessen: ein OpenRGB-Client-Aufruf
lebt ca. 2,1 s — das 2-Hz-Blinken aus Update 8 (`yellowbusy`) spawnte damit
bis zu 11 gleichzeitige OpenRGB-Prozesse. Fix: Serialisierung auf maximal
einen In-Flight-Client (`$script:kbProc`, per `-PassThru`/`HasExited`
geprüft) — `Sync-Keyboard` (vormals `Set-KeyboardColor`) wird jetzt jeden
Tick mit der aktuell gewünschten Farbe aufgerufen; läuft noch ein Client,
verfällt der Wunsch einfach und der nächste Tick versucht es erneut
(„latest wins"). Blinken komplett entfernt, stattdessen statische Farben:
`yellowbusy` bekommt eine eigene Farbe (Orange `FF5A00`) statt geteiltem Rot
mit `yellow`, um beide Zustände weiterhin unterscheidbar zu halten. Der
Shutdown-Handback erzwingt die Ruhefarbe unabhängig von Busy-/Dedupe-Guard
(direkter `Start-Process`-Aufruf statt `Sync-Keyboard`).

**Update 10 (2026-09-01):** v5 — SDK-Streaming-Animator (C#), statische
Farben ersetzt durch echte Wellen-/Puls-Effekte. Nutzer-Verdikt: statische
Farben inakzeptabel, Effekte sind Pflicht.

*Protokoll-Verifikation (byte-genau, gegen den laufenden Server getestet):*
Handshake (Paket 40, Client-Version 1) → Server antwortet mit Server-Version;
effektiv = min(Client, Server) = 1. `SET_CLIENT_NAME` (50),
`REQUEST_CONTROLLER_COUNT` (0), `REQUEST_CONTROLLER_DATA` (1, Payload
Protokollversion) → Antwort-Blob byte-genau geparst (data_size, type, name,
vendor [ab Protokoll ≥1], description, version, serial, location, num_modes
+ active_mode + Modes [je 9× u32-Feld + Farben], num_zones + Zones [+
Matrix], num_leds, num_colors + Farben) — Parser konsumiert exakt
3297/3297 Byte ohne Rest. **Korrektur:** Turtle Beach Vulcan II hat **108
LEDs über Gerät 0**, nicht 109 wie ursprünglich angenommen (der Wert 109
war eine Verwechslung/Näherung aus SignalRGB-Erinnerung) — 108 ist der
empirisch verifizierte, byte-exakte Wert und dient als Parser-Abnahmetest.

*Kritischer Befund — nativer Absturz im Nightly-Build:* Senden eines
LED-Farbarrays über das Netzwerk-SDK (sowohl `RGBCONTROLLER_UPDATELEDS`,
1050, als auch `RGBCONTROLLER_UPDATEZONELEDS`, 1051) an dieses Gerät stürzt
den `master`-Pipeline-Nightly-Build von OpenRGB reproduzierbar ab
(Ausnahmecode `0xc0000005`, Modul `ucrtbase.dll`, **identischer
Faulting-Offset `0x0000000000065655` in 4 unabhängigen Reproduktionen** —
Windows Event Log, Quelle „Application Error"). Isolationstests: Handshake
allein, `SETCUSTOMMODE` (1100) allein, CLI-Aufruf
`OpenRGB.exe --device 0 --mode direct --color RRGGBB` (v4/v4.1s Mechanismus)
und einzelne `UPDATESINGLELED`-Pakete (1052) sind alle unauffällig; sowohl
1050 (sofort, ein Aufruf reicht) als auch 1051 (nach ~15–69 Frames Streaming,
unabhängig von der Bildrate 2–20 FPS) stürzen ab. Fazit: Bug im
Nightly-Build selbst, nicht im Client-Protokoll.

*Gegentest stabile Version 1.0rc3.1
(https://codeberg.org/OpenRGB/OpenRGB/releases/download/release_candidate_1.0rc3.1/OpenRGB_1.0rc3.1_Windows_64_5e81e26.zip):*
kein einziger Absturz über alle Testreihen (einmaliges `UPDATELEDS`,
`UPDATEZONELEDS` 60 s bei 20 FPS, `UPDATELEDS` 60 s bei 20 FPS) — Event-Log
zeigt durchgehend die Baseline-Anzahl an OpenRGB-Fehlereinträgen, keine
neuen. Stattdessen ein anderes, unkritisches Verhalten: Eine **dauerhafte**
Verbindung, auf der mehrere LED-Update-Pakete nacheinander gesendet werden,
wird vom Server nach 1–2 Paketen sauber geschlossen (`recv` liefert 0 Byte —
geordnetes FIN, kein Absturz, kein RST). Fix: für **jedes** Update-Paket
(pro Zone, pro Frame) eine frische, kurzlebige TCP-Verbindung
(Connect → Handshake → ein Paket senden → Close) statt einer einzigen
dauerhaften Verbindung. Ein voller Zyklus dauert über Loopback < 1 ms
(gemessen: >20.000 Zyklen in 15 s ohne Fehler) — für 20 FPS mit riesigem
Puffer ausreichend.

*Architektur:* `ClaudeSignal.ps1` schreibt (REINSTATED aus Update 7, atomar
per tmp+rename) den aggregierten Zustand nach `state.txt` und startet neben
dem OpenRGB-Server (jetzt ohne `--device/--mode/--color`, nur noch
`--server --startminimized`) zusätzlich `SignalAnimator.exe`. Der Animator
(C#, Ziel .NET Framework 4.0 / `csc.exe`-kompatible Syntax, `/target:winexe`
— kein Fenster) pollt `state.txt` alle ~200 ms, hält die Controller-/
Zonen-Struktur gecacht (nur bei Verbindungsverlust neu abgefragt) und
rendert bei jedem der 20 Frames/s (`Thread.Sleep(50)`) neue Farben pro LED:
`gray`/`green` konstant; `red` (arbeitet) als blaue Welle (`t/1400 mod 1`
Phase, Kosinus-Falloff Breite 0,35, plus globaler Atem-Faktor
`0,75+0,25·sin(t/900)`); `yellow` (wartet) als kräftiges Pulsieren
(`k=0,5+0,5·sin(t/127)`, Lerp `#3C0000→#E53935`); `yellowbusy` als schnellere
rote Welle (`t/1000 mod 1`, Basis `#280000`, Spitze `#FF1010`). `state.txt`
älter als 10 s → `gray` (Overlay beendet/abgestürzt). `config.json` →
`{"AllRgbDevices": true}` liest der Animator selbst (kein Umweg mehr über
das Overlay). Logging: `animator.log`, auf ~80 Zeilen begrenzt, bei jedem
nennenswerten Ereignis (Start, Verbindungsaufbau inkl. erkannter
LED-Zahl, Zustandswechsel, Fehler, Herzschlag alle 100 Frames) komplett neu
geschrieben — kein unbegrenztes Wachstum.

`install.sh` pinnt ab sofort OpenRGB **1.0rc3.1** (s.o.) statt des
Nightly-Builds, per Versions-Marker-Datei im Zielordner (erkennt und
ersetzt automatisch eine ältere/andere Installation dort) und kompiliert
`SignalAnimator.cs` mit dem im .NET Framework mitgelieferten `csc.exe`
(keine neue Abhängigkeit; nicht fatal, falls `csc.exe` fehlt). Die
`state.txt`-Bereinigung aus Update 8 entfällt — die Datei ist wieder ein
aktiv genutzter Kommunikationskanal, kein Altlast mehr.

**Update 11 (2026-09-01):** v5.1-Härtung nach unabhängiger Review, empirisch
verifiziert.

*Kritisch:*
- **Port-Erschöpfungsrisiko bei `AllRgbDevices`** (viele Zonen × 20 FPS
  hätte >136 Verbindungen/s erzeugen können — Risiko für systemweite
  Ephemeral-Port-Erschöpfung). Fix, alle drei zusammen: (a) Umstieg von
  Paket 1051 (`UPDATEZONELEDS`, pro Zone) auf **1050** (`UPDATELEDS`, ein
  Paket pro Controller/Frame) — weniger Verbindungen, einfacherer Code,
  behebt nebenbei einen Offset-Parsing-Bug in der Zonen-Slicing-Logik;
  1050 war im eigenen Stabil-Build-Test bereits 60 s bei 20 FPS
  absturzfrei verifiziert. (b) Byte-identische Frames werden pro Controller
  übersprungen (gecachtes letztes Bild + Zeitstempel), nur bei Änderung
  oder nach 1 s Keepalive erneut gesendet — ruhende Zustände (grau/grün)
  fallen dadurch auf ~1 Verbindung/s. Live gemessen (isoliert vom
  produktiven Overlay, das parallel dieselbe state.txt beschreibt hätte):
  Baseline-TIME_WAIT-Bestand blieb über 2 Minuten Leerlauf stabil; ein
  gezieltes 11-Sekunden-Fenster zeigte genau 10 neue TIME_WAIT-Einträge
  (≈0,9/s) statt der ~20/s vor dem Fix. (c) Gesamt-Bildrate an die Zahl der
  angesteuerten Controller gekoppelt gedeckelt: `fps = clamp(40/n, 1, 20)`,
  damit Controller × FPS ≤ 40/s bleibt, auch wenn jeder Frame tatsächlich
  neu ist (Animationszustand bei vielen Geräten).
- **install.sh riss die funktionierende OpenRGB-Installation vor einem
  fehlschlagfähigen Download ab** (`rm -rf` vor dem Download; ein
  Fehlschlag hätte mit `set -e` den Installer mitten im kaputten
  Zwischenzustand abgebrochen — gar kein OpenRGB mehr vorhanden). Fix:
  Download/Entpacken in `tools/OpenRGB.new`, dort verifizieren (Existenz
  der .exe), **erst danach** tauschen (alt → `.old`, `.new` → aktiv); das
  Entfernen von `.old` toleriert Fehlschlag (`|| true`, z. B. gesperrte
  Datei einer noch laufenden Instanz) ohne den Installer abzubrechen.

*Wichtig (alle in `SignalAnimator.cs`, sofern nicht anders vermerkt):*
Singleton-Mutex-Bug behoben (`WaitOne` wurde nicht in jedem Pfad
aufgerufen); `UPDATELEDS`-`data_size` zählt jetzt korrekt sich selbst mit
(4 + Rest, vorher fehlte das eigene Feld); `state.txt`-Lesen nutzt
`FileShare.ReadWrite | FileShare.Delete` (verhindert gelegentliches
Scheitern des atomaren Move-Item-Renames im Overlay); Log-Datei wird beim
Start fortgeschrieben statt gelöscht (auf ~200 Zeilen getrimmt), Herzschlag
nur noch alle ~30 s; `ClaudeSignal.ps1` verschiebt die
Server-/Animator-Absicherung in den Tick (1. Tick sofort, danach alle 20
Ticks ≈ 10 s) statt nur einmal beim Start — beide werden dadurch neu
gestartet, falls sie über Nacht sterben; der Animator selbst beendet sich
nach 10 Minuten durchgehendem Grau bewusst (Ressourcen sparen), die
Tick-Überwachung holt ihn bei Bedarf zurück; Antwortgrößen über 4 MB werden
abgelehnt; ein „hängt in alter Farbe fest"-Schutz erzwingt Grau, wenn
`state.txt` aus irgendeinem Grund dauerhaft nicht lesbar ist; `install.sh`
prüft jetzt vor dem Kompilieren, ob eine alte Animator-Instanz die .exe
sperrt (bessere Fehlermeldung statt kryptischem `csc`-Fehler — live
reproduziert: der produktive, durch die eigenen Hooks dieser Session
gestartete Animator sperrte die Datei tatsächlich); läuft OpenRGB noch von
einem alten/anderen Binärpfad, weist `install.sh` darauf hin, dass ein
manueller Neustart nötig ist, statt den Prozess selbst zu beenden.

*Klein:* Antworten überspringen unerwartete Pakete (z. B.
`DEVICE_LIST_UPDATED`) bis zum erwarteten Paket; `ORGB`-Magic wird auf
Empfangsseite geprüft; Verbindungsaufbau nutzt `BeginConnect` mit echtem
2-s-Timeout statt blockierendem `Connect`; die Animationsuhr läuft über
`Stopwatch` (monoton) statt `DateTime.UtcNow`; Log-Zeitstempel tragen ein
„Z"-Suffix (bleiben UTC); Header und Payload werden in einem `Write`
gesendet, `NoDelay=true` (kein Nagle-Delay).

*Live-Verifikation:* `csc /warn:4 /warnaserror /langversion:5` auf einer
Kopie kompiliert warnungsfrei. Der gehärtete Animator lief gegen den
laufenden stabilen Server, Log zeigt weiterhin 108 LEDs für Gerät 0; alle
fünf Zustände durchlaufen sauber (isoliert vom produktiven Overlay
getestet, das parallel dieselbe `state.txt` beschreibt — eine anfängliche
Testrunde ohne Isolation zeigte genau dieses Race, kein Fehler im
Animator). 10-Minuten-Leerlaufende mit einer temporären 30-s-Konstante
verifiziert (Log: „Leerlauf-Ende … -- beende mich", Prozess anschließend
beendet); der Commit selbst verwendet die reguläre 10-Minuten-Konstante.

**Update 12 (2026-09-02):** v6 — Farben/Effekte pro Zustand über
`config.json` konfigurierbar (Block `States` neben `Left`/`Top`/
`AllRgbDevices`), mit sicheren Fallbacks auf die bisherigen fest
verdrahteten Werte. Schema pro Zustand (`working`/`waiting`/`waitingbusy`/
`done`/`idle`, Abbildung auf die internen Zustände red/yellow/yellowbusy/
green/gray): `effect` (`solid`/`pulse`/`wave`), `color` (nur `solid`),
`from`/`to` (nur `pulse`/`wave`), optional `period_ms` und (nur `wave`)
`breath`. Die Standardwerte entsprechen exakt dem Verhalten vor v6 (inkl.
der Herleitung `divisor = period_ms/(2π)` aus den bisherigen
`sin(t/127)`/`sin(t/64)`-Konstanten für `waiting`/`waitingbusy` → 800/400 ms).

*SignalAnimator.cs:* echtes JSON-Parsing über `JavaScriptSerializer`
(`System.Web.Extensions`, GAC-Bestandteil jeder .NET-4.x-Installation —
`install.sh` ergänzt `/r:System.Web.Extensions.dll` beim Kompilieren) statt
des bisherigen naiven String-Checks. Jeder Zustand wird einzeln validiert
(Pflichtfelder, Hex-Format `#RRGGBB`/`RRGGBB`, `period_ms` zwischen 50 und
60000, `effect` bekannt) — ein ungültiger Zustand fällt NUR für sich selbst
auf den eingebauten Standard zurück und wird geloggt
(„Konfiguration: Zustand '…' ungültig -- Standard verwendet"), der Rest der
Konfiguration bleibt wirksam; eine komplett unlesbare/kaputte `config.json`
bedeutet: alle Zustände auf Standard. Die Renderer wurden generalisiert
(`BuildFrame` liest ein aufgelöstes `StateConfig` pro Zustand statt fest
verdrahteter Werte); `pulse` nutzt `k = 0,5 + 0,5·sin(t·2π/period_ms)`,
`wave` die bestehende Lauflicht-/Falloff-Mathematik mit `from`/`to`/
`period_ms`, `breath` optional als Multiplikator. Live-Reload: die
Hauptschleife prüft alle ~5 s `File.GetLastWriteTimeUtc(config.json)`; bei
Änderung wird neu geparst und geloggt („Konfiguration neu geladen"); ändert
sich dabei `AllRgbDevices`, wird zusätzlich eine volle Geräte-Neuabfrage
ausgelöst (`RefreshControllers`).

*ClaudeSignal.ps1:* Der Bildschirm-Punkt übernimmt beim Start (nicht
live) `to`/`color` aus `config.json` als Zielfarbe für `$colorMap`, sofern
gültig (`ConvertTo-SignalHex`, akzeptiert `#RRGGBB`/`RRGGBB`) — ungültige/
fehlende Einträge lassen den bisherigen Standard stehen. Die
Puls-Zeittakte des Punkts selbst bleiben absichtlich fest verdrahtet
(nur der Animator bekommt echte Perioden-/Effekt-Konfiguration).

*Live-Verifikation:* `csc /warn:4 /warnaserror /langversion:5
/r:System.Web.Extensions.dll` auf einer Kopie kompiliert warnungsfrei.
Isoliert vom produktiven Overlay getestet (siehe Update 11 zur Race-
Problematik): ohne `States`-Block verhält sich der Animator identisch zu
vorher (Log zeigt Standardwerte); mit einer benutzerdefinierten
`config.json` (u. a. `done` als `solid #8000FF`, `waiting` als `pulse` mit
`period_ms: 300`) übernimmt der Animator die Werte sichtbar (Log bestätigt
Annahme); absichtlich kaputte Einzeleinträge (ungültiges Hex, unbekannter
`effect`-Wert) lösen den Pro-Zustand-Fallback aus, ohne den Prozess zu
gefährden; eine Änderung an `config.json` während des Laufs wird binnen
~5 s übernommen („Konfiguration neu geladen" im Log).

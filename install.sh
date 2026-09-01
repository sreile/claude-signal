#!/usr/bin/env bash
# Claude Signal installieren: Dateien nach Windows kopieren, Hooks registrieren.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Preflights zuerst, damit im Fehlerfall nichts halb deployt wird ---
command -v python3 >/dev/null || { echo "FEHLER: python3 fehlt"; exit 1; }

REPORT_SCRIPT="$SRC/report-status.sh"
[ -f "$REPORT_SCRIPT" ] || { echo "FEHLER: report-status.sh fehlt"; exit 1; }

# --- Windows-Pfade zur Installationszeit erkennen (kein Hardcoding mehr) ---
PSEXE="$(command -v powershell.exe || echo /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe)"
[ -x "$PSEXE" ] || { echo "FEHLER: powershell.exe nicht gefunden ($PSEXE) — läuft das hier unter WSL mit Windows-Interop?"; exit 1; }
command -v wslpath >/dev/null || { echo "FEHLER: wslpath fehlt — läuft das hier unter WSL?"; exit 1; }

WIN_LOCAL="$(cd /mnt/c && "$PSEXE" -NoProfile -Command 'Write-Output $env:LOCALAPPDATA' | tr -d '\r')"
[ -n "$WIN_LOCAL" ] || { echo "FEHLER: konnte %LOCALAPPDATA% nicht ermitteln"; exit 1; }
WIN_DOCS="$(cd /mnt/c && "$PSEXE" -NoProfile -Command 'Write-Output ([Environment]::GetFolderPath("MyDocuments"))' | tr -d '\r')"
[ -n "$WIN_DOCS" ] || { echo "FEHLER: konnte das Dokumente-Verzeichnis nicht ermitteln"; exit 1; }

WSL_LOCAL="$(wslpath -u "$WIN_LOCAL")"
[ -n "$WSL_LOCAL" ] || { echo "FEHLER: wslpath konnte '$WIN_LOCAL' nicht auflösen"; exit 1; }
WSL_DOCS="$(wslpath -u "$WIN_DOCS")"
[ -n "$WSL_DOCS" ] || { echo "FEHLER: wslpath konnte '$WIN_DOCS' nicht auflösen"; exit 1; }

WIN_DIR="$WSL_LOCAL/ClaudeSignal"
EFF_DST="$WSL_DOCS/WhirlwindFX/Effects"
OVERLAY_WIN="$WIN_LOCAL\\ClaudeSignal\\ClaudeSignal.ps1"

[ -d "$(dirname "$WIN_DIR")" ] || { echo "FEHLER: $WIN_DIR nicht erreichbar (WSL-Mount?)"; exit 1; }

mkdir -p "$WIN_DIR/sessions"
cp "$SRC/ClaudeSignal.ps1" "$SRC/Signal.Logic.ps1" "$WIN_DIR/"
echo "Overlay-Dateien kopiert nach: $WIN_DIR"

# OpenRGB bereitstellen (Tastatur/Geräte-Backend, ersetzt SignalRGB komplett —
# lautlos, kein Fenster/Effekt-Sandbox). Nicht fatal: ohne OpenRGB läuft nur
# der Bildschirm-Punkt weiter (Guard in ClaudeSignal.ps1 lässt den RGB-Teil aus).
#
# WICHTIG: bewusst auf die stabile Version 1.0rc3.1 gepinnt, NICHT auf den
# "master"-Nightly-Build — der Nightly-Build stürzt beim SDK-Streaming
# reproduzierbar ab (0xc0000005 in ucrtbase.dll), siehe Update 10 im
# Spec-Dokument. Ein Versions-Marker sorgt dafür, dass ein zuvor installierter
# Nightly-Build automatisch durch die gepinnte stabile Version ersetzt wird.
ORGB_DIR="$WIN_DIR/tools/OpenRGB"
ORGB_EXE="$ORGB_DIR/OpenRGB Windows 64-bit/OpenRGB.exe"
ORGB_VERSION="release_candidate_1.0rc3.1"
ORGB_URL="https://codeberg.org/OpenRGB/OpenRGB/releases/download/release_candidate_1.0rc3.1/OpenRGB_1.0rc3.1_Windows_64_5e81e26.zip"
ORGB_VERSION_FILE="$ORGB_DIR/.claude-signal-version"

orgb_up_to_date=0
if [ -f "$ORGB_EXE" ] && [ -f "$ORGB_VERSION_FILE" ] && [ "$(cat "$ORGB_VERSION_FILE" 2>/dev/null)" = "$ORGB_VERSION" ]; then
  orgb_up_to_date=1
fi

if [ "$orgb_up_to_date" = 1 ]; then
  echo "OpenRGB bereit (gepinnt $ORGB_VERSION): $ORGB_EXE"
else
  # C2: NIE die alte, funktionierende Installation vor der Verifikation der
  # neuen löschen. Erst nach ".new" laden/entpacken/prüfen, dann tauschen —
  # ein rm -rf auf eine laufende .exe kann fehlschlagen und würde mit set -e
  # den ganzen Installer mitten im Umbau abbrechen (kaputter Zwischenzustand,
  # gar kein OpenRGB mehr vorhanden).
  ORGB_DIR_NEW="${ORGB_DIR}.new"
  ORGB_EXE_NEW="$ORGB_DIR_NEW/OpenRGB Windows 64-bit/OpenRGB.exe"
  rm -rf "$ORGB_DIR_NEW"
  mkdir -p "$WIN_DIR/tools" "$ORGB_DIR_NEW"

  if curl -sL -o "$WIN_DIR/tools/openrgb.zip" "$ORGB_URL" \
     && python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
' "$WIN_DIR/tools/openrgb.zip" "$ORGB_DIR_NEW" \
     && [ -f "$ORGB_EXE_NEW" ]; then
    # Neue Version verifiziert vorhanden -- jetzt erst der eigentliche Tausch.
    ORGB_DIR_OLD="${ORGB_DIR}.old"
    rm -rf "$ORGB_DIR_OLD"
    [ -d "$ORGB_DIR" ] && mv "$ORGB_DIR" "$ORGB_DIR_OLD"
    mv "$ORGB_DIR_NEW" "$ORGB_DIR"
    echo "$ORGB_VERSION" > "$ORGB_VERSION_FILE"
    echo "OpenRGB bereit (gepinnt $ORGB_VERSION): $ORGB_EXE"
    # Alte Version aufräumen -- ein Fehlschlag hier (z. B. weil eine laufende
    # .exe aus diesem Ordner die Datei sperrt) ist NICHT fatal, siehe I8 unten.
    rm -rf "$ORGB_DIR_OLD" 2>/dev/null || true
  else
    echo "WARNUNG: OpenRGB konnte nicht heruntergeladen/entpackt werden — Geräte-Kopplung bleibt inaktiv, der Rest der Installation läuft normal weiter."
    rm -rf "$ORGB_DIR_NEW"
  fi
  rm -f "$WIN_DIR/tools/openrgb.zip"
fi

# I8: Läuft OpenRGB noch von einem anderen/alten Binärpfad (z. B. weil der
# Tausch gerade eben passiert ist), wirkt der Pin erst nach einem Neustart —
# der Installer beendet den Prozess NICHT selbst.
ORGB_RUNNING_PATH="$("$PSEXE" -NoProfile -Command \
  "(Get-Process -Name OpenRGB -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path)" \
  | tr -d '\r')"
if [ -n "$ORGB_RUNNING_PATH" ]; then
  ORGB_RUNNING_PATH_WSL="$(wslpath -u "$ORGB_RUNNING_PATH" 2>/dev/null || echo "")"
  if [ -n "$ORGB_RUNNING_PATH_WSL" ] && [ "$ORGB_RUNNING_PATH_WSL" != "$ORGB_EXE" ]; then
    echo "HINWEIS: OpenRGB läuft noch von einem anderen Pfad ($ORGB_RUNNING_PATH) — für die gepinnte Version einmal manuell neu starten (Stop-Process -Name OpenRGB; das Overlay startet den Server danach automatisch neu)."
  fi
fi

# SignalAnimator kompilieren (C#, SDK-Streaming über OpenRGB Port 6742).
# csc.exe kommt mit jedem .NET Framework mit — keine zusätzliche Abhängigkeit.
CSC="/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
[ -f "$CSC" ] || CSC="/mnt/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
if [ -f "$CSC" ]; then
  # I7: VOR dem Kompilieren prüfen, ob eine alte Instanz noch läuft — die
  # sperrt die .exe-Datei unter Windows, was den Build sonst mit einer
  # verwirrenden Fehlermeldung scheitern lässt.
  ANIM_RUNNING="$("$PSEXE" -NoProfile -Command \
    "if (Get-Process -Name SignalAnimator -ErrorAction SilentlyContinue) { Write-Output yes } else { Write-Output no }" \
    | tr -d '\r')"

  cp "$SRC/SignalAnimator.cs" "$WIN_DIR/"
  if ( cd /mnt/c && "$CSC" /nologo /target:winexe \
         /out:"$(wslpath -w "$WIN_DIR/SignalAnimator.exe")" \
         "$(wslpath -w "$WIN_DIR/SignalAnimator.cs")" ); then
    echo "Animator kompiliert: $WIN_DIR/SignalAnimator.exe"
    if [ "$ANIM_RUNNING" = "yes" ]; then
      echo "HINWEIS: SignalAnimator läuft noch mit der vorherigen Version — für die neue Datei einmal manuell neu starten (Stop-Process -Name SignalAnimator; das Overlay startet ihn danach automatisch neu)."
    fi
  else
    if [ "$ANIM_RUNNING" = "yes" ]; then
      echo "WARNUNG: SignalAnimator-Kompilierung fehlgeschlagen — vermutlich sperrt die laufende Instanz die Datei. Einmal beenden (Stop-Process -Name SignalAnimator) und install.sh erneut ausführen."
    else
      echo "WARNUNG: SignalAnimator-Kompilierung fehlgeschlagen — Animationen deaktiviert (nur Overlay-Punkt)."
    fi
  fi
else
  echo "WARNUNG: csc.exe nicht gefunden — Animationen deaktiviert (nur Overlay-Punkt)."
fi

# signal.env schreiben — report-status.sh liest daraus zur Laufzeit, statt
# Windows-Pfade hartzukodieren. Macht das Repo portabel (kein Nutzername mehr im Code).
cat > "$SRC/signal.env" <<ENV
CLAUDE_SIGNAL_WIN_DIR="$WIN_DIR"
CLAUDE_SIGNAL_OVERLAY_WIN="$OVERLAY_WIN"
ENV
echo "signal.env geschrieben: $SRC/signal.env"

# Veraltete Artefakte früherer Versionen entfernen: v2 (Einzel-Effekte je Zustand),
# v3 (selbst-pollender Effekt + state.txt-Kanal), Testdateien. EFF_DST/WhirlwindFX
# existiert auf frischen Rechnern u.U. gar nicht (mehr) — dann einfach überspringen.
if [ -d "$EFF_DST" ]; then
  for obsolete in "Claude Blau.html" "Claude Blau Puls.html" "Claude Gruen.html" \
                  "Claude Rot Puls.html" "Claude Rot Lauf.html" "Claude Signal Probe.html" \
                  "Claude Signal.html" "Claude Signal Debug.html"; do
    if [ -f "$EFF_DST/$obsolete" ]; then
      rm -f "$EFF_DST/$obsolete"
      echo "Veraltete Effektdatei entfernt: $EFF_DST/$obsolete"
    fi
  done
fi
for obsolete in "testsrv.ps1"; do
  if [ -f "$WIN_DIR/$obsolete" ]; then
    rm -f "$WIN_DIR/$obsolete"
    echo "Veraltete Datei entfernt: $WIN_DIR/$obsolete"
  fi
done

export CLAUDE_SIGNAL_SCRIPT="$REPORT_SCRIPT"

python3 - <<'PY'
import json, os, re, time

path = os.path.expanduser('~/.claude/settings.json')
with open(path) as f:
    settings = json.load(f)

script = os.environ['CLAUDE_SIGNAL_SCRIPT']
events = {
    'SessionStart': 'start',
    'UserPromptSubmit': 'working',
    'PreToolUse': 'working',
    'PostToolUse': 'working',
    'Notification': 'waiting',
    'Stop': 'done',
    'SessionEnd': 'end',
}

existing_hooks = settings.get('hooks', {})
stale_re = re.compile(r'report-status\.sh')

# Durchlauf 1: nur ermitteln, was fehlt. Keine Mutation von `settings`.
to_add = []
for event, arg in events.items():
    command = f'bash "{script}" {arg}'
    entries = existing_hooks.get(event, [])
    exists = any(h.get('command') == command
                 for e in entries for h in e.get('hooks', []))
    if not exists:
        entry = {'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}
        if event in ('PreToolUse', 'PostToolUse'):
            entry['matcher'] = '*'
        to_add.append((event, entry))

# Durchlauf 2: veraltete report-status.sh-Einträge finden (alter Pfad/Name nach
# Repo-Umzug oder Umbenennung) — jeder Eintrag, der auf report-status.sh zeigt,
# aber nicht dem aktuellen Kommando entspricht. Noch keine Mutation.
new_hooks = {}
removed = 0
for event, entries in existing_hooks.items():
    new_command = f'bash "{script}" {events.get(event, "")}'
    kept_entries = []
    for e in entries:
        hlist = e.get('hooks', [])
        kept_hooks = []
        for h in hlist:
            cmd = h.get('command', '')
            if stale_re.search(cmd) and cmd != new_command:
                removed += 1
                continue
            kept_hooks.append(h)
        if kept_hooks:
            e2 = dict(e)
            e2['hooks'] = kept_hooks
            kept_entries.append(e2)
    new_hooks[event] = kept_entries

if not to_add and removed == 0:
    print('Hooks: 0 neu eingetragen, 0 entfernt (nichts geändert)')
else:
    # Backup des ORIGINAL geparsten Inhalts, mit Kollisionsschutz.
    ts = time.strftime('%Y%m%d%H%M%S')
    backup = f"{path}.bak.{ts}"
    n = 0
    while os.path.exists(backup):
        n += 1
        backup = f"{path}.bak.{ts}-{n}"
    with open(backup, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write('\n')

    settings['hooks'] = new_hooks
    hooks = settings['hooks']
    for event, entry in to_add:
        hooks.setdefault(event, []).append(entry)

    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write('\n')
    os.replace(tmp, path)
    print(f'Hooks: {len(to_add)} neu eingetragen, {removed} entfernt, Backup: {backup}')
PY

echo "Fertig. Hooks gelten für NEUE Claude-Sessions (laufende Sessions laden sie nicht nach)."

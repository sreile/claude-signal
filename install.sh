#!/usr/bin/env bash
# Claude Signal installieren: Dateien nach Windows kopieren, Hooks registrieren.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Preflights zuerst, damit im Fehlerfall nichts halb deployt wird ---
command -v python3 >/dev/null || { echo "FEHLER: python3 fehlt"; exit 1; }

REPORT_SCRIPT="$SRC/report-status.sh"
[ -f "$REPORT_SCRIPT" ] || { echo "FEHLER: report-status.sh fehlt"; exit 1; }

TEMPLATE="$SRC/signalrgb-effects/Claude Signal.html.template"
[ -f "$TEMPLATE" ] || { echo "FEHLER: $TEMPLATE fehlt"; exit 1; }

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

# signal.env schreiben — report-status.sh liest daraus zur Laufzeit, statt
# Windows-Pfade hartzukodieren. Macht das Repo portabel (kein Nutzername mehr im Code).
cat > "$SRC/signal.env" <<ENV
CLAUDE_SIGNAL_WIN_DIR="$WIN_DIR"
CLAUDE_SIGNAL_OVERLAY_WIN="$OVERLAY_WIN"
ENV
echo "signal.env geschrieben: $SRC/signal.env"

# SignalRGB-Effekt aus Vorlage generieren: {{STATE_URL}} durch den echten
# file://-Pfad von state.txt ersetzen (aus dem erkannten %LOCALAPPDATA%).
# Der Effekt pollt state.txt danach selbst — kein Effektwechsel/Deep-Link mehr.
url_local="${WIN_LOCAL//\\//}"
url_local="${url_local// /%20}"
STATE_URL="file:///${url_local}/ClaudeSignal/state.txt"

mkdir -p "$EFF_DST"
GENERATED="$(mktemp)"
trap 'rm -f "$GENERATED"' EXIT
STATE_URL="$STATE_URL" TEMPLATE_PATH="$TEMPLATE" OUT_PATH="$GENERATED" python3 - <<'PY'
import os

with open(os.environ['TEMPLATE_PATH'], 'r', encoding='utf-8') as f:
    content = f.read()
content = content.replace('{{STATE_URL}}', os.environ['STATE_URL'])
with open(os.environ['OUT_PATH'], 'w', encoding='utf-8') as f:
    f.write(content)
PY

DEST_EFFECT="$EFF_DST/Claude Signal.html"
changed=0
cmp -s "$GENERATED" "$DEST_EFFECT" 2>/dev/null || changed=1
cp "$GENERATED" "$DEST_EFFECT"
rm -f "$GENERATED"
trap - EXIT
echo "SignalRGB-Effekt generiert: $DEST_EFFECT"
if [ "$changed" = 1 ]; then
  echo "HINWEIS: Effektdatei neu/geändert — SignalRGB einmal neu starten, damit es sie einliest."
fi

# Veraltete Einzel-Effekte aus der Deep-Link-Ära (v2) und Testartefakte
# entfernen, falls noch von einer älteren Installation vorhanden.
for obsolete in "Claude Blau.html" "Claude Blau Puls.html" "Claude Gruen.html" \
                "Claude Rot Puls.html" "Claude Rot Lauf.html" "Claude Signal Probe.html"; do
  if [ -f "$EFF_DST/$obsolete" ]; then
    rm -f "$EFF_DST/$obsolete"
    echo "Veraltete Effektdatei entfernt: $EFF_DST/$obsolete"
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

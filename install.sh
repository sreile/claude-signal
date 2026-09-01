#!/usr/bin/env bash
# Claude Signal installieren: Dateien nach Windows kopieren, Hooks registrieren.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Preflights zuerst, damit im Fehlerfall nichts halb deployt wird ---
command -v python3 >/dev/null || { echo "FEHLER: python3 fehlt"; exit 1; }

REPORT_SCRIPT="$SRC/report-status.sh"
[ -f "$REPORT_SCRIPT" ] || { echo "FEHLER: report-status.sh fehlt"; exit 1; }

ls "$SRC/signalrgb-effects/"*.html >/dev/null 2>&1 || { echo "FEHLER: keine Effektdateien in $SRC/signalrgb-effects"; exit 1; }

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

# SignalRGB-Effekte installieren (Quelle: Repo). Neustart-Hinweis nur bei Änderung.
mkdir -p "$EFF_DST"
changed=0
for f in "$SRC/signalrgb-effects/"*.html; do
  base=$(basename "$f")
  cmp -s "$f" "$EFF_DST/$base" || changed=1
  cp "$f" "$EFF_DST/"
done
echo "SignalRGB-Effekte kopiert nach: $EFF_DST"
if [ "$changed" = 1 ]; then
  echo "HINWEIS: Effektdateien neu/geändert — SignalRGB einmal neu starten, damit es sie einliest."
fi

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

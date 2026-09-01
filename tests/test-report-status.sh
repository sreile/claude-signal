#!/usr/bin/env bash
# Tests für report-status.sh — nutzt CLAUDE_SIGNAL_DIR-Override, braucht kein /mnt/c.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/report-status.sh"
TMP=$(mktemp -d)/"signal dir mit Leerzeichen"
mkdir -p "$TMP"
trap 'rm -rf "$(dirname "$TMP")"' EXIT
fails=0

check() { # name erwartet bekommen
  if [ "$2" = "$3" ]; then echo "ok - $1"
  else echo "FAIL - $1: erwartet '$2', bekommen '$3'"; fails=$((fails+1)); fi
}

run() { # status json — ruft das Skript wie ein Hook auf
  printf '%s' "$2" | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" "$1"
}

JSON='{"session_id":"abc-123","hook_event_name":"Stop","cwd":"/home/x"}'

# 1) working schreibt Statusdatei mit aktuellem Zeitstempel
run working "$JSON"
check "working: Exit 0" "0" "$?"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "working: Status" "working" "${line%% *}"
ts="${line##* }"; now=$(date +%s)
if [ "$ts" -ge $((now - 5)) ] 2>/dev/null && [ "$ts" -le "$now" ]; then
  echo "ok - working: Zeitstempel aktuell"
else
  echo "FAIL - working: Zeitstempel '$ts' nicht aktuell"; fails=$((fails+1))
fi

# 2) waiting überschreibt
run waiting "$JSON"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "waiting: Status" "waiting" "${line%% *}"

# 3) start schreibt done (Spawn per CLAUDE_SIGNAL_NO_SPAWN unterdrückt)
run start "$JSON"
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "start: Status done" "done" "${line%% *}"

# 4) end löscht die Datei
run end "$JSON"
[ -e "$TMP/sessions/abc-123.status" ] && { echo "FAIL - end: Datei existiert noch"; fails=$((fails+1)); } || echo "ok - end: Datei gelöscht"

# 5) Session-ID wird bereinigt (Pfad-Injection unmöglich)
run working '{"session_id":"../evil/../x"}'
[ -e "$TMP/sessions/evilx.status" ] && echo "ok - Session-ID bereinigt" || { echo "FAIL - Session-ID-Bereinigung"; fails=$((fails+1)); }
[ -e "$TMP/evil" ] && { echo "FAIL - Pfad-Injection möglich!"; fails=$((fails+1)); } || echo "ok - keine Pfad-Injection"

# 6) Müll auf stdin → Exit 0, keine Datei
before=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
printf 'kein json' | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
check "Müll-stdin: Exit 0" "0" "$?"
after=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
check "Müll-stdin: keine Datei" "$before" "$after"

# 7) fehlende session_id → Exit 0, keine neue Datei
before=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
printf '{"foo":"bar"}' | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
check "ohne session_id: Exit 0" "0" "$?"
after=$(ls "$TMP/sessions" 2>/dev/null | wc -l)
check "ohne session_id: keine Datei" "$before" "$after"

# 8) Zielordner-Elternteil fehlt (simuliert fehlendes /mnt/c) → Exit 0, nichts angelegt.
#    CLAUDE_SIGNAL_DIR ist explizit gesetzt (Override) — auch wenn neben dem Skript
#    eine signal.env läge, MUSS der Override gewinnen (Prioritätsreihenfolge in
#    report-status.sh: CLAUDE_SIGNAL_DIR vor CLAUDE_SIGNAL_WIN_DIR aus signal.env).
printf '%s' "$JSON" | CLAUDE_SIGNAL_DIR="/nonexistent-$$/signal" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
check "fehlendes Ziel: Exit 0" "0" "$?"
[ -d "/nonexistent-$$" ] && { echo "FAIL - hat /nonexistent-$$ angelegt"; fails=$((fails+1)); } || echo "ok - fehlendes Ziel: nichts angelegt"

# 9) unbekannter Status → Exit 0, keine Datei
printf '%s' "$JSON" | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" quatsch
check "unbekannter Status: Exit 0" "0" "$?"
[ -e "$TMP/sessions/abc-123.status" ] && { echo "FAIL - unbekannter Status schrieb Datei"; fails=$((fails+1)); } || echo "ok - unbekannter Status: keine Datei"

# 10) Hintergrund-Agent darf waiting nicht überschreiben -> waitingbusy
run waiting "$JSON"
printf '%s' '{"session_id":"abc-123","agent_id":"a1","tool_name":"Bash"}' | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
line=$(cat "$TMP/sessions/abc-123.status" 2>/dev/null || echo FEHLT)
check "Agent auf waiting: waitingbusy" "waitingbusy" "${line%% *}"

# 11) Hintergrund-Agent auf waitingbusy: bleibt waitingbusy
printf '%s' '{"session_id":"abc-123","agent_id":"a1"}' | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
line=$(cat "$TMP/sessions/abc-123.status")
check "Agent auf waitingbusy: bleibt" "waitingbusy" "${line%% *}"

# 12) Hauptkette working löst waiting/waitingbusy auf
run working "$JSON"
line=$(cat "$TMP/sessions/abc-123.status")
check "Hauptkette working: löst auf" "working" "${line%% *}"

# 13) Hintergrund-Agent auf working: bleibt working (nur Refresh)
printf '%s' '{"session_id":"abc-123","agent_id":"a1"}' | CLAUDE_SIGNAL_DIR="$TMP" CLAUDE_SIGNAL_NO_SPAWN=1 bash "$SCRIPT" working
line=$(cat "$TMP/sessions/abc-123.status")
check "Agent auf working: working" "working" "${line%% *}"
run end "$JSON"

# 14) Ohne signal.env UND ohne CLAUDE_SIGNAL_DIR-Override: stiller No-op (Exit 0,
#     keine Datei irgendwo). Dafür eine isolierte Kopie von report-status.sh in
#     ein frisches Verzeichnis ohne signal.env legen, damit BASH_SOURCE dorthin zeigt.
ISO=$(mktemp -d)
cp "$SCRIPT" "$ISO/report-status.sh"
before_home=$(find "$HOME" -maxdepth 1 -name '*.status' 2>/dev/null | wc -l)
printf '%s' "$JSON" | env -u CLAUDE_SIGNAL_DIR -u CLAUDE_SIGNAL_WIN_DIR bash "$ISO/report-status.sh" working
check "ohne signal.env/Override: Exit 0" "0" "$?"
after_home=$(find "$HOME" -maxdepth 1 -name '*.status' 2>/dev/null | wc -l)
check "ohne signal.env/Override: nichts im HOME angelegt" "$before_home" "$after_home"
[ -e "$ISO/sessions" ] && { echo "FAIL - hat sessions/ im Iso-Verzeichnis angelegt"; fails=$((fails+1)); } || echo "ok - ohne signal.env/Override: keine sessions/ angelegt"
rm -rf "$ISO"

if [ "$fails" -eq 0 ]; then echo "ALLE TESTS OK"; exit 0
else echo "$fails TEST(S) FEHLGESCHLAGEN"; exit 1; fi

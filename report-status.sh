#!/usr/bin/env bash
# Claude Signal: schreibt den Session-Status für das Windows-Overlay.
# Aufruf durch Claude-Code-Hooks: report-status.sh <start|end|working|waiting|done>
# Hook-JSON kommt auf stdin. Darf NIEMALS fehlschlagen oder blockieren.

main() {
  local status="${1:-}"

  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$script_dir/signal.env" ] && . "$script_dir/signal.env"
  local win_dir="${CLAUDE_SIGNAL_DIR:-${CLAUDE_SIGNAL_WIN_DIR:-}}"
  [ -n "$win_dir" ] || return 0
  local sessions_dir="$win_dir/sessions"
  local ps_exe="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe"
  local cmd_exe="/mnt/c/WINDOWS/System32/cmd.exe"
  local overlay_win="${CLAUDE_SIGNAL_OVERLAY_WIN:-}"

  # Ohne Windows-Mount (oder falschem Override-Pfad) still aussteigen,
  # sonst würde mkdir -p Verzeichnisse im WSL-Rootfs anlegen.
  [ -d "$(dirname "$win_dir")" ] || return 0

  local input session_id
  [ -t 0 ] && return 0
  input=$(timeout 2 cat) || return 0
  session_id=$(printf '%s' "$input" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
    | sed 's/.*"\([^"]*\)"$/\1/')
  session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
  [ -n "$session_id" ] || return 0

  local from_agent=0
  printf '%s' "$input" | grep -q '"agent_id"' && from_agent=1

  case "$status" in
    start)
      mkdir -p "$sessions_dir" || return 0
      printf 'done %s\n' "$(date +%s)" > "$sessions_dir/$session_id.status"
      if [ -z "${CLAUDE_SIGNAL_NO_SPAWN:-}" ] && [ -n "$overlay_win" ] && [ -x "$ps_exe" ] && [ -x "$cmd_exe" ]; then
        # Overlay detached starten; beendet sich selbst, wenn schon eine Instanz läuft.
        ( cd /mnt/c && setsid nohup "$cmd_exe" /c start "" \
            powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
            -File "$overlay_win" ) >/dev/null 2>&1 &
      fi
      ;;
    end)
      rm -f "$sessions_dir/$session_id.status"
      ;;
    working|waiting|done)
      mkdir -p "$sessions_dir" || return 0
      local new_status="$status" current=""
      if [ "$status" = "working" ] && [ "$from_agent" = "1" ]; then
        current=$(head -c 32 "$sessions_dir/$session_id.status" 2>/dev/null | cut -d' ' -f1)
        case "$current" in waiting|waitingbusy) new_status="waitingbusy" ;; esac
      fi
      printf '%s %s\n' "$new_status" "$(date +%s)" > "$sessions_dir/$session_id.status"
      ;;
  esac
  return 0
}

main "$@" >/dev/null 2>&1 || true
exit 0

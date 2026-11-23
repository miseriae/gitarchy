#!/bin/bash

# Resolve the cwd of the tmux pane shown by the given tmux client pid
tmux_client_pane_cwd() {
  local client_pid="$1"
  local socket_dir socket client session tty cwd line

  [[ $client_pid =~ ^[0-9]+$ ]] || return 1
  [[ -r /proc/$client_pid/environ ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1

  socket_dir=$(tr '\0' '\n' <"/proc/$client_pid/environ" 2>/dev/null |
    sed -n 's/^TMUX_TMPDIR=//p' | head -n1)
  socket_dir="${socket_dir:-/tmp}/tmux-$(id -u)"

  for socket in "$socket_dir"/*; do
    [[ -S $socket ]] || continue

    # Keep the client's tty along with its session: in a session with several
    # attached clients, display-message -t <session> resolves the session's
    # active pane, which is not necessarily the pane this client is viewing.
    client=$(tmux -S "$socket" list-clients \
      -F '#{client_pid}|#{client_tty}|#{client_session}' 2>/dev/null |
      awk -F'|' -v pid="$client_pid" '$1 == pid { print $2 "|" $3; exit }')
    [[ -n $client ]] || continue

    tty=${client%%|*}
    session=${client#*|}
    cwd=""
    if [[ -n $tty ]]; then
      cwd=$(tmux -S "$socket" display-message -p -c "$tty" \
        -F '#{pane_current_path}' 2>/dev/null) || cwd=""
    fi
    if [[ -z $cwd && -n $session ]]; then
      cwd=$(tmux -S "$socket" display-message -p -t "$session" \
        -F '#{pane_current_path}' 2>/dev/null) || cwd=""
    fi
    if [[ -n $cwd && -d $cwd ]]; then
      printf '%s\n' "$cwd"
      return 0
    fi
  done

  return 1
}

# Resolve the cwd of the tmux pane attached to the given terminal pid. Walks
# the terminal's children and resolves the first tmux client found
terminal_tmux_pane_cwd() {
  local terminal_pid="$1"
  local child grandchild cwd

  for child in $(pgrep -P "$terminal_pid" 2>/dev/null); do
    cwd=$(tmux_client_pane_cwd "$child") && {
      printf '%s\n' "$cwd"
      return 0
    }
    for grandchild in $(pgrep -P "$child" 2>/dev/null); do
      cwd=$(tmux_client_pane_cwd "$grandchild") && {
        printf '%s\n' "$cwd"
        return 0
      }
    done
  done

  return 1
}

main() {
  local terminal_pid="${1:-}" cwd shell_pid shell kitty_socket kitty_json
  local window_pid tmux_cwd children_file child stat session tty_nr

  if [[ -z $terminal_pid ]]; then
    command -v jq >/dev/null 2>&1 &&
      terminal_pid=$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid // empty')
    if [[ -z $terminal_pid ]]; then
      terminal_pid=$(hyprctl activewindow 2>/dev/null | awk '/pid:/ {print $2; exit}')
    fi
  fi
  [[ $terminal_pid =~ ^[0-9]+$ ]] || return 0

  kitty_socket="$XDG_RUNTIME_DIR/omarchy-kitty-$terminal_pid"
  cwd=""

  if [[ -S $kitty_socket ]] && command -v kitten >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    kitty_json=$(kitten @ --to "unix:$kitty_socket" ls --match "state:focused" 2>/dev/null)
    # The focused tab and its focused window, not every tab in the OS window
    cwd=$(jq -r 'first(.[].tabs[] | select(.is_focused) | .windows[] | select(.is_focused) | .cwd) // empty' <<<"$kitty_json")
    window_pid=$(jq -r 'first(.[].tabs[] | select(.is_focused) | .windows[] | select(.is_focused) | .pid) // empty' <<<"$kitty_json")
    if [[ -z $cwd ]]; then
      # Older kitty JSON without is_focused: take the first window
      cwd=$(jq -r 'first(.[].tabs[].windows[].cwd) // empty' <<<"$kitty_json")
      window_pid=$(jq -r 'first(.[].tabs[].windows[].pid) // empty' <<<"$kitty_json")
    fi
    if [[ -n $window_pid ]]; then
      tmux_cwd=$(terminal_tmux_pane_cwd "$window_pid")
      [[ -n $tmux_cwd ]] && cwd=$tmux_cwd
    fi
  fi

  if [[ -z $cwd ]]; then
    cwd=$(terminal_tmux_pane_cwd "$terminal_pid")
  fi

  if [[ -z $cwd ]]; then
    # The newest child that leads its own session on a terminal pty is the
    # terminal's shell. A child any other app spawned (a browser's download
    # helper, say) is not a session leader and must not claim the cwd.
    shell_pid=""
    for children_file in /proc/"$terminal_pid"/task/*/children; do
      [[ -r $children_file ]] || continue
      read -ra children <"$children_file" || true
      for child in "${children[@]}"; do
        (( child > ${shell_pid:-0} )) && shell_pid=$child
      done
    done

    if [[ -n $shell_pid ]] && read -r stat 2>/dev/null <"/proc/$shell_pid/stat"; then
      read -r _ _ _ session tty_nr _ <<<"${stat##*) }"
      if (( session == shell_pid && tty_nr != 0 )); then
        cwd=$(readlink -f "/proc/$shell_pid/cwd" 2>/dev/null)
        shell=$(readlink -f "/proc/$shell_pid/exe" 2>/dev/null)
        grep -Fqsx "$shell" /etc/shells || cwd=""
      fi
    fi
  fi

  if [[ -d $cwd ]]; then
    printf '%s\n' "$cwd"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

#!/bin/bash

# Resolve the cwd of the tmux pane shown by the given tmux client pid
tmux_client_pane_cwd() {
  local client_pid="$1"
  local socket_dir socket session cwd line

  [[ $client_pid =~ ^[0-9]+$ ]] || return 1
  [[ -r /proc/$client_pid/environ ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1

  socket_dir=$(tr '\0' '\n' <"/proc/$client_pid/environ" 2>/dev/null |
    sed -n 's/^TMUX_TMPDIR=//p' | head -n1)
  socket_dir="${socket_dir:-/tmp}/tmux-$(id -u)"

  for socket in "$socket_dir"/*; do
    [[ -S $socket ]] || continue

    session=$(tmux -S "$socket" list-clients \
      -F '#{client_pid}|#{client_session}' 2>/dev/null |
      awk -F'|' -v pid="$client_pid" '$1 == pid { print $2; exit }')
    [[ -n $session ]] || continue

    cwd=$(tmux -S "$socket" display-message -p -t "$session" \
      -F '#{pane_current_path}' 2>/dev/null) || continue
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
  local terminal_pid cwd shell_pid shell kitty_socket kitty_json window_pid tmux_cwd

  terminal_pid=$(hyprctl activewindow | awk '/pid:/ {print $2}')
  kitty_socket="$XDG_RUNTIME_DIR/omarchy-kitty-$terminal_pid"
  cwd=""

  if [[ -S $kitty_socket ]]; then
    kitty_json=$(kitten @ --to "unix:$kitty_socket" ls --match "state:focused" 2>/dev/null)
    cwd=$(jq -r '.[].tabs[].windows[].cwd // empty' <<<"$kitty_json")
    window_pid=$(jq -r '.[].tabs[].windows[].pid // empty' <<<"$kitty_json" | head -n1)
    if [[ -n $window_pid ]]; then
      tmux_cwd=$(terminal_tmux_pane_cwd "$window_pid")
      [[ -n $tmux_cwd ]] && cwd=$tmux_cwd
    fi
  fi

  if [[ -z $cwd ]]; then
    cwd=$(terminal_tmux_pane_cwd "$terminal_pid")
  fi

  if [[ -z $cwd ]]; then
    shell_pid=$(pgrep -P "$terminal_pid" | tail -n1)

    if [[ -n $shell_pid ]]; then
      cwd=$(readlink -f "/proc/$shell_pid/cwd" 2>/dev/null)
      shell=$(readlink -f "/proc/$shell_pid/exe" 2>/dev/null)
      grep -Fqsx "$shell" /etc/shells || cwd=""
    fi
  fi

  if [[ -d $cwd ]]; then
    printf '%s\n' "$cwd"
  else
    printf '%s\n' "$HOME"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

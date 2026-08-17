.pragma library

// Expected output shape:
//   {"ok":true,"branch":"main","staged":1,"modified":2,"untracked":3,
//    "conflicts":0,"stash":1,"ahead":2,"behind":0,
//    "operation":"","detached":0,"unborn":0}
// Output on failure (not a repo, missing git, ...):
//   {"ok":false}
function statusScript() {
  return [
    'P="$1"',
    'cd "$P" 2>/dev/null || { printf \'{"ok":false}\\n\'; exit 0; }',
    'git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf \'{"ok":false}\\n\'; exit 0; }',
    'GD=$(git rev-parse --git-dir 2>/dev/null)',
    'B=$(git symbolic-ref --short HEAD 2>/dev/null)',
    'ST=$(git stash list 2>/dev/null | wc -l)',
    'AB=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0 0")',
    'BEHIND=${AB%%[[:space:]]*}',
    'AHEAD=${AB##*[[:space:]]}',
    'STAGED=0; MOD=0; UNT=0; CONF=0',
    'while IFS= read -r line; do',
    '  [ -z "$line" ] && continue',
    '  case "$line" in "??"*) UNT=$((UNT+1)); continue;; esac',
    '  X=${line:0:1}; Y=${line:1:1}',
    '  case "$X$Y" in "UU"|"AA"|"DD"|"AU"|"UA"|"DU"|"UD") CONF=$((CONF+1)); continue;; esac',
    '  case "$X" in " ") ;; *) STAGED=$((STAGED+1));; esac',
    '  case "$Y" in " ") ;; *) MOD=$((MOD+1));; esac',
    'done <<< "$(git status --porcelain=v1 2>/dev/null)"',
    'OP=""',
    '[ -n "$GD" ] || GD=".git"',
    '[ -f "$GD/MERGE_HEAD" ] && OP="merge"',
    '[ -d "$GD/rebase-merge" ] && OP="rebase"',
    '[ -d "$GD/rebase-apply" ] && OP="rebase"',
    '[ -f "$GD/CHERRY_PICK_HEAD" ] && OP="cherry-pick"',
    'git rev-parse --verify HEAD >/dev/null 2>&1; UNBORN=$([ $? -ne 0 ] && echo 1 || echo 0)',
    '[ -n "$B" ] || { DETACHED=1; B=$(git rev-parse --short HEAD 2>/dev/null); }',
    'DETACHED=${DETACHED:-0}',
    'printf \'{"ok":true,"branch":"%s","staged":%d,"modified":%d,"untracked":%d,"conflicts":%d,"stash":%d,"ahead":%d,"behind":%d,"operation":"%s","detached":%d,"unborn":%d}\\n\' "$B" "$STAGED" "$MOD" "$UNT" "$CONF" "$ST" "$AHEAD" "$BEHIND" "$OP" "$DETACHED" "$UNBORN"'
  ].join("\n")
}

function buildStatusCommand(path) {
  return ["bash", "-c", statusScript(), "gitarchy", String(path || "")]
}

// Bundled tmux-aware cwd resolver (see scripts/terminal-cwd.sh). Resolves the
// active terminal's working directory including changes inside tmux panes,
// which the stock omarchy-cmd-terminal-cwd misses
function bundledCwdCommand(scriptPath) {
  return [String(scriptPath || "")]
}

function parseStatus(raw) {
  var out = { ok: false, branch: "", staged: 0, modified: 0, untracked: 0, conflicts: 0, stash: 0, ahead: 0, behind: 0, operation: "", detached: false, unborn: false }
  var text = String(raw || "").trim()
  if (text === "") return out
  try {
    var data = JSON.parse(text)
    if (!data || data.ok !== true) return out
    out.ok = true
    out.branch = String(data.branch || "")
    out.staged = toInt(data.staged)
    out.modified = toInt(data.modified)
    out.untracked = toInt(data.untracked)
    out.conflicts = toInt(data.conflicts)
    out.stash = toInt(data.stash)
    out.ahead = toInt(data.ahead)
    out.behind = toInt(data.behind)
    out.operation = String(data.operation || "")
    out.detached = data.detached === 1
    out.unborn = data.unborn === 1
  } catch (e) {
    // fall through with ok:false
  }
  return out
}

function toInt(value) {
  var n = parseInt(value, 10)
  return isFinite(n) && n > 0 ? n : 0
}

// Total dirty files across every repo status object in a list
function totalDirty(statuses) {
  var total = 0
  if (!Array.isArray(statuses)) return 0
  for (var i = 0; i < statuses.length; i++) {
    var s = statuses[i]
    if (!s) continue
    total += (s.staged || 0) + (s.modified || 0) + (s.untracked || 0)
  }
  return total
}

// Name of the first repo that has a branch
function primaryBranch(statuses) {
  if (!Array.isArray(statuses)) return ""
  for (var i = 0; i < statuses.length; i++) {
    var s = statuses[i]
    if (s && s.branch) return s.branch
  }
  return ""
}

function repoName(path) {
  var parts = String(path || "").replace(/\/+$/, "").split("/")
  return parts.length > 0 ? parts[parts.length - 1] : String(path || "")
}

function barText(statuses, showBranch, showDirty) {
  var dirty = totalDirty(statuses)
  var branch = showBranch !== false ? primaryBranch(statuses) : ""
  var parts = []
  if (branch !== "") parts.push(branch)
  if (showDirty !== false && dirty > 0) parts.push("+" + dirty)

  // Conflict / in-progress markers come from the primary (focused/current)
  // repo when present, so the bar communicates "deal with this now"
  var s = statuses && statuses.length > 0 ? statuses[0] : null
  if (s) {
    if (s.conflicts > 0) parts.push("!" + s.conflicts)
    if (s.operation !== "") parts.push("· " + s.operation)
  }
  return parts.join(" ")
}

function barTooltip(statuses) {
  if (!Array.isArray(statuses) || statuses.length === 0) return "Gitarchy — no repos configured"
  var lines = []
  for (var i = 0; i < statuses.length; i++) {
    var s = statuses[i]
    if (!s) continue
    var name = s.name || repoName(s.path || "")
    var branch = s.branch || "?"
    var dirty = (s.staged || 0) + (s.modified || 0) + (s.untracked || 0)
    var counts = ""
    if (s.staged || s.modified || s.untracked)
      counts = " +" + s.staged + " ~" + s.modified + " -" + s.untracked
    var remote = (s.ahead || s.behind) ? " ↑" + s.ahead + " ↓" + s.behind : ""
    lines.push(name + "  " + branch + counts + remote + (s.stash ? " {" + s.stash + "}" : ""))
  }
  return lines.join("\n")
}

// Command to open lazygit in a repo path from a GUI click.
// mode "focus" (default): reuse/focus an open lazygit window (org.omarchy.lazygit).
// mode "floating": always open a new floating terminal (org.omarchy.terminal, floated by Hyprland rules)
function openLazygitCommand(path, mode) {
  if (mode === "floating")
    return "omarchy-launch-tui --app-id=org.omarchy.terminal lazygit -p " + shellQuote(path)
  return "omarchy-launch-or-focus-tui lazygit -p " + shellQuote(path)
}

// Open the repo's origin remote in the default browser (GitHub, GitLab, ...)
// Normalizes ssh/ssh+git remote URLs to https so xdg-open works everywhere
// Falls back to the folder when no remote exists
function openGitHubCommand(path) {
  return "url=$(git -C " + shellQuote(path) + " remote get-url origin 2>/dev/null); "
    + "case \"$url\" in "
    + "git@*:*|ssh://git@*|git+ssh://git@*|ssh://git@*/*) "
    + "  rest=${url#git@}; rest=${rest#ssh://git@}; rest=${rest#git+ssh://git@}; rest=${rest#ssh://}; "
    + "  rest=${rest/:/\/}; url=\"https://$rest\";; "
    + "esac; "
    + "url=${url%.git}; "
    + "if [[ -n $url ]]; then xdg-open \"$url\"; else xdg-open " + shellQuote(path) + "; fi"
}

// Copy the current branch name to the clipboard
function copyBranchCommand(path) {
  return "git -C " + shellQuote(path) + " branch --show-current 2>/dev/null | wl-copy"
}

// Open the repo in the file manager
function openFolderCommand(path) {
  return "xdg-open " + shellQuote(path)
}

function fetchCommand(path) {
  return "git -C " + shellQuote(path) + " fetch --all --prune"
}

function copyUrlCommand(path) {
  return "git -C " + shellQuote(path) + " remote get-url origin 2>/dev/null | wl-copy"
}

// gh command to view the current branch's PR. Run from inside the repo (the
// caller sets Process.workingDirectory to the repo path) — `gh pr view --repo`
// expects OWNER/REPO, not a filesystem path
function ghPrCommand() {
  return ["gh", "pr", "view", "--json", "number,title,state,url,headRefName", "--jq", ". | {number,title,state,url,headRefName}"]
}

function parsePr(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  try {
    var data = JSON.parse(text)
    if (!data || !data.number) return null
    return {
      number: data.number,
      title: String(data.title || ""),
      state: String(data.state || ""),
      url: String(data.url || ""),
      headRefName: String(data.headRefName || "")
    }
  } catch (e) {
    return null
  }
}

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

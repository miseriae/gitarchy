.pragma library

// Expected output shape:
//   {"ok":true,"branch":"main","root":"/path/to/repo","staged":1,"modified":2,
//    "untracked":3,"conflicts":0,"stash":1,"ahead":2,"behind":0,
//    "operation":"","detached":0,"unborn":0}
// Output on failure (not a repo, missing git/jq, ...):
//   {"ok":false}
//
// A single `git status --porcelain=v2 --branch` supplies the branch,
// upstream ahead/behind counts, and every file entry, so the one-second
// focused-repo refresh stays cheap. `root` is the work-tree top level, which
// is what rows are deduplicated and pinned by — the terminal's cwd may be a
// subdirectory of a watched repo.
function statusScript() {
  return [
    'P="$1"',
    'cd "$P" 2>/dev/null || { printf \'{"ok":false}\\n\'; exit 0; }',
    'git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf \'{"ok":false}\\n\'; exit 0; }',
    'command -v jq >/dev/null 2>&1 || { printf \'{"ok":false}\\n\'; exit 0; }',
    'ROOT=$(git rev-parse --show-toplevel 2>/dev/null)',
    'GD=$(git rev-parse --git-dir 2>/dev/null)',
    'ST=$(git stash list 2>/dev/null | wc -l)',
    'STATUS=$(git status --porcelain=v2 --branch --untracked-files=normal 2>/dev/null)',
    'STAGED=0; MOD=0; UNT=0; CONF=0; AHEAD=0; BEHIND=0; DETACHED=0; UNBORN=0',
    'B=""; OID=""; AB=""',
    'while IFS= read -r line; do',
    '  case "$line" in',
    '    "# branch.oid "*) OID=${line#"# branch.oid "} ;;',
    '    "# branch.head "*) B=${line#"# branch.head "} ;;',
    '    "# branch.ab "*) AB=${line#"# branch.ab "} ;;',
    '    "1 "*|"2 "*)',
    '      XY=${line:2:2}',
    '      X=${XY:0:1}; Y=${XY:1:1}',
    '      [ "$X" = "." ] || STAGED=$((STAGED+1))',
    '      [ "$Y" = "." ] || MOD=$((MOD+1))',
    '      ;;',
    '    "u "*) CONF=$((CONF+1)) ;;',
    '    "? "*) UNT=$((UNT+1)) ;;',
    '  esac',
    'done <<< "$STATUS"',
    'if [ "$OID" = "(initial)" ]; then',
    '  UNBORN=1',
    'elif [ "$B" = "(detached)" ]; then',
    '  DETACHED=1',
    '  B=${OID:0:7}',
    'fi',
    'if [ -n "$AB" ]; then',
    '  AHEAD=${AB#+}',
    '  AHEAD=${AHEAD%% *}',
    '  BEHIND=${AB##* }',
    '  BEHIND=${BEHIND#-}',
    'fi',
    'AHEAD=${AHEAD:-0}; BEHIND=${BEHIND:-0}',
    'OP=""',
    '[ -n "$GD" ] || GD=".git"',
    '[ -f "$GD/MERGE_HEAD" ] && OP="merge"',
    '[ -d "$GD/rebase-merge" ] && OP="rebase"',
    '[ -d "$GD/rebase-apply" ] && OP="rebase"',
    '[ -f "$GD/CHERRY_PICK_HEAD" ] && OP="cherry-pick"',
    '[ -f "$GD/REVERT_HEAD" ] && OP="revert"',
    '[ -f "$GD/BISECT_LOG" ] && OP="bisect"',
    'jq -cn --arg branch "$B" --arg root "$ROOT" --arg operation "$OP" \\',
    '  --argjson staged "$STAGED" --argjson modified "$MOD" --argjson untracked "$UNT" \\',
    '  --argjson conflicts "$CONF" --argjson stash "$ST" --argjson ahead "$AHEAD" \\',
    '  --argjson behind "$BEHIND" --argjson detached "$DETACHED" --argjson unborn "$UNBORN" \\',
    '  \'{ok:true,branch:$branch,root:$root,staged:$staged,modified:$modified,untracked:$untracked,conflicts:$conflicts,stash:$stash,ahead:$ahead,behind:$behind,operation:$operation,detached:$detached,unborn:$unborn}\''
  ].join("\n")
}

function buildStatusCommand(path) {
  return ["bash", "-c", statusScript(), "gitarchy", String(path || "")]
}

// Bundled tmux-aware cwd resolver (see scripts/terminal-cwd.sh). Resolves the
// active terminal's working directory including changes inside tmux panes,
// which the stock omarchy-cmd-terminal-cwd does not (yet). Run through bash so
// the checkout's executable bit is not required.
function bundledCwdCommand(scriptPath) {
  return ["bash", String(scriptPath || "")]
}

function parseStatus(raw) {
  var out = { ok: false, branch: "", root: "", staged: 0, modified: 0, untracked: 0, conflicts: 0, stash: 0, ahead: 0, behind: 0, operation: "", detached: false, unborn: false }
  var text = String(raw || "").trim()
  if (text === "") return out
  try {
    var data = JSON.parse(text)
    if (!data || data.ok !== true) return out
    out.ok = true
    out.branch = String(data.branch || "")
    out.root = String(data.root || "")
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

// Glanceable overall state for the bar label color: "urgent" when a repo needs
// user attention (conflicts or an in-progress operation), "accent" when there
// is uncommitted work, otherwise "neutral". The widget maps these to theme
// colors so the bar communicates status without extra text
function barState(statuses) {
  if (!Array.isArray(statuses)) return "neutral"
  for (var i = 0; i < statuses.length; i++) {
    var s = statuses[i]
    if (!s) continue
    if (s.conflicts > 0 || (s.operation && s.operation !== "")) return "urgent"
    if ((s.staged || 0) + (s.modified || 0) + (s.untracked || 0) > 0) return "accent"
  }
  return "neutral"
}

function barTooltip(statuses) {
  if (!Array.isArray(statuses) || statuses.length === 0) return "Gitarchy — no repos configured"
  var lines = []
  for (var i = 0; i < statuses.length; i++) {
    var s = statuses[i]
    if (!s) continue
    var name = s.name || repoName(s.root || s.path || "")
    var branch = s.branch || "?"
    var dirty = (s.staged || 0) + (s.modified || 0) + (s.untracked || 0)
    var counts = ""
    if (s.staged || s.modified || s.untracked)
      counts = " +" + s.staged + " ~" + s.modified + " ?" + s.untracked
    var remote = (s.ahead || s.behind) ? " ↑" + s.ahead + " ↓" + s.behind : ""
    lines.push(name + "  " + branch + counts + remote + (s.stash ? " {" + s.stash + "}" : ""))
  }
  return lines.join("\n")
}

// Command to open lazygit in a repo path from a GUI click.
// mode "focus" (default): reuse/focus an open lazygit window (org.omarchy.lazygit).
// mode "floating": always open a new floating terminal (org.omarchy.terminal,
// floated by Hyprland rules) and focus the newly created window
function openLazygitCommand(path, mode) {
  if (mode === "floating")
    return floatingLazygitCommand(path)
  return "omarchy-launch-or-focus-tui lazygit -p " + shellQuote(path)
}

function floatingLazygitCommand(path) {
  return "before=$(hyprctl clients -j 2>/dev/null | jq -r '.[].address'); "
    + "omarchy-launch-tui --app-id=org.omarchy.terminal lazygit -p " + shellQuote(path) + " >/dev/null 2>&1 & "
    + "for i in $(seq 1 40); do "
    + "address=$(hyprctl clients -j 2>/dev/null | jq -r --arg before \"$before\" 'first(.[] | . as $client | select($client.class == \"org.omarchy.terminal\") | select((($before | split(\"\\n\")) | index($client.address)) == null) | $client.address) // empty'); "
    + "if [[ -n \"$address\" ]]; then "
    + "hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$address\\\" })\" >/dev/null 2>&1 || hyprctl dispatch focuswindow \"address:$address\"; "
    + "break; fi; sleep 0.05; done"
}

// Open the repo's origin remote in the default browser (GitHub, GitLab, ...)
// Normalizes ssh/ssh+git remote URLs to https so the browser handles them,
// strips embedded credentials, and falls back to the folder when no remote
// exists
function openGitHubCommand(path) {
  return "url=$(git -C " + shellQuote(path) + " remote get-url origin 2>/dev/null); "
    + "case \"$url\" in "
    + "  git@*:*) rest=${url#git@}; host=${rest%%:*}; repo=${rest#*:}; url=\"https://$host/$repo\" ;; "
    + "  ssh://git@*|git+ssh://git@*) rest=${url#ssh://}; rest=${rest#git+ssh://}; "
    + "    if [[ $rest =~ ^git@([^/:]+)(:[0-9]+)?/(.*)$ ]]; then url=\"https://${BASH_REMATCH[1]}/${BASH_REMATCH[3]}\"; else url=\"\"; fi ;; "
    + "  git://*) url=\"https://${url#git://}\" ;; "
    + "esac; "
    + "if [[ $url =~ ^https?://[^/@]+@(.*)$ ]]; then url=\"https://${BASH_REMATCH[1]}\"; fi; "
    + "url=${url%.git}; "
    + "if [[ -n $url ]]; then omarchy-launch-browser \"$url\"; else xdg-open " + shellQuote(path) + "; fi"
}

function copyBranchCommand(path) {
  return "git -C " + shellQuote(path) + " branch --show-current 2>/dev/null | wl-copy"
}

function openFolderCommand(path) {
  return "xdg-open " + shellQuote(path)
}

// Actions run through Process so the panel can show a busy state and surface
// git's stderr; argv vectors avoid another shell parsing layer
function fetchCommand(path) {
  return ["git", "-C", String(path || ""), "fetch", "--all", "--prune"]
}

// Pull is fast-forward only so it never rewrites local history (safe default
// for a one-click action). Push uses the branch's existing upstream
function pullCommand(path) {
  return ["git", "-C", String(path || ""), "pull", "--ff-only"]
}

function pushCommand(path) {
  return ["git", "-C", String(path || ""), "push"]
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

// ---------------------------------------------------------------- repo lists

function expandHome(path, home) {
  var p = String(path || "")
  var h = String(home || "")
  if (p === "~") return h
  if (p.indexOf("~/") === 0 && h !== "") return h + p.substring(1)
  return p
}

function normalizeRepoPath(value, home) {
  var path = ""
  if (typeof value === "string") path = value.trim()
  else if (value && typeof value === "object" && value.path !== undefined) path = String(value.path).trim()
  if (path === "") return ""
  path = expandHome(path, home)
  if (path.length > 1) path = path.replace(/\/+$/, "")
  return path
}

function repoEntryName(value) {
  if (!value || typeof value !== "object" || value.name === undefined || value.name === null) return ""
  return String(value.name)
}

// Normalized view of the configured list: paths are trimmed, expanded, and
// deduplicated while each entry's display name is kept next to its path
function normalizeRepoList(list, home) {
  var out = []
  var seen = ({})
  if (!list || typeof list.length !== "number") return out
  for (var i = 0; i < list.length; i++) {
    var path = normalizeRepoPath(list[i], home)
    if (path === "" || seen[path] === true) continue
    seen[path] = true
    out.push({ path: path, name: repoEntryName(list[i]) })
  }
  return out
}

function repoDisplayName(list, path, root, home) {
  var targetPath = normalizeRepoPath(path, home)
  var targetRoot = normalizeRepoPath(root || path, home)
  var entries = normalizeRepoList(list, home)
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].path === targetPath || entries[i].path === targetRoot)
      return entries[i].name !== "" ? entries[i].name : repoName(entries[i].path)
  }
  // A watched subdirectory of this repo is still the same row; prefer its name
  for (var j = 0; j < entries.length; j++) {
    if (targetRoot !== "" && entries[j].path.indexOf(targetRoot + "/") === 0)
      return entries[j].name !== "" ? entries[j].name : repoName(entries[j].path)
  }
  return repoName(targetRoot || targetPath)
}

// Add a repo (by its canonical root) without disturbing existing entries or
// their display names. A repo already watched through one of its subdirectories
// counts as present.
function addRepo(list, path, home) {
  var next = Array.isArray(list) ? list.slice() : []
  var target = normalizeRepoPath(path, home)
  if (target === "") return next
  var entries = normalizeRepoList(next, home)
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].path === target || entries[i].path.indexOf(target + "/") === 0)
      return next
  }
  next.push(target)
  return next
}

// Remove every entry that names this repo or one of its subdirectories,
// leaving unrelated entries (and their objects) untouched
function removeRepo(list, path, root, home) {
  var next = []
  if (!Array.isArray(list)) return next
  var targetPath = normalizeRepoPath(path, home)
  var targetRoot = normalizeRepoPath(root || path, home)
  for (var i = 0; i < list.length; i++) {
    var entryPath = normalizeRepoPath(list[i], home)
    if (entryPath === "") continue
    if (entryPath === targetPath || entryPath === targetRoot) continue
    if (targetRoot !== "" && entryPath.indexOf(targetRoot + "/") === 0) continue
    next.push(list[i])
  }
  return next
}

// ------------------------------------------------------------- status lists

function statusKey(status) {
  if (!status) return ""
  return String(status.root || status.path || "")
}

// Current repo first (when it is a real repo), then watched repos, with rows
// deduplicated by work-tree root so a terminal inside a subdirectory of a
// watched repo does not appear twice or double-count in the bar
function mergeStatuses(current, statuses) {
  var out = []
  var seen = ({})
  if (current && current.ok) {
    var currentKey = statusKey(current)
    if (currentKey !== "") seen[currentKey] = true
    out.push(current)
  }
  if (!Array.isArray(statuses)) return out
  for (var i = 0; i < statuses.length; i++) {
    var status = statuses[i]
    if (!status) continue
    var key = statusKey(status)
    if (key !== "" && seen[key] === true) continue
    if (key !== "") seen[key] = true
    out.push(status)
  }
  return out
}

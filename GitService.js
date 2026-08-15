.pragma library

// Expected utput shape:
//   {"ok":true,"branch":"main","staged":1,"modified":2,"untracked":3,
//    "stash":1,"ahead":2,"behind":0}
// Output on failure (not a repo, missing git, ...):
//   {"ok":false}
function statusScript() {
  return [
    'P="$1"',
    'cd "$P" 2>/dev/null || { printf \'{"ok":false}\\n\'; exit 0; }',
    'B=$(git symbolic-ref --short HEAD 2>/dev/null)',
    'ST=$(git stash list 2>/dev/null | wc -l)',
    'AB=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0 0")',
    'BEHIND=${AB%% *}',
    'AHEAD=${AB##* }',
    'STAGED=0; MOD=0; UNT=0',
    'while IFS= read -r line; do',
    '  [ -z "$line" ] && continue',
    '  case "$line" in "??"*) UNT=$((UNT+1)); continue;; esac',
    '  X=${line:0:1}; Y=${line:1:1}',
    '  case "$X" in " ") ;; *) STAGED=$((STAGED+1));; esac',
    '  case "$Y" in " ") ;; *) MOD=$((MOD+1));; esac',
    'done <<< "$(git status --porcelain=v1 2>/dev/null)"',
    'printf \'{"ok":true,"branch":"%s","staged":%d,"modified":%d,"untracked":%d,"stash":%d,"ahead":%d,"behind":%d}\\n\' "$B" "$STAGED" "$MOD" "$UNT" "$ST" "$AHEAD" "$BEHIND"'
  ].join("\n")
}

function buildStatusCommand(path) {
  return ["bash", "-c", statusScript(), "gitarchy", String(path || "")]
}

function parseStatus(raw) {
  var out = { ok: false, branch: "", staged: 0, modified: 0, untracked: 0, stash: 0, ahead: 0, behind: 0 }
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
    out.stash = toInt(data.stash)
    out.ahead = toInt(data.ahead)
    out.behind = toInt(data.behind)
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
  if (parts.length === 0) parts.push("git")
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

function openLazygitCommand(path) {
  return "omarchy-launch-or-focus-tui lazygit -p " + shellQuote(path)
}

function openTerminalCommand(path) {
  return "omarchy-launch-floating-terminal-with-presentation -- " + shellQuote(path)
}

function fetchCommand(path) {
  return "git -C " + shellQuote(path) + " fetch --all --prune"
}

function copyUrlCommand(path) {
  return "git -C " + shellQuote(path) + " remote get-url origin 2>/dev/null | wl-copy"
}

function ghPrCommand(path) {
  return ["gh", "pr", "view", "--repo", String(path || ""), "--json", "number,title,state,url,headRefName", "--jq", ". | {number,title,state,url,headRefName}"]
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

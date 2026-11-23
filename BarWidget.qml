import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "GitService.js" as GitService

// Gitarchy bar widget: watches configured repos, shows branch + total dirty
// count in the bar, and hosts the details panel.
//
// Config (shell.json entry for this widget, or defaults from manifest):
//   pollInterval            seconds between git status refreshes (default 30)
//   currentRefreshInterval  seconds between focused-repo refreshes (default 2)
//   repos                   array of paths (or {path, name} objects) to watch
//   showBranch              show the primary branch name (default true)
//   showDirty               show total dirty count (default true)
//   lazyGitMode             "focus" or "floating"
BarWidget {
  id: root
  moduleName: "miseriae.gitarchy"

  readonly property string homeDir: Quickshell.env("HOME")

  property var repos: []
  property var statuses: []
  property var currentRepo: null
  property string currentPath: ""
  property string lastDataKey: ""

  readonly property bool showBranch: root.boolSetting("showBranch", true)
  readonly property bool showDirty: root.boolSetting("showDirty", true)
  readonly property int pollInterval: Math.max(5, parseInt(setting("pollInterval", 30), 10) || 30)
  readonly property int currentRefreshInterval: Math.max(1, parseInt(setting("currentRefreshInterval", 2), 10) || 2)
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")
  readonly property string terminalCwdScript: {
    var url = String(Qt.resolvedUrl("scripts/terminal-cwd.sh")).replace(/^file:\/\//, "")
    try { return decodeURIComponent(url) } catch (e) { return url }
  }

  // ---- Lifecycle contract for the nested panel (Bar.findPanelWidget)
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("statuses" in target) target.statuses = root.panelStatuses
  }

  // Watched repos + the focused-terminal repo (if any), with the current repo
  // first so it reads as "this is where I am right now". The current repo is
  // only shown when it is an actual git repository. Repos are deduplicated by
  // work-tree root, so a terminal inside a subdirectory of a watched repo does
  // not show up twice or count its dirty files twice.
  readonly property var panelStatuses: {
    // Decorate the current status first (pin badge + display name), then merge
    // it with the watched statuses so it can be deduplicated by work-tree root
    var current = root.currentRepo && root.currentRepo.ok ? root.currentPanelStatus() : null
    return GitService.mergeStatuses(current, root.statuses)
  }

  // `omarchy bar set` stores a plain string unless --json is passed, so a
  // boolean typed on the command line arrives as "true"/"false" rather than a
  // JSON boolean. Accept both forms.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).toLowerCase()
    if (text === "true" || text === "1" || text === "yes" || text === "on") return true
    if (text === "false" || text === "0" || text === "no" || text === "off") return false
    return fallback !== false
  }

  function refresh() {
    if (refreshTimer.running) refreshTimer.restart()
    var nextRepos = normalizeRepos(setting("repos", []))
    var reposChanged = root.repos.length !== nextRepos.length
    if (!reposChanged) {
      for (var i = 0; i < nextRepos.length; i++) {
        if (root.repos[i] !== nextRepos[i]) {
          reposChanged = true
          break
        }
      }
    }

    if (reposChanged) {
      var previous = root.statuses
      var nextStatuses = []

      // Keep the last known values while git status runs. Clearing these
      // arrays makes the bar's implicit width collapse and hides the button
      for (var j = 0; j < nextRepos.length; j++) {
        var preserved = null
        for (var k = 0; k < previous.length; k++) {
          if (previous[k] && previous[k].path === nextRepos[j]) {
            preserved = previous[k]
            break
          }
        }
        nextStatuses.push(preserved)
      }

      root.repos = nextRepos
      root.statuses = nextStatuses
    }
    root.syncPanel()

    for (var m = 0; m < gitInstantiator.count; m++) {
      var obj = gitInstantiator.objectAt(m)
      if (obj && typeof obj.refresh === "function") obj.refresh()
    }
    if (!cwdProc.running) cwdProc.running = true
  }

  function refreshCurrentRepo() {
    if (!cwdProc.running) cwdProc.running = true
  }

  // Fast re-check of the focused repo's git status (no watched-repo poll).
  // Also re-resolves the cwd every few ticks so `cd` inside a tmux pane
  // (which fires no focus event) is picked up promptly
  property int currentTick: 0
  function refreshCurrentStatus() {
    root.currentTick++
    if (root.currentTick % 10 === 0) {
      if (!cwdProc.running) cwdProc.running = true
      return
    }
    root.requestCurrentStatus()
  }

  function requestCurrentStatus() {
    if (root.currentPath === "" || currentProc.running) return
    currentProc.requestedPath = root.currentPath
    currentProc.running = true
  }

  // Focused terminal cwd resolved -> run git status on it
  function applyFocusedCwd(raw) {
    var path = String(raw || "").replace(/\s+$/, "")
    if (path === "") {
      root.currentPath = ""
      if (root.currentRepo !== null) {
        root.currentRepo = null
        root.syncPanel()
      }
      return
    }

    if (path !== root.currentPath) {
      root.currentPath = path
      root.currentRepo = null
      root.syncPanel()
    }
    root.requestCurrentStatus()
  }

  function applyCurrentRepo(raw, path) {
    // A cwd change can happen while the previous git process is still active
    // Never label an old result as the newly focused repo
    if (path !== root.currentPath) {
      Qt.callLater(root.requestCurrentStatus)
      return
    }
    var parsed = GitService.parseStatus(raw)
    parsed.path = path
    parsed.root = parsed.root !== "" ? parsed.root : path
    parsed.name = root.repoDisplayName(path, parsed.root)
    parsed.pr = null
    parsed.current = parsed.ok
    root.currentRepo = parsed
    root.syncPanel()
  }

  // Glanceable bar tint, derived from the live statuses so it updates on every
  // status change without manual re-sync: urgent (conflict/in-progress),
  // accent (uncommitted work), or neutral (inherits the bar's normal color)
  readonly property string buttonState: GitService.barState(root.panelStatuses)

  // Derived so settings that only affect the label (showBranch/showDirty)
  // update immediately instead of waiting for the next poll
  readonly property string buttonText: GitService.barText(root.panelStatuses, root.showBranch, root.showDirty)
  readonly property string buttonTooltip: GitService.barTooltip(root.panelStatuses)

  function syncPanel() {
    if (panelLoader.item && "statuses" in panelLoader.item)
      panelLoader.item.statuses = root.panelStatuses
  }

  function applyRepoStatus(path, raw) {
    var index = -1
    for (var i = 0; i < root.repos.length; i++) {
      if (root.repos[i] === path) {
        index = i
        break
      }
    }
    if (index < 0) return

    var parsed = GitService.parseStatus(raw)
    parsed.path = path
    parsed.root = parsed.root !== "" ? parsed.root : path
    parsed.name = root.repoDisplayName(path, parsed.root)
    parsed.pr = null
    parsed.pinned = true

    var copy = root.statuses.slice()
    copy[index] = parsed
    root.statuses = copy

    root.syncPanel()
  }

  function repoDisplayName(path, rootPath) {
    return GitService.repoDisplayName(setting("repos", []), path, rootPath, root.homeDir)
  }

  function currentPanelStatus() {
    var current = Object.assign({}, root.currentRepo)
    current.pinned = false

    var key = GitService.statusKey(current)
    for (var i = 0; i < root.statuses.length; i++) {
      var status = root.statuses[i]
      if (!status) continue
      if (GitService.statusKey(status) !== key) continue
      current.pinned = true
      current.name = root.repoDisplayName(status.path, status.root || status.path)
      return current
    }

    // Statuses may still be loading; match the configured entry by path so the
    // pin badge is stable from the first frame
    var entries = GitService.normalizeRepoList(setting("repos", []), root.homeDir)
    var targets = [String(current.path || ""), String(current.root || "")]
    for (var j = 0; j < entries.length; j++) {
      if (targets.indexOf(entries[j].path) !== -1) {
        current.pinned = true
        current.name = entries[j].name !== "" ? entries[j].name : GitService.repoName(entries[j].path)
        return current
      }
    }
    return current
  }

  function normalizeRepos(list) {
    var entries = GitService.normalizeRepoList(list, root.homeDir)
    var out = []
    for (var i = 0; i < entries.length; i++) out.push(entries[i].path)
    return out
  }

  function primaryRepoPath() {
    // The current (focused-terminal) repo takes precedence — right-click should
    // open lazygit where you are working, not a pinned repo
    if (root.currentRepo && root.currentRepo.ok && root.currentPath !== "")
      return root.currentRepo.root !== "" ? root.currentRepo.root : root.currentPath
    if (root.repos.length === 0) return ""
    for (var i = 0; i < root.statuses.length; i++) {
      if (root.statuses[i] && root.statuses[i].branch)
        return root.statuses[i].root !== "" ? root.statuses[i].root : root.repos[i]
    }
    return root.repos[0]
  }

  function openPrimaryLazygit() {
    var path = root.primaryRepoPath()
    if (path !== "" && root.bar) root.bar.run(GitService.openLazygitCommand(path, root.lazyGitMode))
  }

  visible: root.buttonText !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
  }

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    var reposKey = JSON.stringify(normalizeRepos(setting("repos", [])))
    var pollKey = String(setting("pollInterval", 30))
    var dataKey = reposKey + "|" + pollKey
    if (dataKey !== root.lastDataKey) {
      root.lastDataKey = dataKey
      refresh()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.pollInterval * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Debounce rapid focus changes (terminal -> browser -> terminal)
  // so a burst of active-toplevel events spawns at most one cwd lookup
  Timer {
    id: currentRepoDebounce
    interval: 80
    repeat: false
    onTriggered: root.refreshCurrentRepo()
  }

  // Fast focused-repo refresh: keeps the bar + CURRENT row live while working
  // (edits, untracked files, `cd` within the focused terminal)
  Timer {
    id: currentRepoTimer
    interval: root.currentRefreshInterval * 1000
    running: true
    repeat: true
    onTriggered: root.refreshCurrentStatus()
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      currentRepoDebounce.restart()
    }
  }

  ShellIpc {
    target: "miseriae.gitarchy"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // One git status process per watched repo. The Instantiator keeps the
  // delegate objects alive for the widget's lifetime so each process only
  // runs on refresh rather than being torn down and rebuilt every poll
  Instantiator {
    id: gitInstantiator
    model: root.repos

    delegate: Item {
      id: repoObject
      required property var modelData
      required property int index
      property string requestedPath: ""
      visible: false

      function refresh() {
        if (gitProc.running) return
        repoObject.requestedPath = String(repoObject.modelData || "")
        if (repoObject.requestedPath === "") return
        gitProc.running = true
      }

      // A delegate added after the last poll (settings changed to add a repo)
      // starts its own status run instead of waiting for the next tick
      Component.onCompleted: refresh()

      Process {
        id: gitProc
        running: false
        command: GitService.buildStatusCommand(repoObject.requestedPath)
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: root.applyRepoStatus(repoObject.requestedPath, text)
        }
      }
    }
  }

  // Focused-terminal repo detection: resolve the active terminal's cwd, then
  // run the same git status pipeline on it. Shown as the "current" repo
  Process {
    id: cwdProc
    running: false
    command: GitService.bundledCwdCommand(root.terminalCwdScript)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFocusedCwd(text)
    }
  }

  Process {
    id: currentProc
    running: false
    property string requestedPath: ""
    command: requestedPath !== "" ? GitService.buildStatusCommand(requestedPath) : []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCurrentRepo(text, currentProc.requestedPath)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.buttonText
    tooltipText: root.buttonTooltip
    horizontalMargin: 8.75
    verticalPadding: 8.75
    active: root.buttonState !== "neutral"
    activeColor: root.buttonState === "urgent" ? Color.urgent : Color.accent

    onPressed: function(b) {
      if (b === Qt.RightButton) root.openPrimaryLazygit()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }
}

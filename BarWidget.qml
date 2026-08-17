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
//   pollInterval  seconds between git status refreshes (default 30)
//   repos         array of paths (or {path, name} objects) to watch
//   showBranch    show the primary branch name (default true)
//   showDirty     show total dirty count (default true)
BarWidget {
  id: root
  moduleName: "miseriae.gitarchy"

  property var repos: []
  property var statuses: []
  property var currentRepo: null
  property string currentPath: ""
  property string buttonText: ""
  property string buttonTooltip: "Gitarchy — no repos configured"
  property string lastDataKey: ""
  property real buttonOpacity: 1.0

  readonly property bool showBranch: setting("showBranch", true) !== false
  readonly property bool showDirty: setting("showDirty", true) !== false
  readonly property int pollInterval: Math.max(5, parseInt(setting("pollInterval", 30), 10) || 30)
  readonly property int currentRefreshInterval: Math.max(1, parseInt(setting("currentRefreshInterval", 1), 10) || 1)
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")
  readonly property string terminalCwdScript: String(Qt.resolvedUrl("scripts/terminal-cwd.sh")).replace("file://", "")

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
  // only shown when it is an actual git repository
  readonly property var panelStatuses: {
    var out = []
    var currentPath = root.currentRepo && root.currentRepo.ok
      ? String(root.currentRepo.path || root.currentPath)
      : ""
    if (currentPath !== "") out.push(root.currentPanelStatus())
    for (var i = 0; i < root.statuses.length; i++) {
      var status = root.statuses[i]
      if (!status) continue
      if (currentPath !== "" && String(status.path || "") === currentPath) continue
      out.push(status)
    }
    return out
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
  // Runs on a short timer so edits inside the focused terminal show up within
  // a second. Also re-resolves the cwd every few ticks so `cd` inside a tmux
  // pane (which fires no focus event) is picked up promptly
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
    var path = String(raw || "").trim()
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
    parsed.name = GitService.repoName(path)
    parsed.pr = null
    parsed.current = parsed.ok
    root.currentRepo = parsed
    root.syncPanel()
  }

  function syncPanel() {
    if (panelLoader.item && "statuses" in panelLoader.item)
      panelLoader.item.statuses = root.panelStatuses
    root.buttonText = GitService.barText(root.panelStatuses, root.showBranch, root.showDirty)
    root.buttonTooltip = GitService.barTooltip(root.panelStatuses)
  }

  function applyRepoStatus(index, raw) {
    var parsed = GitService.parseStatus(raw)
    parsed.path = root.repos[index]
    parsed.name = repoDisplayName(root.repos[index], index)
    parsed.pr = null
    parsed.pinned = true

    var copy = root.statuses.slice()
    copy[index] = parsed
    root.statuses = copy

    root.syncPanel()
  }

  function repoDisplayName(path, index) {
    var entry = repoEntry(index)
    if (entry && entry.name) return String(entry.name)
    return GitService.repoName(path)
  }

  function currentPanelStatus() {
    var current = Object.assign({}, root.currentRepo)
    current.pinned = false
    for (var i = 0; i < root.repos.length; i++) {
      if (root.repos[i] !== current.path) continue
      current.pinned = true
      current.name = repoDisplayName(current.path, i)
      break
    }
    return current
  }

  function repoEntry(index) {
    var list = setting("repos", [])
    if (list && typeof list.length === "number" && list[index] && typeof list[index] === "object")
      return list[index]
    return null
  }

  function normalizeRepos(list) {
    var out = []
    if (!list) return out
    var length = typeof list.length === "number" ? list.length : 0
    for (var i = 0; i < length; i++) {
      var v = list[i]
      var path = ""
      if (typeof v === "string" && v.trim() !== "") path = v.trim()
      else if (v && typeof v === "object" && v.path) path = String(v.path).trim()
      if (path !== "") {
        out.push(expandHome(path.replace(/\/+$/, "")))
      }
    }
    return out
  }

  function expandHome(path) {
    if (path === "~") return Quickshell.env("HOME")
    if (path.charAt(0) === "~" && path.charAt(1) === "/")
      return Quickshell.env("HOME") + path.substring(1)
    return path
  }

  function primaryRepoPath() {
    // The current (focused-terminal) repo takes precedence — right-click should
    // open lazygit where you are working, not a pinned repo
    if (root.currentRepo && root.currentRepo.ok && root.currentPath !== "")
      return root.currentPath
    if (root.repos.length === 0) return ""
    for (var i = 0; i < root.statuses.length; i++) {
      if (root.statuses[i] && root.statuses[i].branch) return root.repos[i]
    }
    return root.repos[0]
  }

  function openPrimaryLazygit() {
    var path = root.primaryRepoPath()
    if (path !== "" && root.bar) root.bar.run(GitService.openLazygitCommand(path, root.lazyGitMode))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Behavior on implicitWidth {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
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
  onStatusesChanged: {
    if (panelLoader.item && "statuses" in panelLoader.item) panelLoader.item.statuses = root.panelStatuses
  }
  onButtonTextChanged: {
    // Brief fade-out/in so the branch/count text swap feels like a cross-fade
    // rather than a hard snap. Runs on every change, cheaper
    textFade.running = false
    textFade.running = true
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
  // (edits, untracked files, `cd` within the focused terminal). Cheap — one
  // git status on a single repo (~2-3ms) per tick
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

  IpcHandler {
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
      visible: false

      function refresh() {
        if (gitProc.running) return
        gitProc.running = true
      }

      Process {
        id: gitProc
        running: false
        command: GitService.buildStatusCommand(repoObject.modelData)
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: root.applyRepoStatus(repoObject.index, text)
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
    opacity: root.buttonOpacity
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.openPrimaryLazygit()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // Cross-fade the bar label when its text changes: dip to 60% then back to
  // 100%, so the branch/count swap reads as a smooth transition
  SequentialAnimation {
    id: textFade
    running: false
    onRunningChanged: if (!running) root.buttonOpacity = 1.0

    NumberAnimation {
      target: root
      property: "buttonOpacity"
      to: 0.6
      duration: 70
      easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: root
      property: "buttonOpacity"
      to: 1.0
      duration: 70
      easing.type: Easing.InCubic
    }
  }
}

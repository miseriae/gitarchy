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

  readonly property bool showBranch: setting("showBranch", true) !== false
  readonly property bool showDirty: setting("showDirty", true) !== false
  readonly property int pollInterval: Math.max(5, parseInt(setting("pollInterval", 30), 10) || 30)
  readonly property int currentRefreshInterval: Math.max(1, parseInt(setting("currentRefreshInterval", 1), 10) || 1)
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")

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
    if (root.currentRepo && root.currentRepo.ok) out.push(root.currentRepo)
    for (var i = 0; i < root.statuses.length; i++) out.push(root.statuses[i])
    return out
  }

  function refresh() {
    if (refreshTimer.running) refreshTimer.restart()
    root.repos = normalizeRepos(setting("repos", []))
    root.statuses = []
    root.currentRepo = null
    if (root.repos.length === 0) {
      root.buttonText = ""
      root.buttonTooltip = "Gitarchy — no repos configured"
    }
    for (var i = 0; i < gitInstantiator.count; i++) {
      var obj = gitInstantiator.objectAt(i)
      if (obj && typeof obj.refresh === "function") obj.refresh()
    }
    if (!cwdProc.running) cwdProc.running = true
  }

  // Re-resolve only the focused-terminal repo (CURRENT row) without touching
  // the watched repos. Called on every active-toplevel change so switching
  // terminals updates the row immediately rather than waiting for the poll
  function refreshCurrentRepo() {
    root.currentRepo = null
    root.syncPanel()
    if (!cwdProc.running) cwdProc.running = true
  }

  // Fast re-check of the focused repo's git status only (no cwd re-resolve,
  // no watched-repo poll). Runs on a short timer so edits and `cd` inside the
  // focused terminal show up in the bar / CURRENT row within a second
  function refreshCurrentStatus() {
    if (root.currentPath !== "" && !currentProc.running) currentProc.running = true
  }

  // Focused terminal cwd resolved -> run git status on it.
  function applyFocusedCwd(raw) {
    var path = String(raw || "").trim()
    if (path === "") {
      root.currentRepo = null
      root.syncPanel()
      return
    }
    root.currentPath = path
    if (!currentProc.running) currentProc.running = true
  }

  function applyCurrentRepo(raw) {
    var parsed = GitService.parseStatus(raw)
    parsed.path = root.currentPath
    parsed.name = GitService.repoName(root.currentPath)
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

  Timer {
    id: refreshTimer
    interval: root.pollInterval * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Debounce rapid focus changes (terminal -> browser -> terminal, alt-tab)
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
    command: GitService.focusedCwdCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFocusedCwd(text)
    }
  }

  Process {
    id: currentProc
    running: false
    command: root.currentPath !== "" ? GitService.buildStatusCommand(root.currentPath) : []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCurrentRepo(text)
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

    onPressed: function(b) {
      if (b === Qt.RightButton) root.openPrimaryLazygit()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
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
  property string buttonText: ""
  property string buttonTooltip: "Gitarchy — no repos configured"
  property string lastDataKey: ""

  readonly property bool showBranch: setting("showBranch", true) !== false
  readonly property bool showDirty: setting("showDirty", true) !== false
  readonly property int pollInterval: Math.max(5, parseInt(setting("pollInterval", 30), 10) || 30)
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
    if ("statuses" in target) target.statuses = root.statuses
  }

  function refresh() {
    if (refreshTimer.running) refreshTimer.restart()
    root.repos = normalizeRepos(setting("repos", []))
    root.statuses = []
    if (root.repos.length === 0) {
      root.buttonText = "git"
      root.buttonTooltip = "Gitarchy — no repos configured"
      return
    }
    for (var i = 0; i < gitInstantiator.count; i++) {
      var obj = gitInstantiator.objectAt(i)
      if (obj && typeof obj.refresh === "function") obj.refresh()
    }
  }

  function applyRepoStatus(index, raw) {
    var parsed = GitService.parseStatus(raw)
    parsed.path = root.repos[index]
    parsed.name = repoDisplayName(root.repos[index], index)
    parsed.pr = null

    var copy = root.statuses.slice()
    copy[index] = parsed
    root.statuses = copy

    root.buttonText = GitService.barText(root.statuses, root.showBranch, root.showDirty)
    root.buttonTooltip = GitService.barTooltip(root.statuses)

    if (panelLoader.item && "statuses" in panelLoader.item) panelLoader.item.statuses = root.statuses
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
    if (panelLoader.item && "statuses" in panelLoader.item) panelLoader.item.statuses = root.statuses
  }

  Timer {
    id: refreshTimer
    interval: root.pollInterval * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
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

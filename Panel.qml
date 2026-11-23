import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GitService.js" as GitService


// The BarWidget owns the polled statuses and injects them here via
// `statuses`. It also injects `hostWidget`, which drives refresh and the
// lazygit/terminal launches through the bar.
//
// Rows are a stable list of repo keys; live status data lives in
// `statusByKey`, so a status refresh (on each focused-repo tick) does not
// reset the ListView's scroll position or rebuild its delegates.
Panel {
  id: root
  moduleName: "miseriae.gitarchy"
  ipcTarget: "miseriae.gitarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var statuses: []
  property int selectedIndex: -1
  property bool ghAvailable: false

  readonly property var barIdentity: hostWidget || root
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")
  readonly property string homeDir: Quickshell.env("HOME")

  // Stable rows: [{ key }] in display order. Updated only when the set or
  // order of repos changes, never on a status tick.
  property var rows: []
  property var rowKeys: []
  property var statusByKey: ({})
  property var prByKey: ({})
  property var prInFlight: ({})
  property var actionBusy: ({})
  property var actionErrors: ({})

  // Stable panel foreground. barForeground swaps to a wallpaper-contrast color
  // when the bar is transparent (it is tuned for text floating over the
  // wallpaper); the panel card has its own opaque background, so it must use
  // the theme foreground, matching the built-in clock/weather panels
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property bool nerdFontSelected: String(Style.resolvedFontFamily || "").toLowerCase().indexOf("nerd") !== -1
  readonly property string refreshIcon: root.nerdFontSelected ? "󰑓" : "\u21BB"

  onStatusesChanged: root.rebuildRows()
  Component.onCompleted: root.rebuildRows()

  function refresh() {
    if (root.hostWidget && typeof root.hostWidget.refresh === "function")
      root.hostWidget.refresh()
  }

  function open() {
    root.refresh()
    root.controller.show()
  }

  // ---------------------------------------------------------------- rows

  function sameKeys(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function rebuildRows() {
    var map = ({})
    var keys = []
    var list = root.statuses || []
    for (var i = 0; i < list.length; i++) {
      var status = list[i]
      if (!status) continue
      var key = GitService.statusKey(status)
      if (key === "" || map[key] !== undefined) continue
      map[key] = status
      keys.push(key)
    }
    root.statusByKey = map

    if (root.sameKeys(keys, root.rowKeys)) return
    root.rowKeys = keys
    var next = []
    for (var j = 0; j < keys.length; j++) next.push({ key: keys[j] })
    root.rows = next
    if (root.selectedIndex >= next.length)
      root.selectedIndex = next.length > 0 ? next.length - 1 : -1
    if (repoList) repoList.currentIndex = root.selectedIndex
  }

  function rowKey(index) {
    var row = root.rows[index]
    return row ? String(row.key || "") : ""
  }

  function statusForKey(key) {
    var status = root.statusByKey[key]
    if (!status) return null
    var pr = root.prForKey(key)
    if (!pr) return status
    var copy = Object.assign({}, status)
    copy.pr = pr
    return copy
  }

  function statusForIndex(index) {
    var key = root.rowKey(index)
    return key !== "" ? root.statusForKey(key) : null
  }

  // PR state is cached outside the polled status object so a status refresh
  // does not erase it. A cached PR from a different branch is stale.
  function prForKey(key) {
    var pr = root.prByKey[key]
    if (!pr) return null
    var status = root.statusByKey[key]
    if (!status) return null
    if (String(pr.branch || "") !== String(status.branch || "")) return null
    return pr
  }

  function mapWith(map, key, value) {
    var copy = ({})
    for (var existingKey in map) {
      if (existingKey !== key) copy[existingKey] = map[existingKey]
    }
    if (value !== undefined) copy[key] = value
    return copy
  }

  function setSelected(index) {
    if (index < 0 || index >= root.rows.length) return
    root.selectedIndex = index
    repoList.currentIndex = index
  }

  function ensureSelection() {
    if (root.selectedIndex < 0 && root.rows.length > 0) root.setSelected(0)
  }

  function repoCountLabel() {
    var total = GitService.totalDirty(root.statuses)
    if (root.rows.length === 0) return ""
    return total > 0
      ? root.rows.length + " repo" + (root.rows.length > 1 ? "s" : "") + " · " + total + " dirty"
      : "all clean"
  }

  // j/k (and arrow) navigation over the repo rows
  function moveSelection(dy) {
    if (root.rows.length === 0) return
    if (root.selectedIndex < 0) root.selectedIndex = 0
    else root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + dy))
    repoList.currentIndex = root.selectedIndex
    if (panel && panel.contentItem && panel.focusTarget) {
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function activateSelection() {
    root.ensureSelection()
    if (root.selectedIndex >= 0 && root.selectedIndex < root.rows.length)
      root.openLazygit(root.selectedIndex)
  }

  function repoTarget(index) {
    var s = root.statusForIndex(index)
    if (!s) return ""
    return String(s.root !== "" ? s.root : s.path)
  }

  // Tab walks the panels in the same bar section; pass the widget mounted in
  // the slot, not this nested panel, or the bar cannot find the next slot
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ------------------------------------------------------------ settings

  function writeEntry(updates) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in updates) entry[key] = updates[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Persist the lazygit launch mode to the widget's shell.json entry, the same
  // inline-settings write the clock uses: apply locally first, push to the host
  // widget, then let the shell rewrite the entry (which feeds settings back to
  // every live instance of this widget)
  function persistLazyGitMode(mode) {
    if (mode === root.lazyGitMode) return
    root.writeEntry({ lazyGitMode: mode })
  }

  // ------------------------------------------------------------- actions

  function openLazygit(index) {
    var path = root.repoTarget(index)
    root.close()
    if (path !== "" && root.bar) root.bar.run(GitService.openLazygitCommand(path, root.lazyGitMode))
  }

  function copyUrl(index) {
    var path = root.repoTarget(index)
    if (path !== "" && root.bar) root.bar.run(GitService.copyUrlCommand(path))
  }

  function openGitHub(index) {
    var path = root.repoTarget(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openGitHubCommand(path))
  }

  function copyBranch(index) {
    var path = root.repoTarget(index)
    if (path !== "" && root.bar) root.bar.run(GitService.copyBranchCommand(path))
  }

  function openFolder(index) {
    var path = root.repoTarget(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openFolderCommand(path))
  }

  function openPrUrl(index) {
    var status = root.statusForIndex(index)
    var pr = status ? status.pr : null
    if (pr && pr.url && root.bar)
      root.bar.run("omarchy-launch-browser " + GitService.shellQuote(pr.url))
  }

  function startGitAction(index, action) {
    if (gitActionProcess.running) return
    var key = root.rowKey(index)
    var path = root.repoTarget(index)
    if (key === "" || path === "") return

    var command = null
    if (action === "fetch") command = GitService.fetchCommand(path)
    else if (action === "pull") command = GitService.pullCommand(path)
    else if (action === "push") command = GitService.pushCommand(path)
    if (!command) return

    root.actionBusy = root.mapWith(root.actionBusy, key, true)
    root.actionErrors = root.mapWith(root.actionErrors, key, undefined)
    gitActionProcess.requestedKey = key
    gitActionProcess.command = command
    gitActionProcess.running = true
    actionTimeout.restart()
  }

  function fetch(index) { root.startGitAction(index, "fetch") }
  function pull(index) { root.startGitAction(index, "pull") }
  function push(index) { root.startGitAction(index, "push") }

  function shortError(raw) {
    var text = String(raw || "").replace(/\s+/g, " ").trim()
    if (text.length > 160) text = text.substring(0, 157) + "…"
    return text !== "" ? text : "git command failed"
  }

  // Pin the focused/current repo to the watched list (persistent). The raw
  // setting list is edited in place so other entries keep their objects and
  // custom names. The canonical work-tree root is stored, so pinning from a
  // subdirectory does not add a second row for the same repo.
  function pinRepo(index) {
    if (!root.hostWidget) return
    var status = root.statusForIndex(index)
    if (!status) return
    var raw = root.setting("repos", [])
    var list = Array.isArray(raw) ? raw : []
    var next = GitService.addRepo(list, status.root !== "" ? status.root : status.path, root.homeDir)
    if (next.length === list.length) return
    root.writeEntry({ repos: next })
    root.refresh()
  }

  // Remove a repo from the watched list (persistent), preserving every
  // unrelated entry and its display name
  function unpinRepo(index) {
    if (!root.hostWidget) return
    var status = root.statusForIndex(index)
    if (!status) return
    var raw = root.setting("repos", [])
    var list = Array.isArray(raw) ? raw : []
    var next = GitService.removeRepo(list, status.path, status.root, root.homeDir)
    if (next.length === list.length) return
    root.writeEntry({ repos: next })
    root.refresh()
  }

  // ----------------------------------------------------------- PR status

  function togglePr(index) {
    var key = root.rowKey(index)
    if (key === "") return
    if (root.prForKey(key)) {
      root.prByKey = root.mapWith(root.prByKey, key, undefined)
      return
    }
    if (!root.ghAvailable || prProcess.running) return
    if (root.prInFlight[key] === true) return

    var path = root.repoTarget(index)
    if (path === "") return

    root.prInFlight = root.mapWith(root.prInFlight, key, true)
    prProcess.requestedKey = key
    prProcess.workingDirectory = path
    prProcess.command = GitService.ghPrCommand()
    prProcess.running = true
    prTimeout.restart()
  }

  function applyPr(key, raw, exitCode) {
    root.prInFlight = root.mapWith(root.prInFlight, key, undefined)
    var status = root.statusByKey[key]
    var branch = status ? String(status.branch || "") : ""
    var pr = exitCode === 0 ? GitService.parsePr(raw) : null
    if (pr) {
      pr.branch = branch
      root.prByKey = root.mapWith(root.prByKey, key, pr)
    } else {
      root.prByKey = root.mapWith(root.prByKey, key, { error: true, branch: branch })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(listColumn.implicitHeight + Style.space(8))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveSelection(dy) }
      onActivateRequested: root.activateSelection()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "f" || t === "F") { root.ensureSelection(); root.fetch(root.selectedIndex) }
        else if (t === "p") { root.ensureSelection(); root.pull(root.selectedIndex) }
        else if (t === "P") { root.ensureSelection(); root.push(root.selectedIndex) }
        else if (t === "g" || t === "G") { root.ensureSelection(); root.openGitHub(root.selectedIndex) }
        else if (t === "c" || t === "C") { root.ensureSelection(); root.copyUrl(root.selectedIndex) }
        else if (t === "b" || t === "B") { root.ensureSelection(); root.copyBranch(root.selectedIndex) }
        else if (t === "u" || t === "U") { root.ensureSelection(); root.unpinRepo(root.selectedIndex) }
      }

      Column {
        id: listColumn
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: parent.width
          height: Math.max(headerTitle.implicitHeight, headerCount.implicitHeight, modeLabel.implicitHeight, modeSeparator.implicitHeight, modeSwitch.height, refreshBtn.height)

          Text {
            id: headerTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Gitarchy"
            color: root.contentForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            id: headerCount
            anchors.left: headerTitle.right
            anchors.leftMargin: Style.space(8)
            anchors.right: modeSeparator.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.repoCountLabel()
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: modeLabel
            anchors.right: modeSwitch.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: (root.lazyGitMode === "floating" ? "Floating" : "Focus")
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            id: modeSeparator
            anchors.right: modeLabel.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "·"
            color: Qt.darker(root.contentForeground, 1.8)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            id: modeSwitch
            anchors.right: refreshBtn.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            checked: root.lazyGitMode === "floating"
            foreground: root.contentForeground
            accent: Color.accent
            onToggled: root.persistLazyGitMode(root.lazyGitMode === "floating" ? "focus" : "floating")

            PanelToolTip {
              visible: modeSwitch.containsMouse
              text: root.lazyGitMode === "floating" ? "Floating window" : "Focus window"
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
          }

          PanelActionButton {
            id: refreshBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.refreshIcon
            tooltipText: "Refresh"
            foreground: root.contentForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.refresh()
          }
        }

        ListView {
          id: repoList
          width: parent.width
          height: Math.min(repoList.contentHeight, panel.availableCardHeight > 0
            ? Math.max(Style.space(160), panel.availableCardHeight - Style.space(120))
            : Style.space(420))
          model: root.rows
          spacing: Style.space(6)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          onCurrentIndexChanged: {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: RepoItem {
            required property var modelData
            required property int index

            readonly property string rowKey: String(modelData && modelData.key || "")

            width: repoList.width
            status: root.statusForKey(rowKey)
            selected: root.selectedIndex === index
            contentForeground: root.contentForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            ghAvailable: root.ghAvailable
            prBusy: root.prInFlight[rowKey] === true
            actionBusy: root.actionBusy[rowKey] === true
            actionError: root.actionErrors[rowKey] || ""
            onHovered: root.setSelected(index)
            onOpenLazygit: root.openLazygit(index)
            onFetch: root.fetch(index)
            onPull: root.pull(index)
            onPush: root.push(index)
            onCopyUrl: root.copyUrl(index)
            onTogglePr: root.togglePr(index)
            onOpenGitHub: root.openGitHub(index)
            onCopyBranch: root.copyBranch(index)
            onOpenFolder: root.openFolder(index)
            onOpenPrUrl: root.openPrUrl(index)
            onPinRepo: root.pinRepo(index)
            onUnpinRepo: root.unpinRepo(index)
          }
        }

        Column {
          visible: root.rows.length === 0
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "No repos to show"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Open a terminal inside a git repository, or pin one to watch it here."
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  Process {
    id: ghCheck
    command: ["bash", "-c", "command -v gh 2>/dev/null"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ghAvailable = String(text || "").trim() !== ""
    }
  }

  Process {
    id: prProcess
    running: false
    property string requestedKey: ""
    command: GitService.ghPrCommand()
    stdout: StdioCollector { id: prStdout; waitForEnd: true }
    stderr: StdioCollector { id: prStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var key = prProcess.requestedKey
      if (key === "") return
      prProcess.requestedKey = ""
      prTimeout.stop()
      root.applyPr(key, prStdout.text, exitCode)
    }
  }

  // A hung `gh` (network or an auth prompt) must not disable the PR button for
  // every row until the shell restarts
  Timer {
    id: prTimeout
    interval: 15000
    repeat: false
    onTriggered: {
      var key = prProcess.requestedKey
      if (key === "") return
      prProcess.requestedKey = ""
      prProcess.running = false
      root.applyPr(key, "", 1)
    }
  }

  Process {
    id: gitActionProcess
    running: false
    property string requestedKey: ""
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var key = gitActionProcess.requestedKey
      gitActionProcess.requestedKey = ""
      actionTimeout.stop()
      if (key === "") return
      root.actionBusy = root.mapWith(root.actionBusy, key, undefined)
      if (exitCode !== 0) {
        root.actionErrors = root.mapWith(root.actionErrors, key, root.shortError(actionStderr.text || actionStdout.text))
        errorClearTimer.restart()
      } else {
        root.actionErrors = root.mapWith(root.actionErrors, key, undefined)
      }
      root.refresh()
    }
  }

  // Fetching over a slow network can legitimately take a while, but a stuck
  // credential helper must not block every row's actions forever
  Timer {
    id: actionTimeout
    interval: 120000
    repeat: false
    onTriggered: {
      var key = gitActionProcess.requestedKey
      if (key === "") return
      gitActionProcess.requestedKey = ""
      gitActionProcess.running = false
      root.actionBusy = root.mapWith(root.actionBusy, key, undefined)
      root.actionErrors = root.mapWith(root.actionErrors, key, "Timed out")
      errorClearTimer.restart()
    }
  }

  Timer {
    id: errorClearTimer
    interval: 12000
    repeat: false
    onTriggered: root.actionErrors = ({})
  }
}

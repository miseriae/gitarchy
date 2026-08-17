import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GitService.js" as GitService


// The BarWidget owns the polled statuses and injects them here via
// `statuses`. It also injects `hostWidget`, which drives refresh and the
// lazygit/terminal launches through the bar
Panel {
  id: root
  moduleName: "miseriae.gitarchy"
  ipcTarget: "miseriae.gitarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var statuses: []
  property int selectedIndex: -1

  readonly property var barIdentity: hostWidget || root
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")

  // Stable panel foreground. barForeground swaps to a wallpaper-contrast color
  // when the bar is transparent (it is tuned for text floating over the
  // wallpaper); the panel card has its own opaque background, so it must use
  // the theme foreground, matching the built-in clock/weather panels
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground

  function refresh() {
    if (root.hostWidget && typeof root.hostWidget.refresh === "function")
      root.hostWidget.refresh()
  }

  function open() {
    root.refresh()
    root.controller.show()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
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
            text: "Gitarchy"
            color: root.contentForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            id: headerCount
            anchors.right: modeSeparator.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
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
            iconText: "󰑓"
            tooltipText: "Refresh"
            foreground: root.contentForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.refresh()
          }
        }

        ListView {
          id: repoList
          width: parent.width
          height: Math.min(contentHeight, panel.availableCardHeight > 0
            ? Math.max(Style.space(160), panel.availableCardHeight - Style.space(120))
            : Style.space(420))
          model: root.statuses
          spacing: Style.space(6)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          onCurrentIndexChanged: {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: RepoItem {
            required property var modelData
            required property int index

            width: repoList.width
            status: modelData
            selected: root.selectedIndex === index
            contentForeground: root.contentForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onOpenLazygit: root.openLazygit(index)
            onFetch: root.fetch(index)
            onCopyUrl: root.copyUrl(index)
            onTogglePr: root.togglePr(index)
            onOpenGitHub: root.openGitHub(index)
            onCopyBranch: root.copyBranch(index)
            onOpenFolder: root.openFolder(index)
            onPinRepo: root.pinRepo(index)
            onUnpinRepo: root.unpinRepo(index)
          }
        }

        Column {
          visible: root.statuses.length === 0
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No repos to show"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
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

  function repoCountLabel() {
    var total = GitService.totalDirty(root.statuses)
    if (root.statuses.length === 0) return ""
    return total > 0 ? root.statuses.length + " repo" + (root.statuses.length > 1 ? "s" : "") + " · " + total + " dirty" : "all clean"
  }

  // j/k (and arrow) navigation over the repo rows
  function moveSelection(dy) {
    if (root.statuses.length === 0) return
    if (root.selectedIndex < 0) root.selectedIndex = 0
    else root.selectedIndex = Math.max(0, Math.min(root.statuses.length - 1, root.selectedIndex + dy))
    repoList.currentIndex = root.selectedIndex
    if (panel && panel.contentItem && panel.focusTarget) {
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function activateSelection() {
    if (root.selectedIndex >= 0 && root.selectedIndex < root.statuses.length) {
      root.openLazygit(root.selectedIndex)
    }
  }

  function repoPath(index) {
    var s = root.statuses[index]
    if (s && s.path) return String(s.path)
    return ""
  }

  // Persist the lazygit launch mode to the widget's shell.json entry, the same
  // inline-settings write the clock uses: apply locally first, push to the host
  // widget, then let the shell rewrite the entry (which feeds settings back to
  // every live instance of this widget)
  function persistLazyGitMode(mode) {
    if (mode === root.lazyGitMode) return
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.lazyGitMode = mode

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function openLazygit(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openLazygitCommand(path, root.lazyGitMode))
  }

  function fetch(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.fetchCommand(path))
    root.refresh()
  }

  function copyUrl(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.copyUrlCommand(path))
  }

  function openGitHub(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openGitHubCommand(path))
  }

  function copyBranch(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.copyBranchCommand(path))
  }

  function openFolder(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openFolderCommand(path))
  }

  // Pin the focused/current repo to the watched list (persistent). Mirrors the
  // clock's inline-settings write: add the path to `repos` and push through the
  // shell so the widget picks it up live
  function pinRepo(index) {
    var path = root.repoPath(index)
    if (path === "" || !root.hostWidget) return
    var repos = root.hostWidget.repos ? root.hostWidget.repos.slice() : []
    for (var i = 0; i < repos.length; i++) {
      if (repos[i] === path) return  // already watched
    }
    repos.push(path)

    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.repos = repos
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Remove a repo from the watched list (persistent)
  function unpinRepo(index) {
    var path = root.repoPath(index)
    if (path === "" || !root.hostWidget) return
    var repos = root.hostWidget.repos ? root.hostWidget.repos.slice() : []
    var next = []
    for (var i = 0; i < repos.length; i++) {
      if (repos[i] !== path) next.push(repos[i])
    }
    if (next.length === repos.length) return  // not watched

    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.repos = next
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Click-to-reveal PR: run gh once per row, cache the result in status.pr
  property var prInFlight: {}

  function togglePr(index) {
    var s = root.statuses[index]
    if (!s) return
    if (s.pr) {
      var copy = root.statuses.slice()
      copy[index] = Object.assign({}, s, { pr: null })
      root.statuses = copy
      return
    }
    if (root.prInFlight[index]) return
    root.prInFlight[index] = true
    prProcess.index = index
    prProcess.workingDirectory = root.repoPath(index)
    prProcess.command = GitService.ghPrCommand()
    prProcess.running = true
  }

  Process {
    id: prProcess
    running: false
    property int index: -1
    command: GitService.ghPrCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPr(root.prProcess.index, text)
    }
  }

  function applyPr(index, raw) {
    root.prInFlight[index] = false
    var s = root.statuses[index]
    if (!s) return
    var copy = root.statuses.slice()
    copy[index] = Object.assign({}, s, { pr: GitService.parsePr(raw) })
    root.statuses = copy
  }
}

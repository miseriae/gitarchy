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

  readonly property var barIdentity: hostWidget || root
  readonly property string lazyGitMode: setting("lazyGitMode", "focus")

  // Stable panel foreground. barForeground swaps to a wallpaper-contrast color
  // when the bar is transparent (it is tuned for text floating over the
  // wallpaper); the panel card has its own opaque background, so it must use
  // the theme foreground, matching the built-in clock/weather panels.
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

        Repeater {
          model: root.statuses

          RepoItem {
            required property var modelData
            required property int index

            width: listColumn.width
            status: modelData
            contentForeground: root.contentForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onOpenLazygit: root.openLazygit(index)
            onFetch: root.fetch(index)
            onCopyUrl: root.copyUrl(index)
            onTogglePr: root.togglePr(index)
          }
        }

        Text {
          visible: root.statuses.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No repos configured"
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  function repoCountLabel() {
    var total = GitService.totalDirty(root.statuses)
    if (root.statuses.length === 0) return ""
    return total > 0 ? root.statuses.length + " repo" + (root.statuses.length > 1 ? "s" : "") + " · " + total + " dirty" : "all clean"
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
    prProcess.command = GitService.ghPrCommand(root.repoPath(index))
    prProcess.running = true
  }

  Process {
    id: prProcess
    running: false
    property int index: -1
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

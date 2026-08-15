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
          height: Math.max(headerTitle.implicitHeight, headerCount.implicitHeight, refreshBtn.height)

          Text {
            id: headerTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Gitarchy"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            id: headerCount
            anchors.right: refreshBtn.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.repoCountLabel()
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: refreshBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑓"
            tooltipText: "Refresh"
            foreground: root.barForeground
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
            barForeground: root.barForeground
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
          color: Qt.darker(root.barForeground, 1.4)
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
    if (!root.hostWidget || !root.hostWidget.repos) return ""
    return String(root.hostWidget.repos[index] || "")
  }

  function openLazygit(index) {
    var path = root.repoPath(index)
    if (path !== "" && root.bar) root.bar.run(GitService.openLazygitCommand(path))
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

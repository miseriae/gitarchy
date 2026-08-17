import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A single watched repo row in the Gitarchy panel: name · branch · dirty
// counts · stash · ahead/behind. The action strip is always shown below the
// status row; double-click opens lazygit
Column {
  id: root
  spacing: Style.space(6)

  property var status: null
  property color contentForeground: Color.foreground
  property string fontFamily: Style.font.family
  property bool selected: false

  signal openLazygit()
  signal fetch()
  signal copyUrl()
  signal togglePr()
  signal openGitHub()
  signal copyBranch()
  signal openFolder()
  signal pinRepo()
  signal unpinRepo()

  readonly property bool hasBranch: !!status && status.branch !== ""
  readonly property int dirtyCount: status
    ? (status.staged || 0) + (status.modified || 0) + (status.untracked || 0)
    : 0
  readonly property bool hasRemote: status && (status.ahead || status.behind) ? true : false

  CursorSurface {
    id: rowSurface
    width: parent.width
    height: rowBody.implicitHeight
    hasCursor: root.selected
    current: false
    foreground: root.contentForeground
    fill: root.selected ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
    currentFill: Style.selectedFillFor(root.contentForeground, Color.accent)

    RowLayout {
      id: rowBody
      width: parent.width
      spacing: Style.space(8)

      // Repo icon
      Text {
        Layout.alignment: Qt.AlignVCenter
        text: ""
        color: root.hasBranch ? root.contentForeground : Qt.darker(root.contentForeground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        Layout.alignment: Qt.AlignVCenter
        spacing: 0

        Row {
          spacing: Style.space(4)

          Text {
            text: root.status ? root.status.name || "" : ""
            color: root.contentForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: root.status && root.status.current === true
            anchors.verticalCenter: parent.verticalCenter
            text: "CURRENT"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: root.status && root.status.pinned === true
            anchors.verticalCenter: parent.verticalCenter
            text: "PINNED"
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Row {
          spacing: Style.space(6)

          Text {
            text: root.branchLabel()
            color: root.branchColor()
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            visible: root.status && root.status.conflicts > 0
            text: "!" + root.status.conflicts
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: root.status && root.status.operation !== ""
            text: root.status.operation
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }

      Item { Layout.fillWidth: true; height: 1 }

      Text {
        Layout.alignment: Qt.AlignVCenter
        text: root.countsLabel()
        color: root.dirtyCount > 0 || (root.status && root.status.conflicts > 0)
          ? Color.urgent
          : Qt.darker(root.contentForeground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        text: root.hasRemote
          ? "↑" + status.ahead + " ↓" + status.behind
          : ""
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: root.status && root.status.stash > 0
        Layout.alignment: Qt.AlignVCenter
        text: "󱘋 " + root.status.stash
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onDoubleClicked: root.openLazygit()
    }
  }

  // Action strip
  Column {
    width: parent.width
    spacing: Style.space(2)

    Rectangle {
      width: parent.width
      height: Style.spacing.hairline
      color: root.contentForeground
      opacity: 0.1
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      // Single row of git / browse actions
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        PanelActionButton {
          iconText: ""
          tooltipText: "Open lazygit"
          foreground: root.contentForeground
          hoverColor: Color.accent
          bordered: true
          fontFamily: root.fontFamily
          onClicked: root.openLazygit()
        }

        PanelActionButton {
          iconText: ""
          tooltipText: "Fetch"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.fetch()
        }

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.spacing.hairline
          Layout.preferredHeight: Style.space(18)
          color: root.contentForeground
          opacity: 0.2
        }

        PanelActionButton {
          iconText: ""
          tooltipText: "Open on GitHub"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.openGitHub()
        }

        PanelActionButton {
          iconText: "󰉋"
          tooltipText: "Open in file manager"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.openFolder()
        }

        PanelActionButton {
          iconText: "󰅌"
          tooltipText: "Copy remote URL"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.copyUrl()
        }

        Item { Layout.fillWidth: true; height: 1 }

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.spacing.hairline
          Layout.preferredHeight: Style.space(18)
          color: root.contentForeground
          opacity: 0.2
        }

        PanelActionButton {
          iconText: ""
          tooltipText: "Copy branch name"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.copyBranch()
        }

        // Pin: only offered on the CURRENT (focused) repo that isn't pinned yet
        PanelActionButton {
          visible: root.status && root.status.current === true && root.status.pinned !== true
          iconText: ""
          tooltipText: "Pin this repo (keep it in your list)"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.pinRepo()
        }

        // Unpin: only offered on pinned (watched) repos
        PanelActionButton {
          visible: root.status && root.status.pinned === true
          iconText: "󰐄"
          tooltipText: "Unpin this repo"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.unpinRepo()
        }

        PanelActionButton {
          iconText: ""
          tooltipText: root.status && root.status.pr ? "Hide PR" : "Show PR"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.togglePr()
        }
      }

      Text {
        visible: root.status && root.status.pr
        width: parent.width
        elide: Text.ElideRight
        text: root.prLabel()
        color: root.prColor()
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  function countsLabel() {
    if (!root.status) return ""
    var parts = []
    if (root.status.staged) parts.push("+" + root.status.staged)
    if (root.status.modified) parts.push("~" + root.status.modified)
    if (root.status.untracked) parts.push("-" + root.status.untracked)
    return parts.join(" ")
  }

  // Branch display: normal branch, "(no commits)" for unborn, "detached" for
  // a detached HEAD
  function branchLabel() {
    if (!root.status) return ""
    if (root.status.unborn) return "no commits"
    if (root.status.detached) return "detached " + root.status.branch
    return root.status.branch || "not a repo"
  }

  function branchColor() {
    if (!root.status) return Qt.darker(root.contentForeground, 1.5)
    if (root.status.conflicts > 0) return Color.urgent
    if (root.status.operation !== "") return Color.urgent
    if (root.status.branch) return Color.accent
    return Qt.darker(root.contentForeground, 1.5)
  }

  function prLabel() {
    var pr = root.status ? root.status.pr : null
    if (!pr) return ""
    return "#" + pr.number + " " + pr.state
  }

  function prColor() {
    var pr = root.status ? root.status.pr : null
    if (!pr) return root.contentForeground
    if (pr.state === "OPEN") return Color.accent
    if (pr.state === "MERGED") return Color.urgent
    return Qt.darker(root.contentForeground, 1.4)
  }
}

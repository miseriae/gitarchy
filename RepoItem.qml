import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A single watched repo row in the Gitarchy panel: name · branch · dirty
// counts · stash · ahead/behind. Single click expands a details/action strip;
// double-click opens lazygit; the strip exposes fetch, copy URL, and
// click-to-reveal PR status.
Column {
  id: root

  property var status: null
  property color contentForeground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false

  signal openLazygit()
  signal fetch()
  signal copyUrl()
  signal togglePr()

  readonly property bool hasBranch: !!status && status.branch !== ""
  readonly property int dirtyCount: status
    ? (status.staged || 0) + (status.modified || 0) + (status.untracked || 0)
    : 0
  readonly property bool hasRemote: status && (status.ahead || status.behind) ? true : false

  CursorSurface {
    id: rowSurface
    width: parent.width
    height: rowBody.implicitHeight
    hasCursor: root.expanded
    current: root.dirtyCount > 0
    foreground: root.contentForeground
    fill: "transparent"
    currentFill: Style.selectedFillFor(root.contentForeground, Color.accent)

    RowLayout {
      id: rowBody
      width: parent.width
      spacing: Style.space(8)

      // Repo icon
      Text {
        Layout.alignment: Qt.AlignVCenter
        text: ""
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
        }

        Text {
          text: root.status && root.status.branch ? root.status.branch : "not a repo"
          color: root.status && root.status.branch
            ? Color.accent
            : Qt.darker(root.contentForeground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item { Layout.fillWidth: true; height: 1 }

      Text {
        Layout.alignment: Qt.AlignVCenter
        text: root.countsLabel()
        color: root.dirtyCount > 0
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
      onClicked: root.expanded = !root.expanded
      onDoubleClicked: root.openLazygit()
    }
  }

  // Details / action strip
  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: root.expanded

    Rectangle {
      width: parent.width
      height: Style.spacing.hairline
      color: root.contentForeground
      opacity: 0.1
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        PanelActionButton {
          iconText: "󰊘"
          tooltipText: "Open lazygit"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.openLazygit()
        }

        PanelActionButton {
          iconText: "󰀹"
          tooltipText: "Fetch"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.fetch()
        }

        PanelActionButton {
          iconText: "󰅌"
          tooltipText: "Copy remote URL"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.copyUrl()
        }

        Item { Layout.fillWidth: true; height: 1 }

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: root.prLabel()
          color: root.prColor()
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          iconText: "󰇾"
          tooltipText: root.status && root.status.pr ? "Hide PR" : "Show PR"
          foreground: root.contentForeground
          fontFamily: root.fontFamily
          onClicked: root.togglePr()
        }
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

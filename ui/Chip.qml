import QtQuick
import qs.Commons

// A small labeled pill — a tag on a row or in a picker. Ported from GH
// Grilles' own ui/Chip.qml (Gabriel, 2026-10-08), unchanged.
Rectangle {
  id: root

  property string label: ""
  property bool clickable: true
  property bool removable: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  signal activated()
  signal removeRequested()

  implicitWidth: content.implicitWidth + Style.space(16)
  implicitHeight: content.implicitHeight + Style.space(6)
  radius: Style.cornerRadius
  color: hover.hovered && root.clickable
    ? Style.hoverFillFor(root.foreground, root.accent)
    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      text: root.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }

    Text {
      visible: root.removable
      text: "×"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.removeRequested()
      }
    }
  }

  HoverHandler {
    id: hover
    enabled: root.clickable
    cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.clickable
    onClicked: root.activated()
  }
}

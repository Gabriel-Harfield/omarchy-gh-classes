import QtQuick
import qs.Commons
import qs.Ui

// Stand-in for the "consignes"/"agent" file-building wizards described by
// Gabriel (2026-09-13): the "Générer" buttons next to those two path
// fields in the Corrections tab must exist and open a dialog now, but the
// actual wizard steps are a follow-up. Deliberately just a title + message
// + close button, same "coming soon" posture as the existing
// addAppreciationToLabelSheet() placeholder in the Appréciations tab.
Item {
  id: root

  property bool opened: false
  property string title: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal canceled()

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(420))
      height: Math.min(parent.height - Style.space(32),
        cardContent.implicitHeight + card.contentTopInset + card.contentBottomInset)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(16)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.lg

        Text {
          text: root.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Text {
          text: "Cet assistant de construction n'est pas encore disponible dans cette version — il faudra pour l'instant rédiger ce fichier vous-même."
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Button {
          text: "Fermer"
          bordered: true
          foreground: root.foreground
          accent: root.accent
          onClicked: root.canceled()
        }
      }
    }
  }
}

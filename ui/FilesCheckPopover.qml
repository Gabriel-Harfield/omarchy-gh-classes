import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Log popover for the optional pre-launch "🔍 Vérifier les fichiers" check
// — a read-only relecture of sujet/corrigé/consignes/agent together,
// before Gabriel commits to creating the évaluation.
Item {
  id: root

  property bool opened: false
  property bool running: false
  property string result: ""
  property string error: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal canceled()

  function bodyText() {
    if (root.running) return "Vérification en cours…"
    if (root.error !== "") return root.error
    if (root.result === "" || root.result.toUpperCase() === "RAS") return "RAS — rien à signaler, les fichiers sont cohérents."
    return root.result
  }

  function bodyColor() {
    if (root.error !== "") return Color.urgent
    return Qt.darker(root.foreground, 1.3)
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(40), Style.space(480))
      height: Math.min(parent.height - Style.space(40), Style.space(420))
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      ScrollView {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          width: card.width - card.contentLeftInset - card.contentRightInset
          spacing: Style.spacing.lg

          Text {
            text: "Vérification des fichiers"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.bodyText()
            color: root.bodyColor()
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
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
}

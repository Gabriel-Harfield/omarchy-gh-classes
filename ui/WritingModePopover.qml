import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/Store.js" as Store

// "Manuscrit / Tapuscrit" overlay for the Corrections tab: sets the
// evaluation's overall writing medium (used to tell the correction agent
// how cautious to be about misreading), plus a per-student exception list
// for students whose copy is the OPPOSITE medium (ex. un aménagement
// dys qui tape alors que le reste de la classe écrit à la main).
// Same MultiSelect-based shape as IncompatibilityPopover.
Item {
  id: root

  property bool opened: false
  property string mode: "manuscrit" // manuscrit | tapuscrit
  property var exceptionIds: []
  property var students: [] // [{id, nom, prenom}, ...]
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal applied(string mode, var exceptionIds)
  signal canceled()

  property string draftMode: "manuscrit"

  function studentOptions() {
    return root.students.map(function(s) { return { value: s.id, label: Store.studentLabel(s) } })
  }

  visible: opened
  onOpenedChanged: if (opened) {
    root.draftMode = root.mode
    picker.values = root.exceptionIds.slice()
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(40), Style.space(520))
      height: Math.min(parent.height - Style.space(40), Style.space(560))
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
          spacing: Style.spacing.huge

          Text {
            text: "Manuscrit ou tapuscrit ?"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: "Précise le mode d'écriture majoritaire de cette évaluation : l'agent de correction sera plus prudent sur la lecture d'une copie manuscrite (il signalera dans le log tout passage illisible ou ambigu plutôt que de deviner). Ajoute ensuite, si besoin, les élèves qui font exception (par ex. un aménagement)."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "manuscrit", label: "Manuscrit" },
              { value: "tapuscrit", label: "Tapuscrit" }
            ]
            value: root.draftMode
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
            onChanged: function(value) { root.draftMode = value }
          }

          Text {
            text: "Élèves en exception (copie en " + (root.draftMode === "manuscrit" ? "tapuscrit" : "manuscrit") + ")"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          MultiSelect {
            id: picker
            width: parent.width
            label: ""
            showLabel: false
            options: root.studentOptions()
            noSelectionText: "Aucune exception"
            placeholderText: "Rechercher un élève…"
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
          }

          Row {
            spacing: Style.spacing.controlGap

            Button {
              text: "Valider"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.applied(root.draftMode, picker.values.slice())
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
}

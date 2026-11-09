import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/Store.js" as Store

// "Exclure du tirage" overlay (Gabriel, 2026-11-02): one toggle per
// student; a ticked student is never picked by "🎲 Tirer au sort" (e.g. a
// PAP-type aménagement). Each toggle is saved immediately.
Item {
  id: root

  property bool opened: false
  property string flag: "drawExcluded"
  property string title: "Exclure du tirage"
  property string description: "Les élèves cochés ne seront jamais tirés au sort (aménagement de type PAP, par exemple). Leur historique de tirage est conservé."
  property var students: [] // [{id, nom, prenom, drawExcluded}, ...]
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal toggled(string studentId, bool excluded)
  signal canceled()

  function sortedStudents() {
    return root.students.slice().sort(function(a, b) {
      return Store.studentLabel(a).localeCompare(Store.studentLabel(b))
    })
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(40), Style.space(520))
      height: Math.min(parent.height - Style.space(40), Style.space(620))
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
            text: root.title
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.description
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.sortedStudents()
              delegate: Toggle {
                required property var modelData
                width: parent.width
                label: Store.studentLabel(modelData)
                checked: !!modelData[root.flag]
                foreground: root.foreground
                accent: Color.urgent
                fontFamily: root.fontFamily
                onClicked: root.toggled(modelData.id, !modelData[root.flag])
              }
            }
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

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/Store.js" as Store

// "Élèves incompatibles" overlay: pick 2+ students who must never land in
// the same group, add that set to the class's incompatibilities, review
// / remove existing sets.
Item {
  id: root

  property bool opened: false
  property var students: [] // [{id, nom, prenom}, ...]
  property var incompatibilities: [] // [[studentId, ...], ...]
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal setAdded(var studentIds)
  signal setRemoved(int index)
  signal canceled()

  function studentOptions() {
    return root.students.map(function(s) { return { value: s.id, label: Store.studentLabel(s) } })
  }

  function setLabel(set) {
    var byId = {}
    for (var i = 0; i < root.students.length; i++) byId[root.students[i].id] = root.students[i]
    return set.map(function(id) { return byId[id] ? Store.studentLabel(byId[id]) : "?" }).join("  ≠  ")
  }

  visible: opened
  onOpenedChanged: if (opened) picker.values = []

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
            text: "Élèves incompatibles"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: "Sélectionnez au moins 2 élèves qui ne doivent jamais se retrouver dans le même groupe."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          MultiSelect {
            id: picker
            width: parent.width
            label: ""
            showLabel: false
            options: root.studentOptions()
            noSelectionText: "Choisir des élèves…"
            placeholderText: "Rechercher un élève…"
            foreground: root.foreground
            background: root.background
            accent: root.accent
            fontFamily: root.fontFamily
          }

          Button {
            text: "Ajouter cette incompatibilité"
            bordered: true
            enabled: picker.values.length >= 2
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              root.setAdded(picker.values.slice())
              picker.values = []
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          Text {
            text: "Incompatibilités enregistrées"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.incompatibilities.length === 0
            text: "Aucune pour le moment."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.incompatibilities
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: Math.max(setText.implicitHeight, removeBtn.implicitHeight)

                Text {
                  id: setText
                  anchors.left: parent.left
                  anchors.right: removeBtn.left
                  anchors.rightMargin: Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.setLabel(modelData)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }

                Button {
                  id: removeBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "✕"
                  bordered: true
                  foreground: root.foreground
                  accent: Color.urgent
                  onClicked: root.setRemoved(index)
                }
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

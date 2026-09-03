import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/Store.js" as Store

// "Paramètres" overlay: list of existing classes (with delete), plus the
// "créer une nouvelle classe" form (name + typed path to the roster
// markdown file — no native FileDialog, see Panel.qml's own comment on
// why this codebase avoids QtQuick.Dialogs.FileDialog entirely).
Item {
  id: root

  property bool opened: false
  property var classes: []
  property bool importing: false
  property string importError: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal createRequested(string name, string path)
  signal deleteRequested(string classId)
  signal canceled()

  function clearDraft() {
    nameField.text = ""
    pathField.text = ""
  }

  visible: opened

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
            text: "Paramètres — Classes"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.classes.length > 0

            Repeater {
              model: root.classes
              delegate: Item {
                required property var modelData
                width: parent.width
                height: Math.max(classNameText.implicitHeight, deleteBtn.implicitHeight)

                Text {
                  id: classNameText
                  anchors.left: parent.left
                  anchors.right: deleteBtn.left
                  anchors.rightMargin: Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name + "  ·  " + modelData.students.length + " élève" + (modelData.students.length > 1 ? "s" : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                Button {
                  id: deleteBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Supprimer"
                  bordered: true
                  foreground: root.foreground
                  accent: Color.urgent
                  onClicked: root.deleteRequested(modelData.id)
                }
              }
            }
          }

          Text {
            visible: root.classes.length === 0
            text: "Aucune classe pour le moment."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              text: "Créer une nouvelle classe"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Nom de la classe (ex. 2nde 4)"
              foreground: root.foreground
              accent: root.accent
              maximumLength: 120
            }

            TextField {
              id: pathField
              width: parent.width
              placeholderText: "Chemin du fichier .md (une ligne par élève : NOM Prénom)"
              foreground: root.foreground
              accent: root.accent
              maximumLength: 2000
            }

            Text {
              visible: root.importError !== ""
              width: parent.width
              text: root.importError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            Row {
              spacing: Style.spacing.controlGap

              Button {
                text: root.importing ? "Import en cours…" : "Créer"
                bordered: true
                enabled: !root.importing
                foreground: root.foreground
                accent: root.accent
                onClicked: root.createRequested(nameField.text, pathField.text)
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
}

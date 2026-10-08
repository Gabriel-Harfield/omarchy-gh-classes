import QtQuick
import qs.Commons
import qs.Ui

// Pick-or-type-a-tag popover for "💾 Enregistrer dans la banque" (Eval.
// Compétences' "Commentaires" section, Gabriel, 2026-10-08) — same idiom
// as GH Grilles' own ui/TagPopover.qml, ported and renamed.
Item {
  id: root

  property bool opened: false
  property var existingTags: [] // string[], already alphabetical
  property string initialTag: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal tagPicked(string tag)
  signal canceled()

  visible: opened
  anchors.fill: parent

  onOpenedChanged: if (opened) {
    newTagField.text = root.initialTag
    Qt.callLater(function() { newTagField.forceActiveFocus() })
  }

  function commit(tag) {
    var t = String(tag || "").trim()
    if (!t) return
    root.tagPicked(t)
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(360))
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
          text: "Enregistrer dans la banque de commentaires"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          visible: root.existingTags.length > 0
          text: "Tags existants :"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flow {
          width: parent.width
          visible: root.existingTags.length > 0
          spacing: Style.spacing.sm

          Repeater {
            model: root.existingTags
            delegate: Chip {
              required property string modelData
              label: modelData
              foreground: root.foreground
              accent: root.accent
              onActivated: root.commit(modelData)
            }
          }
        }

        PanelSeparator { foreground: root.foreground; width: parent.width }

        Text {
          text: "Nouveau tag :"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          TextField {
            id: newTagField
            width: parent.width - confirmBtn.width - cancelBtn.width - Style.spacing.controlGap * 2
            placeholderText: "nom du tag…"
            foreground: root.foreground
            accent: root.accent
            maximumLength: 100
            Keys.onReturnPressed: root.commit(newTagField.text)
            Keys.onEnterPressed: root.commit(newTagField.text)
            Keys.onEscapePressed: root.canceled()
          }

          Button {
            id: confirmBtn
            text: "Valider"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.commit(newTagField.text)
          }

          Button {
            id: cancelBtn
            text: "Annuler"
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

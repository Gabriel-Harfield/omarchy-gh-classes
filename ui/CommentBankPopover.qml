import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/CommentsBankStore.js" as CommentsBankStore

// "📚 Insérer depuis la banque": browse the saved appreciation-comment
// bank, grouped by tag, filterable by text or tag (Eval. Compétences'
// "Commentaires" section, Gabriel, 2026-10-08) — same idiom as GH Grilles'
// own ui/CriteriaBankPopup.qml, ported and renamed. Clicking an entry's
// text inserts it as a new comment bullet for the CURRENTLY SELECTED
// student (Panel.qml's job, via commentPicked) — this popover never
// touches the student's comments itself. Deleting a bank entry (the × per
// row) asks for confirmation first, since it's a permanent removal from
// the reusable bank, not from any one student's copy.
Item {
  id: root

  property bool opened: false
  property var bank: [] // [{ id, text, tag }]
  property string filterText: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal commentPicked(var entry)
  signal deleteConfirmed(string id)
  signal canceled()

  readonly property var filteredGroups: {
    var q = root.filterText.trim().toLowerCase()
    var groups = CommentsBankStore.groupedByTag(root.bank)
    if (!q) return groups
    var out = []
    for (var i = 0; i < groups.length; i++) {
      var kept = groups[i].entries.filter(function(e) {
        return e.text.toLowerCase().indexOf(q) !== -1 || e.tag.toLowerCase().indexOf(q) !== -1
      })
      if (kept.length > 0) out.push({ tag: groups[i].tag, entries: kept })
    }
    return out
  }

  property string _pendingDeleteId: ""
  property string _pendingDeleteLabel: ""

  visible: opened
  anchors.fill: parent

  onOpenedChanged: if (opened) {
    root.filterText = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(460))
      height: Math.min(parent.height - Style.space(48), Style.space(480))
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(16)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.lg

        Text {
          text: "Insérer depuis la banque de commentaires"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Filtrer par texte ou tag…"
          foreground: root.foreground
          accent: root.accent
          text: root.filterText
          onTextChanged: root.filterText = text
          Keys.onEscapePressed: root.canceled()
        }

        Text {
          visible: root.filteredGroups.length === 0
          text: root.bank.length === 0
            ? "La banque de commentaires est vide pour l'instant."
            : "Aucun commentaire ne correspond à ce filtre."
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          wrapMode: Text.WordWrap
          width: parent.width
        }

        ScrollView {
          width: parent.width
          height: parent.height - y
          clip: true
          visible: root.filteredGroups.length > 0
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: root.filteredGroups

              delegate: Column {
                required property var modelData
                width: parent ? parent.width : 0
                spacing: Style.spacing.sm

                Text {
                  text: modelData.tag
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  textFormat: Text.PlainText
                }

                Repeater {
                  model: modelData.entries

                  delegate: BorderSurface {
                    id: entryCard
                    required property var modelData
                    width: parent ? parent.width : 0
                    height: entryText.implicitHeight + Style.spacing.sm * 2
                    radius: Style.cornerRadius
                    color: entryHover.hovered
                      ? Style.hoverFillFor(root.foreground, root.accent)
                      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                    borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16), Style.normalBorderWidth)
                    leftPadding: Style.spacing.controlPaddingX
                    rightPadding: Style.spacing.controlPaddingX

                    HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }

                    Text {
                      id: entryText
                      anchors.left: parent.left
                      anchors.right: deleteGlyph.left
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: entryCard.contentLeftInset
                      anchors.rightMargin: Style.spacing.controlGap
                      text: entryCard.modelData.text
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      wrapMode: Text.WordWrap

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.commentPicked(entryCard.modelData)
                      }
                    }

                    Text {
                      id: deleteGlyph
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.rightMargin: entryCard.contentRightInset
                      text: "×"
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true

                      HoverHandler { cursorShape: Qt.PointingHandCursor }
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        onClicked: {
                          root._pendingDeleteId = entryCard.modelData.id
                          root._pendingDeleteLabel = entryCard.modelData.text
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  ConfirmDialog {
    anchors.fill: parent
    opened: root._pendingDeleteId !== ""
    message: "Supprimer « " + root._pendingDeleteLabel + " » de la banque de commentaires ?"
    cancelText: "Annuler"
    confirmText: "Supprimer"
    selectedIndex: 0
    background: root.background
    foreground: root.foreground
    onCanceled: root._pendingDeleteId = ""
    onConfirmed: {
      root.deleteConfirmed(root._pendingDeleteId)
      root._pendingDeleteId = ""
    }
  }
}

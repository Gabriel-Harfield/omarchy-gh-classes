import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// "Archives" overlay for the Corrections tab (Gabriel, 2026-10-15): lists
// the archived évaluations of the current class (newest first) and lets
// Gabriel restore one. Restoring first archives the évaluation currently in
// place, so nothing is ever overwritten — see lib/ArchiveStore.js.
Item {
  id: root

  property bool opened: false
  // Popover zoom (shared, persisted by Panel.qml).
  property real zoom: 1.0
  signal zoomChangeRequested(real zoom)
  property var entries: [] // [{ file, when, title, done, total }]
  property string feedback: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal restoreRequested(string file)
  signal canceled()

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(40), Style.space(620))
      height: Math.min(parent.height - Style.space(40), Style.space(520))
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

        // Gabriel, 2026-10-21: popover-local zoom (the panel-wide one does not
        // reach popovers) — same scale-transform trick as Panel.qml's
        // zoomWrapper; the wrapper reports the REAL scaled size to the ScrollView.
        Item {
          id: zoomWrapper
          width: zoomColumn.width * root.zoom
          height: zoomColumn.height * root.zoom
          implicitWidth: width
          implicitHeight: height

          Column {
            id: zoomColumn
            width: (card.width - card.contentLeftInset - card.contentRightInset) / root.zoom
            scale: root.zoom
            transformOrigin: Item.TopLeft
            spacing: Style.spacing.huge

            Row {
              layoutDirection: Qt.RightToLeft
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                text: "+"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.zoomChangeRequested(root.zoom + 0.1)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignHCenter
                text: Math.round(root.zoom * 100) + "%"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Button {
                text: "−"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.zoomChangeRequested(root.zoom - 0.1)
              }
            }

            Text {
              text: "Archives des évaluations"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Évaluations archivées pour cette classe. Restaurer une archive remet ses corrections dans l'onglet ; l'évaluation actuellement en place est d'abord archivée, donc rien n'est écrasé. Les PDF des copies ne sont pas archivés : ils doivent toujours se trouver dans le dossier d'origine."
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.entries.length === 0
              width: parent.width
              text: "Aucune archive pour cette classe."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.entries
              delegate: Column {
                id: entryRow
                required property var modelData
                width: parent.width
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  text: entryRow.modelData.when + "  ·  " + entryRow.modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                }
                Row {
                  spacing: Style.spacing.controlGap
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: entryRow.modelData.done + " / " + entryRow.modelData.total + " copies corrigées"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Button {
                    text: "↩ Restaurer"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.restoreRequested(entryRow.modelData.file)
                  }
                }
              }
            }

            Text {
              visible: root.feedback !== ""
              width: parent.width
              text: root.feedback
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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
}

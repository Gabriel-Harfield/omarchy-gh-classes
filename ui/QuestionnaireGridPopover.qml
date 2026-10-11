import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/QuestionnaireGrid.js" as QuestionnaireGrid

// "Grille" overlay pour une copie du pipeline questionnaire (Gabriel,
// 2026-10-11). Même forme que CompetencyGridPopover — tableau cliquable,
// commentaire de l'agent sous la ligne — mais réorganisé autour de ce qui
// prend le temps ici : il n'y a pas d'appréciation à relire, il y a 30
// cases dont 5 ou 6 méritent un regard.
//
// D'où les deux choix propres à ce popover :
//   - sous chaque ligne, l'agent affiche CE QU'IL A LU sur la copie
//     (« lu : … ») en plus de son arbitrage éventuel : sur une copie
//     manuscrite, c'est la lecture, pas le jugement grammatical, qui est
//     la source d'erreur, et la seule façon de la vérifier d'un coup
//     d'œil est de voir la transcription à côté de la case ;
//   - un filtre « seulement les items à arbitrer » : relire 30 lignes
//     pour en vérifier 6 annule le gain de temps de la correction
//     automatique. Le filtre garde aussi les items que l'agent n'a pas
//     cochés du tout, qui comptent 0 et doivent donc être vus.
Item {
  id: root

  property bool opened: false
  property string studentLabel: ""
  property var columns: []          // [string] — les cases, de gauche à droite
  property var rows: []             // [{ text }]
  property var checks: ({})         // { "<rowIndex>": colIndex }
  property var answers: ({})        // { "<rowIndex>": ce que l'agent a lu }
  property var doubts: ({})         // { "<rowIndex>": son arbitrage }
  // Note "effective" : la correction manuelle de Gabriel s'il en a
  // enregistré une, sinon le calcul automatique. liveNote est TOUJOURS le
  // calcul automatique, affiché à côté pour qu'il voie ce qu'un retour en
  // arrière lui rendrait. Même convention que CompetencyGridPopover.
  property string note: ""
  property string liveNote: ""
  property string liveRaw: ""       // "21 / 30"
  property string tallyLabel: ""    // "Oui : 18 · Partiel : 6 · Non : 6"
  property bool hasNoteOverride: false
  property int missingCount: 0
  property string copyPath: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  property bool onlyDoubts: false
  property bool includeDetailsInExport: true

  onOpenedChanged: {
    if (opened) {
      noteField.text = root.note
      root.onlyDoubts = false
      root.includeDetailsInExport = true
    }
  }
  onNoteChanged: if (root.opened) noteField.text = root.note

  signal canceled()
  signal checkChanged(int rowIndex, int colIndex)
  signal noteSaved(string note)
  signal resetNoteOverrideRequested()
  signal copyOpenRequested()
  signal exportRequested(bool includeDetails)

  readonly property int columnCount: Math.max(1, (root.columns || []).length)
  readonly property int cellColWidth: Style.space(78)
  readonly property int cellsTotalWidth: cellColWidth * root.columnCount + Style.spacing.xs * root.columnCount

  function rowNeedsAttention(index) {
    if (root.checks[String(index)] === undefined) return true
    return String(root.doubts[String(index)] || "").trim() !== ""
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: parent.width - Style.space(40)
      height: parent.height - Style.space(40)
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
            text: "Questionnaire — " + root.studentLabel
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.WordWrap
            width: parent.width
            textFormat: Text.PlainText
          }

          Text {
            visible: root.missingCount > 0
            width: parent.width
            text: "⚠ " + root.missingCount + " item(s) non coché(s) par l'agent — ils comptent 0 dans le total tant que vous ne les tranchez pas vous-même."
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Row {
            spacing: Style.spacing.controlGap
            Button {
              text: "👁 Voir la copie"
              bordered: true
              enabled: root.copyPath !== ""
              foreground: root.foreground
              accent: root.accent
              onClicked: root.copyOpenRequested()
            }
            Button {
              text: root.onlyDoubts ? "👁 Tout afficher" : "🔎 Seulement les items à arbitrer"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.onlyDoubts = !root.onlyDoubts
            }
          }

          Column {
            id: table
            visible: (root.rows || []).length > 0
            width: parent.width
            spacing: Style.spacing.sm

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                width: parent.width - root.cellsTotalWidth
                text: "Items — cliquez une case pour la changer"
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Repeater {
                model: root.columns
                delegate: Column {
                  id: headerCell
                  required property string modelData
                  required property int index
                  width: root.cellColWidth
                  Text {
                    width: parent.width
                    text: headerCell.modelData
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.bold: true
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                  Text {
                    width: parent.width
                    text: QuestionnaireGrid.columnPointsLabel(headerCell.index, root.columnCount) + " pt"
                    horizontalAlignment: Text.AlignHCenter
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Repeater {
              model: root.rows
              delegate: Column {
                id: rowRoot
                required property var modelData
                required property int index
                width: table.width
                spacing: Style.spacing.xxs
                visible: !root.onlyDoubts || root.rowNeedsAttention(rowRoot.index)

                readonly property string doubt: String(root.doubts[String(rowRoot.index)] || "").trim()
                readonly property string answer: String(root.answers[String(rowRoot.index)] || "").trim()
                readonly property bool unchecked: root.checks[String(rowRoot.index)] === undefined

                Row {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width - root.cellsTotalWidth
                    text: (rowRoot.index + 1) + ".  " + QuestionnaireGrid.plainLabel(rowRoot.modelData.text)
                    color: rowRoot.unchecked ? Color.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: root.columnCount
                    delegate: Rectangle {
                      id: cell
                      required property int index
                      width: root.cellColWidth
                      height: Style.space(26)
                      radius: Style.cornerRadius
                      property bool checked: root.checks[String(rowRoot.index)] === cell.index
                      color: cell.checked
                        ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1

                      Text {
                        anchors.centerIn: parent
                        text: cell.checked ? "X" : ""
                        font.bold: true
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.checkChanged(rowRoot.index, cell.index)
                      }
                    }
                  }
                }

                // Ce que l'agent dit avoir lu sur la copie — la seule
                // façon de vérifier une case sans rouvrir le PDF.
                Text {
                  visible: rowRoot.answer !== ""
                  width: parent.width - root.cellsTotalWidth
                  text: "lu : " + rowRoot.answer
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }

                // L'arbitrage. Coloré, contrairement au "lu :" ci-dessus :
                // c'est ce que Gabriel doit valider ou contredire.
                Text {
                  visible: rowRoot.doubt !== ""
                  width: parent.width - root.cellsTotalWidth
                  text: "⚖ " + rowRoot.doubt
                  color: "#c98a3a"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Note"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

            Text {
              width: parent.width
              text: root.tallyLabel
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            Text {
              width: parent.width
              text: "Calcul automatique actuel : " + (root.liveRaw || "—") + "  →  " + (root.liveNote || "—")
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            Text {
              visible: root.hasNoteOverride
              width: parent.width
              text: "⚠ Note corrigée à la main — l'affichage ne suit plus le calcul automatique tant que vous ne cliquez pas sur « Revenir au calcul automatique »."
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.spacing.controlGap
              TextField {
                id: noteField
                width: Style.space(70)
                foreground: root.foreground
                accent: root.accent
              }
              Button {
                text: "💾 Enregistrer comme correction manuelle"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.noteSaved(noteField.text)
              }
              Button {
                visible: root.hasNoteOverride
                text: "↩ Revenir au calcul automatique"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.resetNoteOverrideRequested()
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Export"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

            Toggle {
              width: parent.width
              label: "Inclure les réponses lues et les arbitrages"
              description: "Décoché, le PDF ne contient que la grille cochée, le décompte et la note."
              checked: root.includeDetailsInExport
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.includeDetailsInExport = !root.includeDetailsInExport
            }

            Button {
              text: "📄 Exporter la grille en PDF"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.exportRequested(root.includeDetailsInExport)
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

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/CompetencyGrids.js" as CompetencyGrids

// "Compétences" overlay for one student's row in the Corrections table
// (grid-first pipeline, Gabriel 2026-09-27 — see [[gh-corrections-plugin]]):
// shows the grid CompetencyPromptBuilder's agent filled in, with each
// cell's justification alongside it for Gabriel to check before trusting
// it, and every cell directly clickable to override — same "grille comme
// grille de lecture, éditable" shape as the Eval. Compétences tab's own
// table (Panel.qml ~line 3612), reused here rather than reinvented.
Item {
  id: root

  property bool opened: false
  property string studentLabel: ""
  property var grid: null // CompetencyGrids grid object ({ id, name, rows })
  property var checks: ({}) // { "<rowIndex>": colIndex }
  property var justifications: ({}) // { "<rowIndex>": text }
  property string appreciation: ""
  // "Effective" note: Gabriel's hand-typed override if he's saved one,
  // otherwise the live automatic calculation — this is what pre-fills the
  // editable field below. liveNote is ALWAYS the automatic calculation,
  // shown alongside as a caption so he can see what "revert" would give
  // back even while looking at an override. A single exact value now
  // (Gabriel, 2026-09-27) — the earlier sévère/bienveillante range is
  // gone, computeWeightedNote() produces one number directly.
  property string note: ""
  property string liveNote: ""
  property bool hasNoteOverride: false
  property string copyPath: ""
  property bool regenerating: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Reset every time the popover opens so it never carries the previous
  // student's choice over (same posture as CorrectionLogPopover.expandOpen).
  property bool includeJustificationsInExport: false
  // "courte"/"moyenne"/"longue" — Gabriel, 2026-09-28, picked fresh each
  // time the popover opens rather than remembered, same one-shot posture
  // as the addendum field just below.
  property string appreciationLength: "moyenne"
  onOpenedChanged: {
    if (opened) {
      appreciationField.text = root.appreciation
      noteField.text = root.note
      addendumField.text = ""
      root.includeJustificationsInExport = false
      root.appreciationLength = "moyenne"
    }
  }
  onAppreciationChanged: if (root.opened) appreciationField.text = root.appreciation
  onNoteChanged: if (root.opened) noteField.text = root.note

  signal canceled()
  // Gabriel overriding one cell by hand — rowIndex is the row's position
  // in grid.rows (including non-checkable header rows, so it lines up
  // with StudentCorrection.competencyChecks as stored).
  signal checkChanged(int rowIndex, int colIndex)
  // Direct hand-edit of the appreciation text — bypasses the agent
  // entirely, same posture as CorrectionLogPopover.appreciationSaved.
  signal appreciationSaved(string text)
  // Direct hand-edit of the note — same posture.
  signal noteSaved(string note)
  // Re-runs the appreciation ONLY from the grid AS IT CURRENTLY STANDS,
  // without re-reading the copy and without touching the note — see
  // Gabriel, 2026-09-27. addendum is the optional one-shot text from the
  // field below.
  signal regenerateRequested(string addendum, string length)
  // Clears a hand-typed note override, going back to the automatic
  // calculation — independent from regenerateRequested (Gabriel,
  // 2026-09-27: the two must never be coupled).
  signal resetNoteOverrideRequested()
  signal copyOpenRequested()
  // includeJustifications: whether to print each cell's justification text
  // alongside the grid in the exported PDF — off by default (Gabriel,
  // 2026-09-27): the default export is just the table + appréciation + note.
  signal exportRequested(bool includeJustifications)

  readonly property int cellColWidth: Style.space(90)
  readonly property int cellsTotalWidth: cellColWidth * 4 + Style.spacing.xs * 4

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
          id: gridColumn
          width: card.width - card.contentLeftInset - card.contentRightInset
          spacing: Style.spacing.lg

          Text {
            text: "Compétences — " + root.studentLabel + (root.grid ? " (" + root.grid.name + ")" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.WordWrap
            width: parent.width
            textFormat: Text.PlainText
          }

          Text {
            visible: !root.grid
            text: "Aucune grille associée à cette évaluation."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "👁 Voir la copie"
            bordered: true
            enabled: root.copyPath !== ""
            foreground: root.foreground
            accent: root.accent
            onClicked: root.copyOpenRequested()
          }

          Column {
            id: table
            visible: root.grid !== null
            width: parent.width
            spacing: Style.spacing.sm

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                width: parent.width - root.cellsTotalWidth
                text: "Critères — cliquez une case pour la changer"
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Repeater {
                model: CompetencyGrids.COLUMNS
                delegate: Text {
                  required property string modelData
                  width: root.cellColWidth
                  text: modelData
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  font.bold: true
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Repeater {
              model: root.grid ? root.grid.rows : []
              delegate: Column {
                id: rowRoot
                required property var modelData
                required property int index
                width: table.width
                spacing: Style.spacing.xxs

                Rectangle {
                  visible: !rowRoot.modelData.checkable
                  width: parent.width
                  height: sectionText.implicitHeight + Style.space(8)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

                  Text {
                    id: sectionText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowRoot.modelData.text
                    font.bold: true
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }
                }

                Row {
                  width: parent.width
                  visible: rowRoot.modelData.checkable
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width - root.cellsTotalWidth
                    text: (rowRoot.modelData.level > 1 ? "    " : "") + rowRoot.modelData.text
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: 4
                    delegate: Rectangle {
                      id: cell
                      required property int index
                      width: root.cellColWidth
                      height: Style.space(28)
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

                // Agent's own reasoning for this cell — informational only,
                // Gabriel corrects the PALIER above if he disagrees rather
                // than editing this text (see [[gh-corrections-plugin]]).
                Text {
                  visible: rowRoot.modelData.checkable && !!root.justifications[String(rowRoot.index)]
                  width: parent.width - root.cellsTotalWidth
                  text: root.justifications[String(rowRoot.index)] || ""
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }
              }
            }
          }

          Column {
            visible: root.grid !== null
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Appréciation"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

            Rectangle {
              width: parent.width
              height: Style.space(96)
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
              border.width: 1
              ScrollView {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                TextArea {
                  id: appreciationField
                  wrapMode: TextArea.Wrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  background: null
                  placeholderText: "Corriger le texte de l'appréciation à la main…"
                }
              }
            }

            Text { text: "Points à prendre en compte pour la régénération (facultatif)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle {
              width: parent.width
              height: Style.space(56)
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
              border.width: 1
              ScrollView {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                TextArea {
                  id: addendumField
                  wrapMode: TextArea.Wrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  background: null
                  placeholderText: "Ex. « l'axe II, bien que complet, est bâclé »…"
                }
              }
            }

            Row {
              spacing: Style.spacing.controlGap

              // Wrapped in an Item matching the dropdown's full height
              // (label + gap + control) and anchored to its bottom, so
              // the buttons' boxes line up with the dropdown's actual
              // trigger control rather than its label row — same pattern
              // as maxCharsDropdown/generateButton in the "Eval.
              // Compétences" tab further up this file's Panel.qml.
              Item {
                width: saveAppreciationButton.implicitWidth
                height: lengthDropdown.implicitHeight
                Button {
                  id: saveAppreciationButton
                  anchors.bottom: parent.bottom
                  text: "💾 Enregistrer l'appréciation"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.appreciationSaved(appreciationField.text)
                }
              }

              Item {
                width: regenerateButton.implicitWidth
                height: lengthDropdown.implicitHeight
                Button {
                  id: regenerateButton
                  anchors.bottom: parent.bottom
                  text: root.regenerating ? "🔄 Régénération en cours…" : "🔄 Régénérer l'appréciation"
                  bordered: true
                  enabled: !root.regenerating
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.regenerateRequested(addendumField.text, root.appreciationLength)
                }
              }

              Dropdown {
                id: lengthDropdown
                label: "Longueur"
                options: [
                  { value: "courte", label: "Courte" },
                  { value: "moyenne", label: "Moyenne" },
                  { value: "longue", label: "Longue" }
                ]
                value: root.appreciationLength
                foreground: root.foreground
                background: root.background
                accent: root.accent
                fontFamily: root.fontFamily
                onChanged: function(value) { root.appreciationLength = value }
              }
            }
          }

          Column {
            visible: root.grid !== null
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Note"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

            // Always visible, even while an override is shown below — so
            // Gabriel can see at a glance what la grille + les points
            // donnent "automatiquement" sans avoir besoin de revenir en
            // arrière pour vérifier.
            Text {
              text: "Calcul automatique actuel : " + (root.liveNote || "—") + " / 20"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Text {
              visible: root.hasNoteOverride
              text: "⚠ Note corrigée à la main — l'affichage ci-dessous ne suit plus le calcul automatique tant que vous ne cliquez pas sur « Revenir au calcul automatique »."
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Row {
              spacing: Style.spacing.controlGap
              TextField {
                id: noteField
                width: Style.space(70)
                foreground: root.foreground
                accent: root.accent
              }
              Text { anchors.verticalCenter: parent.verticalCenter; text: "/ 20"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.body }
            }

            Row {
              spacing: Style.spacing.controlGap
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
            visible: root.grid !== null
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Export"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

            Toggle {
              width: parent.width
              label: "Inclure les commentaires par critère"
              description: "Sinon, le PDF ne contient que le tableau coché, l'appréciation et la plage de notes."
              checked: root.includeJustificationsInExport
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.includeJustificationsInExport = !root.includeJustificationsInExport
            }

            Button {
              text: "📄 Exporter en PDF"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.exportRequested(root.includeJustificationsInExport)
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

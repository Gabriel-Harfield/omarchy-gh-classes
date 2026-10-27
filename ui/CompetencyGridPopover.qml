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
  property var doubts: ({}) // { "<rowIndex>": true } — agent hesitated, Gabriel to decide
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
  // Which regeneration is running ("summary" | "bullets" | "both" | ""): only
  // the matching button says "en cours" (Gabriel, 2026-10-21); the others are
  // just greyed out with their normal label.
  property string regeneratingKind: ""
  // "Commentaire guidé" grids (Gabriel, 2026-10-15): the appreciation block is
  // replaced by the agent's bullet comments, shown and edited here exactly
  // like the Eval. Compétences tab's "Commentaires" section.
  property bool bulletsMode: false
  property var bullets: [] // [{ id, text, tag, isNew }]
  // Commentaire guidé PDF export (Gabriel, 2026-10-19): per section, "Afficher
  // dans le PDF" ticked = the section is exported, unticked = left out.
  property bool pdfShowAppreciation: true
  property bool pdfShowComments: true
  // Hybrid grid (Gabriel, 2026-10-23): plan of the copy as extracted by the
  // agent, shown to the right of the grid, plus its PDF toggle.
  property string plan: ""
  property bool pdfShowPlan: false
  readonly property bool hybrid: !!(root.grid && root.grid.hybrid)
  // Plan relevé (Gabriel, 2026-10-27): every writing grid carries the plan
  // the agent read off the copy. The panel on the right is hidden/shown by a
  // button, independently of the "plan dans le PDF" box.
  readonly property bool hasPlan: !!(root.grid && (root.grid.hybrid || root.grid.hasPlan))
  property bool showPlan: true
  readonly property bool planVisible: root.hasPlan && root.showPlan && root.plan !== ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Reset every time the popover opens so it never carries the previous
  // student's choice over (same posture as CorrectionLogPopover.expandOpen).
  property bool includeJustificationsInExport: false
  onOpenedChanged: {
    if (!opened) pendingRemoveBulletId = ""
    if (opened) {
      appreciationField.text = root.appreciation
      summaryField.text = root.appreciation
      noteField.text = root.note
      bulletDraftField.text = ""
      root.includeJustificationsInExport = false
    }
  }
  onAppreciationChanged: if (root.opened) { appreciationField.text = root.appreciation; summaryField.text = root.appreciation }
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
  // Clears a hand-typed note override, going back to the automatic
  // calculation.
  signal resetNoteOverrideRequested()
  signal copyOpenRequested()
  // includeJustifications: whether to print each cell's justification text
  // alongside the grid in the exported PDF — off by default (Gabriel,
  // 2026-09-27): the default export is just the table + appréciation + note.
  signal exportRequested(bool includeJustifications)
  signal bulletAdded(string text)
  signal bulletRemoved(string id)
  signal bulletBanked(string id)
  signal bulletEdited(string id, string text)
  signal bankInsertRequested()
  signal bulletsRegenerateRequested(int cap)
  // Popover-local zoom (the panel-wide one does not reach popovers).
  property real zoom: 1.0
  // Id of the task awaiting delete confirmation ("" = none).
  property string pendingRemoveBulletId: ""
  signal zoomChangeRequested(real zoom)
  // field: "pdfShowAppreciation" | "pdfShowComments"
  signal pdfFlagChanged(string field, bool value)

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

        // Gabriel, 2026-10-20: the panel-wide zoom does not reach popovers
        // (they sit above the zoomed content), so this one has its own, same
        // scale-transform trick as Panel.qml's zoomWrapper: the wrapper
        // reports the REAL scaled size to the ScrollView.
        Item {
          id: zoomWrapper
          width: gridColumn.width * root.zoom
          height: gridColumn.height * root.zoom
          implicitWidth: width
          implicitHeight: height

          Column {
            id: gridColumn
            width: (card.width - card.contentLeftInset - card.contentRightInset) / root.zoom
            scale: root.zoom
            transformOrigin: Item.TopLeft
            spacing: Style.spacing.lg

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
                visible: root.hasPlan
                text: root.showPlan ? "🗺 Masquer le plan" : "🗺 Afficher le plan"
                bordered: true
                enabled: root.plan !== ""
                foreground: root.foreground
                accent: root.accent
                tooltipText: root.plan !== "" ? "Affiche ou masque le plan relevé dans la copie, à droite de la grille" : "Aucun plan relevé pour cette copie (relancer la correction)"
                onClicked: root.showPlan = !root.showPlan
              }
            }

            Toggle {
              visible: root.hasPlan && root.plan !== ""
              width: parent.width
              label: "Afficher le plan dans le PDF"
              checked: root.pdfShowPlan
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.pdfFlagChanged("pdfShowPlan", !root.pdfShowPlan)
            }

            Row {
              id: gridRow
              visible: root.grid !== null
              width: parent.width
              spacing: Style.spacing.lg
              layoutDirection: Qt.LeftToRight
            Column {
              id: table
              width: root.planVisible ? Math.round(gridRow.width * 0.64) : gridRow.width
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
                      font.italic: !!rowRoot.modelData.italic
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
                      text: (rowRoot.modelData.level > 1 ? "    " : "") + (root.doubts[String(rowRoot.index)] ? "⚠ " : "") + (root.hybrid ? (rowRoot.modelData.owner === "teacher" ? "👤 " : "🤖 ") : "") + rowRoot.modelData.text
                      font.italic: !!rowRoot.modelData.italic
                      color: root.doubts[String(rowRoot.index)] ? "#c98a3a" : root.foreground
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

                  Text {
                    visible: rowRoot.modelData.checkable && !!root.doubts[String(rowRoot.index)]
                    width: parent.width - root.cellsTotalWidth
                    text: "⚠ L'agent a hésité entre deux paliers sur ce critère : à toi de trancher (cliquer une case valide ton choix)."
                    color: "#c98a3a"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    wrapMode: Text.WordWrap
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
            Rectangle {
              id: planBox
              visible: root.planVisible
              width: gridRow.width - table.width - gridRow.spacing
              height: Math.max(planColumn.implicitHeight + Style.space(20), Style.space(160))
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
              border.width: 1

              Column {
                id: planColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.spacing.sm

                Text {
                  text: "Plan de la copie"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: root.plan !== "" ? root.plan : "Aucun plan extrait pour cette copie (relancer la correction)."
                  color: root.plan !== "" ? root.foreground : Qt.darker(root.foreground, 1.6)
                  font.italic: root.plan === ""
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }
              }
            }
            }

            Column {
              visible: root.grid !== null && root.bulletsMode
              width: parent.width
              spacing: Style.spacing.xxs

              Text { text: "Appréciation"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

              Rectangle {
                width: parent.width
                height: Style.space(110)
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
                    id: summaryField
                    wrapMode: TextArea.Wrap
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    background: null
                    placeholderText: "Facultatif — écrite à la main. Si ce champ reste vide, la section n'apparaît pas dans le PDF."
                  }
                }
              }

              Row {
                spacing: Style.spacing.controlGap

                Button {
                  text: "💾 Enregistrer l'appréciation"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.appreciationSaved(summaryField.text)
                }
              }

              Toggle {
                width: parent.width
                label: "Afficher dans le PDF"
                checked: root.pdfShowAppreciation
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.pdfFlagChanged("pdfShowAppreciation", !root.pdfShowAppreciation)
              }
            }

            Column {
              visible: root.grid !== null && root.bulletsMode
              width: parent.width
              spacing: Style.spacing.xxs

              Text { text: "Exercice de correction"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

              Text {
                visible: root.bullets.length === 0
                width: parent.width
                text: "Aucune tâche de correction pour cette copie."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.bullets
                delegate: Row {
                  id: bulletRow
                  required property var modelData
                  width: parent ? parent.width - Style.space(14) : 0  // marge pour la barre de défilement
                  spacing: Style.spacing.sm

                  // Per-copy edit (Gabriel, 2026-10-27): rewords this task for
                  // THIS copy only — the bank entry it came from is untouched.
                  property bool editing: false

                  Text {
                    visible: !bulletRow.editing
                    width: parent.width - bulletButtons.width - parent.spacing
                    text: "☐ " + bulletRow.modelData.text
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                  }

                  TextField {
                    id: bulletEditField
                    visible: bulletRow.editing
                    width: parent.width - bulletButtons.width - parent.spacing
                    foreground: root.foreground
                    accent: root.accent
                    Keys.onReturnPressed: { root.bulletEdited(bulletRow.modelData.id, text); bulletRow.editing = false }
                    Keys.onEnterPressed: { root.bulletEdited(bulletRow.modelData.id, text); bulletRow.editing = false }
                    Keys.onEscapePressed: bulletRow.editing = false
                  }

                  Row {
                    id: bulletButtons
                    spacing: Style.spacing.xs

                    Button {
                      visible: !bulletRow.editing
                      text: "✏ Modifier"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Reformule cette tâche pour cette copie uniquement (la banque n'est pas modifiée)"
                      onClicked: { bulletEditField.text = bulletRow.modelData.text; bulletRow.editing = true; bulletEditField.forceActiveFocus() }
                    }
                    Button {
                      visible: bulletRow.editing
                      text: "✔ Valider"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: { root.bulletEdited(bulletRow.modelData.id, bulletEditField.text); bulletRow.editing = false }
                    }
                    Button {
                      visible: bulletRow.editing
                      text: "Annuler"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: bulletRow.editing = false
                    }
                    Button {
                      visible: !bulletRow.editing
                      text: "✕"
                      bordered: true
                      foreground: Color.urgent
                      accent: Color.urgent
                      tooltipText: "Supprime cette tâche (une confirmation sera demandée)"
                      onClicked: root.pendingRemoveBulletId = bulletRow.modelData.id
                    }
                    Button {
                      visible: bulletRow.modelData.isNew
                      text: "＋ Banque"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Enregistre ce commentaire dans la banque pour le réutiliser plus tard"
                      onClicked: root.bulletBanked(bulletRow.modelData.id)
                    }
                  }
                }
              }

              TextField {
                id: bulletDraftField
                width: parent.width
                placeholderText: "Nouveau commentaire…"
                foreground: root.foreground
                accent: root.accent
                Keys.onReturnPressed: { root.bulletAdded(bulletDraftField.text); bulletDraftField.text = "" }
                Keys.onEnterPressed: { root.bulletAdded(bulletDraftField.text); bulletDraftField.text = "" }
              }

              Row {
                spacing: Style.spacing.controlGap

                Button {
                  text: "➕ Ajouter"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  tooltipText: "Ajoute ce texte comme commentaire pour cet élève uniquement"
                  onClicked: { root.bulletAdded(bulletDraftField.text); bulletDraftField.text = "" }
                }
                Button {
                  text: "📚 Insérer depuis la banque"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  tooltipText: "Parcourir/filtrer les commentaires déjà enregistrés"
                  onClicked: root.bankInsertRequested()
                }
              }

              Button {
                id: regenerateBulletsButton
                text: (root.regenerating && (root.regeneratingKind === "bullets" || root.regeneratingKind === "both")) ? "🔄 Régénération en cours…" : "🔄 Régénérer l'exercice"
                bordered: true
                enabled: !root.regenerating
                foreground: root.foreground
                accent: root.accent
                tooltipText: "Réécrit la liste (5 tâches au plus, des critères les moins réussis aux plus réussis) depuis la grille telle qu'elle est maintenant, sans relire la copie. Remplace la liste actuelle."
                onClicked: root.bulletsRegenerateRequested(0)
              }

              Toggle {
                width: parent.width
                label: "Afficher dans le PDF"
                checked: root.pdfShowComments
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.pdfFlagChanged("pdfShowComments", !root.pdfShowComments)
              }
            }

            Column {
              visible: root.grid !== null && !root.bulletsMode
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
                    placeholderText: "Facultatif — écrite à la main. Si ce champ reste vide, la section n'apparaît pas dans le PDF."
                  }
                }
              }

              Button {
                text: "💾 Enregistrer l'appréciation"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.appreciationSaved(appreciationField.text)
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
                text: root.liveNote ? ("Calcul automatique actuel : " + root.liveNote + " / 20") : (root.hybrid ? "À compléter : la note sera calculée quand tous les critères (👤 enseignant compris) seront cochés." : "Calcul automatique actuel : — / 20")
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

  Rectangle {
    anchors.fill: parent
    visible: root.pendingRemoveBulletId !== ""
    color: Util.alpha(root.background, 0.6)
    z: 10

    MouseArea { anchors.fill: parent; onClicked: root.pendingRemoveBulletId = "" }

    BorderSurface {
      width: Style.space(380)
      height: confirmColumn.implicitHeight + Style.space(36)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: confirmColumn
        width: parent.width - Style.space(36)
        anchors.centerIn: parent
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          text: "Supprimer cette tâche de correction ? Cette action est irréversible."
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
        Row {
          spacing: Style.spacing.controlGap
          Button {
            text: "Supprimer"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              var id = root.pendingRemoveBulletId
              root.pendingRemoveBulletId = ""
              root.bulletRemoved(id)
            }
          }
          Button {
            text: "Annuler"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.pendingRemoveBulletId = ""
          }
        }
      }
    }
  }
}

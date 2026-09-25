import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// "Log" overlay for one student's row in the Corrections table: shows why
// the correction agent flagged (or didn't flag) this copy for review, or
// the run's error message if the correction failed outright. Since
// 2026-09-18: a structured log (one item per line, see
// CorrectionsStore.parseLogItems) renders as individually addressable
// blocks Gabriel can validate/ignore/comment on — an older free-text log
// (written before this format existed) falls back to the original single
// block.
Item {
  id: root

  property bool opened: false
  property string studentLabel: ""
  property string status: "idle" // idle | running | done | error
  property string log: ""
  property bool needsReview: false
  property bool reviewed: false
  property string error: ""
  property string appreciation: ""
  property string addendum: ""
  property string copyPath: ""
  property var logItems: [] // [string, ...] — parsed from `log`, see CorrectionsStore.parseLogItems
  property var logItemStates: ({}) // { "<index>": { status, comment } }
  property bool reformulating: false
  // Whether the enlarged "Appréciation" editor overlay is open — reset
  // every time the popover opens so it never carries over between students.
  property bool expandOpen: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property color warningColor: "#c98a3a"
  property string fontFamily: Style.font.family

  signal canceled()
  signal reviewedToggled()
  // Direct hand-edit of the appreciation text — bypasses the agent
  // entirely, for a fix too small to justify a whole re-run.
  signal appreciationSaved(string text)
  // Saves the one-shot addendum without triggering a correction (ex. to
  // jot it down now and relaunch later from the row's own button).
  signal addendumSaved(string text)
  // Saves the addendum (whatever is currently typed, even if "Enregistrer"
  // was never clicked) AND immediately queues a re-run for this student.
  signal recorrectRequested(string addendumText)
  // One log item's triage changed: status is "validated" | "ignored" |
  // "commented" (comment only meaningful for the latter).
  signal logItemStatusChanged(int index, string status, string comment)
  // Cheaper alternative to recorrectRequested: revise the EXISTING
  // appreciation from whatever items are currently "commented", without
  // re-reading the copy at all.
  signal reformulateRequested()
  // Opens the copy in the system's default PDF viewer (same as the row's
  // own "👁 Voir la copie" button) — Gabriel tiles it next to this popover
  // himself via Hyprland rather than embedding a PDF renderer here
  // (2026-09-18: rejected an embedded QtWebEngine view as too heavy).
  signal copyOpenRequested()

  readonly property bool hasItemizedLog: root.status === "done" && root.needsReview && root.logItems.length > 0

  function hasCommentedItems() {
    for (var k in root.logItemStates) {
      if (root.logItemStates[k] && root.logItemStates[k].status === "commented") return true
    }
    return false
  }

  function itemStateFor(index) {
    var s = root.logItemStates[String(index)]
    return s ? s : { status: "pending", comment: "" }
  }

  function itemColorFor(index) {
    var st = root.itemStateFor(index).status
    if (st === "validated") return root.accent
    if (st === "ignored") return Qt.darker(root.foreground, 1.6)
    if (st === "commented") return root.warningColor
    return root.foreground
  }

  onOpenedChanged: {
    if (opened) {
      appreciationField.text = root.appreciation
      addendumField.text = root.addendum
    }
    root.expandOpen = false
  }
  // Panel.qml declares `opened` before `appreciation`/`addendum` on this
  // component, and both are bound off the same studentId change — QML
  // evaluates sibling bindings in declaration order, so onOpenedChanged
  // above can fire and copy a still-stale (often empty) `appreciation`
  // before that property's own binding has caught up to the new student.
  // These re-sync as soon as the up-to-date value actually lands, and also
  // keep the box current if a recorrection/reformulation finishes while
  // the popover is still open.
  onAppreciationChanged: if (root.opened) appreciationField.text = root.appreciation
  onAddendumChanged: if (root.opened) addendumField.text = root.addendum

  function bodyText() {
    if (root.status === "error") return root.error !== "" ? root.error : "La correction a échoué."
    if (root.status === "running") return "Correction en cours…"
    if (root.status !== "done") return "Cette copie n'a pas encore été corrigée."
    if (root.needsReview) return root.log !== "" ? root.log : "L'agent signale un point à vérifier."
    return "RAS — l'agent n'a rien à signaler sur cette copie."
  }

  function bodyColor() {
    if (root.status === "error") return Color.urgent
    if (root.status === "done" && root.needsReview && !root.reviewed) return root.warningColor
    return Qt.darker(root.foreground, 1.3)
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      // GH Classes' own window (Panel.qml's FloatingWindow) is a real,
      // resizable Hyprland window with no maximum size — Gabriel, 2026-09-18,
      // wanted the log editor itself to actually use that space rather than
      // stay capped at a small fixed card regardless of how big the window
      // is. This margin-only sizing lets it fill nearly the whole window.
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
            text: "Log — " + root.studentLabel
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.WordWrap
            width: parent.width
            textFormat: Text.PlainText
          }

          Button {
            text: "👁 Voir la copie"
            bordered: true
            enabled: root.copyPath !== ""
            foreground: root.foreground
            accent: root.accent
            onClicked: root.copyOpenRequested()
          }

          // ---- simple status line: error / running / not-done / RAS, or
          // the raw text of an older log that predates the itemized format
          Rectangle {
            visible: !root.hasItemizedLog
            width: parent.width
            height: bodyTextItem.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.bodyColor().r, root.bodyColor().g, root.bodyColor().b, 0.08)
            border.color: Qt.rgba(root.bodyColor().r, root.bodyColor().g, root.bodyColor().b, 0.35)
            border.width: 1

            Text {
              id: bodyTextItem
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              text: root.bodyText()
              color: root.bodyColor()
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
          }

          // ---- itemized log: one block per point, each individually
          // validated / ignored / commented
          Column {
            visible: root.hasItemizedLog
            width: parent.width
            spacing: Style.spacing.md

            Text { text: "Points relevés"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }

            Repeater {
              model: root.logItems
              delegate: Column {
                id: logItemRow
                required property string modelData
                required property int index
                width: parent.width
                spacing: Style.spacing.xs

                readonly property var itemState: root.itemStateFor(logItemRow.index)
                readonly property color itemColor: root.itemColorFor(logItemRow.index)
                property bool commentOpen: false

                Rectangle {
                  width: parent.width
                  height: itemText.implicitHeight + Style.space(16)
                  radius: Style.cornerRadius
                  color: Qt.rgba(logItemRow.itemColor.r, logItemRow.itemColor.g, logItemRow.itemColor.b, 0.08)
                  border.color: Qt.rgba(logItemRow.itemColor.r, logItemRow.itemColor.g, logItemRow.itemColor.b, 0.35)
                  border.width: 1

                  Text {
                    id: itemText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(10)
                    text: "• " + logItemRow.modelData
                    color: logItemRow.itemColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.controlGap
                  Button {
                    text: logItemRow.itemState.status === "validated" ? "✔ Validé" : "✔ Valider"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: { logItemRow.commentOpen = false; root.logItemStatusChanged(logItemRow.index, "validated", "") }
                  }
                  Button {
                    text: logItemRow.itemState.status === "ignored" ? "🚫 Ignoré" : "🚫 Ignorer"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: { logItemRow.commentOpen = false; root.logItemStatusChanged(logItemRow.index, "ignored", "") }
                  }
                  Button {
                    text: "💬 Commenter"
                    bordered: true
                    foreground: root.foreground
                    accent: logItemRow.itemState.status === "commented" ? root.warningColor : root.accent
                    onClicked: logItemRow.commentOpen = !logItemRow.commentOpen
                  }
                }

                Column {
                  visible: logItemRow.commentOpen || logItemRow.itemState.status === "commented"
                  width: parent.width
                  spacing: Style.spacing.xxs
                  TextField {
                    id: itemCommentField
                    width: parent.width
                    text: logItemRow.itemState.comment
                    placeholderText: "Instruction pour l'agent sur ce point précis…"
                    foreground: root.foreground
                    accent: root.accent
                    maximumLength: 500
                  }
                  Button {
                    text: "Enregistrer ce commentaire"
                    bordered: true
                    enabled: itemCommentField.text.trim() !== ""
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: {
                      root.logItemStatusChanged(logItemRow.index, "commented", itemCommentField.text.trim())
                      logItemRow.commentOpen = false
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.status === "done"
            width: parent.width
            spacing: Style.spacing.xxs

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap
              Text { anchors.verticalCenter: parent.verticalCenter; text: "Appréciation"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: "🔍 Agrandir"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: {
                  expandField.text = appreciationField.text
                  root.expandOpen = true
                }
              }
            }
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
            Row {
              spacing: Style.spacing.controlGap
              Button {
                text: "💾 Enregistrer l'appréciation"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.appreciationSaved(appreciationField.text)
              }
              Button {
                text: root.reformulating ? "✨ Reformulation en cours…" : "✨ Reformuler à partir des commentaires"
                bordered: true
                // The shared Button component has no built-in visual state for
                // `enabled: false` (no dimming) — without this, a disabled
                // button looks identical to an active one and a click on it
                // silently does nothing. Dim it by hand so "no commented item
                // yet" is visible at a glance instead of looking like a bug.
                enabled: !root.reformulating && root.hasCommentedItems()
                foreground: (!root.reformulating && root.hasCommentedItems()) ? root.foreground : Qt.darker(root.foreground, 1.7)
                accent: (!root.reformulating && root.hasCommentedItems()) ? root.accent : Qt.darker(root.foreground, 1.7)
                onClicked: root.reformulateRequested()
              }
            }
          }

          Column {
            visible: root.status === "done" || root.status === "error"
            width: parent.width
            spacing: Style.spacing.xxs

            Text { text: "Complément pour l'agent (usage unique, à la prochaine correction complète)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            Rectangle {
              width: parent.width
              height: Style.space(72)
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
                  font.pixelSize: Style.font.body
                  background: null
                  placeholderText: "Ex. \"le mot que tu lis comme X est en fait Y\"…"
                }
              }
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                text: "💾 Enregistrer"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.addendumSaved(addendumField.text)
              }
              Button {
                text: "🔁 Recorriger entièrement avec ce complément"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.recorrectRequested(addendumField.text)
              }
            }
          }

          Row {
            spacing: Style.spacing.controlGap

            Button {
              visible: root.status === "done"
              text: root.reviewed ? "✔ Vérifié" : "☐ Marquer comme vérifié"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.reviewedToggled()
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

  // Enlarged read/edit view for the appreciation — a long AI-generated text
  // is unreadable in the small fixed box above, so this reuses the same
  // draft (unsaved edits carry over both ways) in a much bigger card.
  Rectangle {
    visible: root.expandOpen
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea {
      anchors.fill: parent
      onClicked: {
        appreciationField.text = expandField.text
        root.expandOpen = false
      }
    }

    BorderSurface {
      id: expandCard
      width: parent.width - Style.space(40)
      height: parent.height - Style.space(40)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: expandCard.contentTopInset
        anchors.rightMargin: expandCard.contentRightInset
        anchors.bottomMargin: expandCard.contentBottomInset
        anchors.leftMargin: expandCard.contentLeftInset

        Text {
          id: expandTitle
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          text: "Appréciation — " + root.studentLabel
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        Row {
          id: expandButtons
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          spacing: Style.spacing.controlGap
          Button {
            text: "💾 Enregistrer l'appréciation"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              appreciationField.text = expandField.text
              root.appreciationSaved(expandField.text)
              root.expandOpen = false
            }
          }
          Button {
            text: "Fermer"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              appreciationField.text = expandField.text
              root.expandOpen = false
            }
          }
        }

        Rectangle {
          anchors.top: expandTitle.bottom
          anchors.topMargin: Style.spacing.lg
          anchors.bottom: expandButtons.top
          anchors.bottomMargin: Style.spacing.lg
          anchors.left: parent.left
          anchors.right: parent.right
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
              id: expandField
              wrapMode: TextArea.Wrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              background: null
              placeholderText: "Corriger le texte de l'appréciation à la main…"
            }
          }
        }
      }
    }
  }
}

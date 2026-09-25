import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// "Assistant — Consignes" — builds a consignes.md from a fixed skeleton
// agreed with Gabriel 2026-09-17/18: a "Paramètres de l'évaluation" block
// (nature, type, durée, bienveillance, etc. — all structured choices, see
// PARAM_* maps below), then Cadre du devoir (free text), then criteria
// classified under Méthode / Contenu / Expression écrite, plus an optional
// Barème indicatif. The 3-category split mirrors what
// CorrectionPromptBuilder.js now hardcodes for the appreciation itself, so
// the correction agent never has to guess which category a criterion
// belongs to. Emits the assembled markdown; Panel.qml owns the actual file
// write (existence check + overwrite confirmation included).
//
// Design call (flagged to Gabriel, not explicitly specified by him): the
// "Paramètres" answers are rendered as plain markdown prose that the
// correction agent reads like the rest of consignes.md — NOT separate
// structured fields injected directly into CorrectionPromptBuilder.js the
// way vouvoiement/no-vocative/3-paragraphs are. Keeps the wizard
// self-contained and these settings reusable/editable by hand in the
// resulting file; if reliability turns out to be a problem in practice,
// some of these (esp. bienveillance/écart/surinterprétation/détail) are
// candidates to promote to hardcoded per-évaluation prompt parameters later.
Item {
  id: root

  property bool opened: false
  property string initialPath: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal canceled()
  signal generateRequested(string path, string markdown)

  // ---- Paramètres de l'évaluation ----
  property string paramNature: "dst"
  property string paramType: "formative"
  property int paramDuree: 60
  property int paramBienveillance: 5
  property bool paramNotesAcceptees: false
  property bool paramCompletudeExigee: true
  property real paramEcart: 2
  property string paramSurinterpretation: "neutre"
  property string paramDetail: "moyen"

  property string cadre: ""
  property string bareme: ""
  property var methodeCriteria: []
  property var contenuCriteria: []
  property var expressionCriteria: []

  readonly property var natureOptions: [
    { value: "dst", label: "Devoir sur table" },
    { value: "blanc", label: "Épreuve blanche" },
    { value: "tp_individuel", label: "TP individuel" },
    { value: "tp_groupe", label: "TP en groupe" }
  ]
  readonly property var typeOptions: [
    { value: "diagnostique", label: "Diagnostique" },
    { value: "formative", label: "Formative" },
    { value: "sommative", label: "Sommative" }
  ]
  readonly property var surinterpretationOptions: [
    { value: "strict", label: "Strict" },
    { value: "neutre", label: "Neutre" },
    { value: "permissif", label: "Permissif" }
  ]
  readonly property var detailOptions: [
    { value: "faible", label: "Faible" },
    { value: "moyen", label: "Moyen" },
    { value: "eleve", label: "Élevé" }
  ]

  // Full explanations injected into the generated file (not just the
  // label) so the agent has the complete nuance Gabriel wrote out, 2026-09-18.
  readonly property var surinterpretationText: ({
    strict: "Strict : aucune surinterprétation n'est permise ; si l'agent ne comprend pas ce qu'il lit, il le signale dans le log et passe à la suite sans deviner.",
    neutre: "Neutre : l'agent peut combler une lacune laissée par l'élève afin d'en comprendre le sens, mais le signale et l'évite autant que possible, pour ne pas biaiser son appréciation finale.",
    permissif: "Permissif : l'agent surinterprète les propos de l'élève si besoin — utile par exemple pour évaluer une prise de notes d'analyse directement sur un extrait."
  })
  // "Moyen" had two overlapping descriptions in Gabriel's original spec
  // (2026-09-18) — kept the one that reads as a coherent middle point
  // between "faible" and "élevé" (variable length, may allude to/cite the
  // copy). Flagged to him; easy to edit in the generated file if wrong.
  readonly property var detailText: ({
    faible: "Faible : appréciation elliptique, sans trop de détails, évasive.",
    moyen: "Moyen : appréciation de taille variable selon la quantité de choses à dire sur la copie, peut citer ou faire allusion à des passages de la copie évaluée.",
    eleve: "Élevé : appréciation détaillée, commentant certains passages (citation ou allusion) afin d'illustrer l'appréciation."
  })

  onOpenedChanged: if (opened) {
    savePathField.text = root.initialPath
    cadreField.text = ""
    baremeField.text = ""
    root.cadre = ""
    root.bareme = ""
    root.methodeCriteria = []
    root.contenuCriteria = []
    root.expressionCriteria = []
    newMethodeField.text = ""
    newContenuField.text = ""
    newExpressionField.text = ""
    root.paramNature = "dst"
    root.paramType = "formative"
    root.paramDuree = 60
    root.paramBienveillance = 5
    root.paramNotesAcceptees = false
    root.paramCompletudeExigee = true
    root.paramEcart = 2
    root.paramSurinterpretation = "neutre"
    root.paramDetail = "moyen"
  }

  function labelFor(options, value) {
    for (var i = 0; i < options.length; i++) if (options[i].value === value) return options[i].label
    return value
  }

  function listFor(category) {
    return category === "methode" ? root.methodeCriteria : category === "contenu" ? root.contenuCriteria : root.expressionCriteria
  }

  function setListFor(category, list) {
    if (category === "methode") root.methodeCriteria = list
    else if (category === "contenu") root.contenuCriteria = list
    else root.expressionCriteria = list
  }

  function addCriterion(category, text) {
    var t = String(text || "").trim()
    if (!t) return
    root.setListFor(category, root.listFor(category).concat([t]))
  }

  function removeCriterion(category, index) {
    var out = root.listFor(category).slice()
    out.splice(index, 1)
    root.setListFor(category, out)
  }

  function buildMarkdown() {
    var lines = []
    lines.push("# Paramètres de l'évaluation")
    lines.push("")
    lines.push("- Nature de l'évaluation : " + root.labelFor(root.natureOptions, root.paramNature))
    lines.push("- Type d'évaluation : " + root.labelFor(root.typeOptions, root.paramType))
    lines.push("- Durée de l'épreuve : " + root.paramDuree + " minutes")
    lines.push("- Niveau de bienveillance : " + root.paramBienveillance + "/10 (0 = très sévère, 10 = très bienveillant)")
    lines.push("- Prise de notes acceptée : " + (root.paramNotesAcceptees ? "Oui" : "Non (rédaction complète exigée)"))
    lines.push("- Le sujet doit être traité intégralement : " + (root.paramCompletudeExigee ? "Oui" : "Non"))
    lines.push("- Écart entre la note sévère et la note bienveillante : " + root.paramEcart.toFixed(1) + " points (la note neutre est leur moyenne)")
    lines.push("- Niveau de surinterprétation autorisé — " + root.surinterpretationText[root.paramSurinterpretation])
    lines.push("- Niveau de détail de l'appréciation — " + root.detailText[root.paramDetail])
    lines.push("")
    lines.push("# Cadre du devoir")
    lines.push("")
    lines.push(String(root.cadre || "").trim())
    lines.push("")
    lines.push("# Méthode")
    root.methodeCriteria.forEach(function(c) { lines.push("## " + c) })
    lines.push("")
    lines.push("# Contenu")
    root.contenuCriteria.forEach(function(c) { lines.push("## " + c) })
    lines.push("")
    lines.push("# Expression écrite")
    root.expressionCriteria.forEach(function(c) { lines.push("## " + c) })
    var baremeTrim = String(root.bareme || "").trim()
    if (baremeTrim !== "") {
      lines.push("")
      lines.push("# Barème indicatif")
      lines.push("")
      lines.push(baremeTrim)
    }
    return lines.join("\n") + "\n"
  }

  readonly property bool canGenerate: savePathField.text.trim() !== ""
    && (root.methodeCriteria.length > 0 || root.contenuCriteria.length > 0 || root.expressionCriteria.length > 0)

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      // Same fix as CorrectionLogPopover.qml (Gabriel, 2026-09-18): use the
      // real, resizable FloatingWindow's actual space instead of a small
      // fixed cap.
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
            text: "Assistant — Consignes"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: "Structure fixe : paramètres de l'évaluation, cadre du devoir, puis des critères classés sous Méthode / Contenu / Expression écrite — l'agent produit son appréciation dans ce même ordre."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          // ---- Paramètres de l'évaluation ----
          Column {
            width: parent.width
            spacing: Style.spacing.md
            Text { text: "Paramètres de l'évaluation"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }

            Dropdown {
              width: parent.width
              label: "Nature de l'évaluation"
              options: root.natureOptions
              value: root.paramNature
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.paramNature = v }
            }

            Dropdown {
              width: parent.width
              label: "Type d'évaluation"
              options: root.typeOptions
              value: root.paramType
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.paramType = v }
            }

            NumberField {
              label: "Durée de l'épreuve (minutes)"
              value: root.paramDuree
              from: 5
              to: 600
              stepSize: 5
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onModified: function(v) { root.paramDuree = v }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xxs
              Text { text: "Niveau de bienveillance : " + root.paramBienveillance + "/10"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              PanelSlider {
                width: parent.width
                bar: null
                minimum: 0
                maximum: 10
                integer: true
                value: root.paramBienveillance
                onMoved: function(v) { root.paramBienveillance = v }
              }
            }

            Toggle {
              width: parent.width
              label: "Prise de notes acceptée"
              description: "Sinon, une rédaction complète est exigée."
              checked: root.paramNotesAcceptees
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.paramNotesAcceptees = !root.paramNotesAcceptees
            }

            Toggle {
              width: parent.width
              label: "Sujet à traiter intégralement"
              description: "Coché = une copie incomplète doit être signalée comme telle."
              checked: root.paramCompletudeExigee
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.paramCompletudeExigee = !root.paramCompletudeExigee
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xxs
              Text { text: "Écart sévère / bienveillante : " + root.paramEcart.toFixed(1) + " pts (neutre = moyenne)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              PanelSlider {
                width: parent.width
                bar: null
                minimum: 0.5
                maximum: 3
                step: 0.5
                value: root.paramEcart
                onMoved: function(v) { root.paramEcart = Math.round(v * 2) / 2 }
              }
            }

            Dropdown {
              width: parent.width
              label: "Niveau de surinterprétation"
              options: root.surinterpretationOptions
              value: root.paramSurinterpretation
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.paramSurinterpretation = v }
            }

            Dropdown {
              width: parent.width
              label: "Niveau de détail de l'appréciation"
              options: root.detailOptions
              value: root.paramDetail
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.paramDetail = v }
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          // ---- Cadre du devoir ----
          Column {
            width: parent.width
            spacing: Style.spacing.xxs
            Text { text: "Cadre du devoir"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            Rectangle {
              width: parent.width
              height: Style.space(88)
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
                  id: cadreField
                  wrapMode: TextArea.Wrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  background: null
                  placeholderText: "Contexte, niveau, attentes générales…"
                  onTextChanged: root.cadre = text
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          // ---- Méthode ----
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            Text { text: "Méthode"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
            Repeater {
              model: root.methodeCriteria
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: Math.max(mLabel.implicitHeight, mRemove.implicitHeight)
                Text { id: mLabel; anchors.left: parent.left; anchors.right: mRemove.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; text: "• " + modelData; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; textFormat: Text.PlainText }
                Button { id: mRemove; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "✕"; bordered: true; foreground: root.foreground; accent: Color.urgent; onClicked: root.removeCriterion("methode", index) }
              }
            }
            Item {
              width: parent.width
              height: Math.max(newMethodeField.implicitHeight, addMethodeButton.implicitHeight)
              TextField { id: newMethodeField; anchors.left: parent.left; anchors.right: addMethodeButton.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; placeholderText: "Nouveau critère…"; foreground: root.foreground; accent: root.accent; maximumLength: 200 }
              Button { id: addMethodeButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "+ Ajouter"; bordered: true; enabled: newMethodeField.text.trim() !== ""; foreground: root.foreground; accent: root.accent; onClicked: { root.addCriterion("methode", newMethodeField.text); newMethodeField.text = "" } }
            }
          }

          // ---- Contenu ----
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            Text { text: "Contenu"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
            Repeater {
              model: root.contenuCriteria
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: Math.max(cLabel.implicitHeight, cRemove.implicitHeight)
                Text { id: cLabel; anchors.left: parent.left; anchors.right: cRemove.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; text: "• " + modelData; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; textFormat: Text.PlainText }
                Button { id: cRemove; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "✕"; bordered: true; foreground: root.foreground; accent: Color.urgent; onClicked: root.removeCriterion("contenu", index) }
              }
            }
            Item {
              width: parent.width
              height: Math.max(newContenuField.implicitHeight, addContenuButton.implicitHeight)
              TextField { id: newContenuField; anchors.left: parent.left; anchors.right: addContenuButton.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; placeholderText: "Nouveau critère…"; foreground: root.foreground; accent: root.accent; maximumLength: 200 }
              Button { id: addContenuButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "+ Ajouter"; bordered: true; enabled: newContenuField.text.trim() !== ""; foreground: root.foreground; accent: root.accent; onClicked: { root.addCriterion("contenu", newContenuField.text); newContenuField.text = "" } }
            }
          }

          // ---- Expression écrite ----
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            Text { text: "Expression écrite"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
            Repeater {
              model: root.expressionCriteria
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: Math.max(eLabel.implicitHeight, eRemove.implicitHeight)
                Text { id: eLabel; anchors.left: parent.left; anchors.right: eRemove.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; text: "• " + modelData; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; textFormat: Text.PlainText }
                Button { id: eRemove; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "✕"; bordered: true; foreground: root.foreground; accent: Color.urgent; onClicked: root.removeCriterion("expression", index) }
              }
            }
            Item {
              width: parent.width
              height: Math.max(newExpressionField.implicitHeight, addExpressionButton.implicitHeight)
              TextField { id: newExpressionField; anchors.left: parent.left; anchors.right: addExpressionButton.left; anchors.rightMargin: Style.spacing.controlGap; anchors.verticalCenter: parent.verticalCenter; placeholderText: "Nouveau critère…"; foreground: root.foreground; accent: root.accent; maximumLength: 200 }
              Button { id: addExpressionButton; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "+ Ajouter"; bordered: true; enabled: newExpressionField.text.trim() !== ""; foreground: root.foreground; accent: root.accent; onClicked: { root.addCriterion("expression", newExpressionField.text); newExpressionField.text = "" } }
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          // ---- Barème indicatif (optionnel) ----
          Column {
            width: parent.width
            spacing: Style.spacing.xxs
            Text { text: "Barème indicatif (optionnel)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            Rectangle {
              width: parent.width
              height: Style.space(64)
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
                  id: baremeField
                  wrapMode: TextArea.Wrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  background: null
                  placeholderText: "Paliers indicatifs, jamais appliqués mécaniquement…"
                  onTextChanged: root.bareme = text
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground; width: parent.width }

          // ---- destination + actions ----
          Column {
            width: parent.width
            spacing: Style.spacing.xxs
            Text { text: "Enregistrer sous (.md)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
            TextField {
              id: savePathField
              width: parent.width
              placeholderText: "chemin du fichier .md…"
              foreground: root.foreground
              accent: root.accent
              maximumLength: 2000
            }
          }

          Row {
            spacing: Style.spacing.controlGap
            Button {
              text: "🪄 Générer et enregistrer"
              bordered: true
              enabled: root.canGenerate
              foreground: root.foreground
              accent: root.accent
              onClicked: root.generateRequested(savePathField.text.trim(), root.buildMarkdown())
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

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/Store.js" as Store
import "lib/RosterParser.js" as RosterParser
import "lib/Draw.js" as Draw
import "lib/Groups.js" as Groups
import "lib/PromptBuilder.js" as PromptBuilder
import "lib/ClaudeRunner.js" as ClaudeRunner
import "ui"

// GH Classes: one tab per class, weighted-random draw, group generation
// with incompatibility constraints, and an AI appreciation generator.
// "panel"-kind plugin (no bar-widget), following the same
// omarchy.dev-gallery/GalleryPanel.qml contract every other plugin in
// this author's GH* family uses — see ghgrilles-plugin's own Panel.qml
// header comment for the reasoning. `keepLoaded: true` (manifest) so a
// running appreciation-generation Process survives the window closing,
// same as GH Typst.
Item {
  id: root

  // ---- plugin lifecycle ----------------------------------------------------

  property bool closingFromHost: false
  property var shell: null

  function open(payloadJson) {
    root.closingFromHost = false
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.closingFromHost = true
    window.visible = false
    root.closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide("io.github.gabrielharfield.ghclasses")
    else window.visible = false
  }

  // ---- theme ----------------------------------------------------------------

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family

  // ---- paths ------------------------------------------------------------

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateDir: root.homeDir + "/.local/state/omarchy/plugins/io.github.gabrielharfield.ghclasses"
  readonly property string classesPath: root.stateDir + "/classes.json"
  readonly property string settingsPath: root.stateDir + "/settings.json"

  function expandHome(path) {
    var p = String(path || "").trim()
    if (p === "~") return root.homeDir
    if (p.indexOf("~/") === 0) return root.homeDir + p.slice(1)
    return p
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir]
  }
  Component.onCompleted: ensureDirsProc.running = true

  // ---- persisted: classes -------------------------------------------------

  property var classes: []

  FileView {
    id: classesFile
    path: root.classesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.classes = Store.parseClasses(classesFile.text())
    onLoadFailed: root.classes = []
  }

  function persistClasses() {
    classesFile.setText(Store.serializeClasses(root.classes))
  }

  // ---- persisted: settings (which class tab was last active) --------------

  property string activeClassId: ""

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.activeClassId = Store.parseSettings(settingsFile.text()).activeClassId
    onLoadFailed: root.activeClassId = ""
  }

  function persistSettings() {
    settingsFile.setText(Store.serializeSettings({ activeClassId: root.activeClassId }))
  }

  function activeClass() {
    var found = Store.findClass(root.classes, root.activeClassId)
    if (found) return found
    return root.classes.length > 0 ? root.classes[0] : null
  }

  function selectClass(id) {
    if (id === root.activeClassId) return
    root.activeClassId = id
    root.persistSettings()
    root.lastDraw = []
    root.lastGroups = []
    root.lastGroupsUnresolved = []
  }

  property string activeFeatureTab: "tirage" // tirage | groupes | appreciations | exercices

  // ---- class creation (Paramètres) -----------------------------------------

  property bool classSettingsOpen: false
  property string classImportError: ""
  property bool classImporting: false
  property string _pendingClassName: ""

  function openClassSettings() { root.classImportError = ""; root.classSettingsOpen = true }
  function closeClassSettings() { root.classSettingsOpen = false }

  function requestCreateClass(name, path) {
    var cleanName = String(name || "").trim().slice(0, Store.MAX_CLASS_NAME_LEN)
    var cleanPath = root.expandHome(String(path || "").trim())
    if (!cleanName) { root.classImportError = "Donnez un nom à la classe."; return }
    if (!cleanPath) { root.classImportError = "Indiquez le chemin du fichier de la liste."; return }
    if (root.classes.length >= Store.MAX_CLASSES) { root.classImportError = "Nombre maximal de classes atteint."; return }
    root._pendingClassName = cleanName
    root.classImporting = true
    root.classImportError = ""
    rosterReadProc.command = ["head", "-c", "2097152", "--", cleanPath]
    rosterReadProc.running = false
    rosterReadProc.running = true
  }

  Process {
    id: rosterReadProc
    stdout: StdioCollector { id: rosterReadOut; waitForEnd: true }
    stderr: StdioCollector { id: rosterReadErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.classImporting = false
      if (exitCode !== 0) {
        root.classImportError = "Impossible de lire ce fichier : " + (rosterReadErr.text || "").slice(0, 300)
        return
      }
      var parsed = RosterParser.parseRoster(rosterReadOut.text, Store.MAX_STUDENTS)
      if (parsed.students.length === 0) {
        root.classImportError = "Aucun élève reconnu dans ce fichier (une ligne par élève, ex. \"DUPONT Marie\")."
        return
      }
      var students = parsed.students.map(function(s) {
        return { id: Store.makeId(), nom: s.nom, prenom: s.prenom, drawCount: 0, drawHistory: [] }
      })
      var newClass = {
        id: Store.makeId(),
        name: root._pendingClassName,
        createdAt: new Date().toISOString(),
        students: students,
        incompatibilities: []
      }
      root.classes = root.classes.concat([newClass])
      root.persistClasses()
      root.activeClassId = newClass.id
      root.persistSettings()
      root.classSettingsOpen = false
      if (classSettingsPopover) classSettingsPopover.clearDraft()
    }
  }

  property string deleteClassPendingId: ""
  function requestDeleteClass(id) { root.deleteClassPendingId = id }
  function confirmDeleteClass() {
    var id = root.deleteClassPendingId
    root.classes = root.classes.filter(function(c) { return c.id !== id })
    root.persistClasses()
    if (root.activeClassId === id) {
      root.activeClassId = root.classes.length > 0 ? root.classes[0].id : ""
      root.persistSettings()
    }
    root.deleteClassPendingId = ""
  }
  function cancelDeleteClass() { root.deleteClassPendingId = "" }
  function pendingDeleteClassName() {
    var c = Store.findClass(root.classes, root.deleteClassPendingId)
    return c ? c.name : ""
  }

  // ---- feature 1: tirage au sort -------------------------------------------

  property var lastDraw: []

  function performDraw() {
    var cls = root.activeClass()
    if (!cls || cls.students.length === 0) return
    var picks = Draw.pickThree(cls.students)
    var ids = picks.map(function(p) { return p.id })
    var updatedStudents = Draw.recordDraw(cls.students, ids, new Date().toISOString())
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    var byId = {}
    updatedStudents.forEach(function(s) { byId[s.id] = s })
    root.lastDraw = ids.map(function(id) { return byId[id] })
  }

  property string pathBarMode: "" // "" | "exportStats"
  property string statsExportedPath: ""

  function slugify(s) {
    return String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "") || "classe"
  }

  function exportStats() {
    var cls = root.activeClass()
    if (!cls || cls.students.length === 0) return
    root.pathBarMode = "exportStats"
    var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
    pathBarField.text = root.homeDir + "/Downloads/tirage-" + root.slugify(cls.name) + "-" + ts + ".csv"
    Qt.callLater(function() { pathBarField.forceActiveFocus() })
  }

  function confirmPathEntry() {
    var path = pathBarField.text.trim()
    if (!path) return
    var mode = root.pathBarMode
    root.pathBarMode = ""
    if (mode === "exportStats") root.startStatsExport(path)
  }
  function cancelPathEntry() { root.pathBarMode = "" }

  function startStatsExport(destPath) {
    var cls = root.activeClass()
    if (!cls) return
    root.statsExportedPath = ""
    statsExportFile.path = destPath
    var csv = Draw.statsCsv(cls.students)
    Qt.callLater(function() { statsExportFile.setText(csv) })
  }

  FileView {
    id: statsExportFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root.statsExportedPath = statsExportFile.path
  }

  // ---- feature 2: groupes ---------------------------------------------------

  property int groupCount: 4
  property var lastGroups: []
  property var lastGroupsUnresolved: []
  property string groupsCopyFeedback: ""

  function generateGroupsForActiveClass() {
    var cls = root.activeClass()
    if (!cls || cls.students.length === 0) return
    var result = Groups.generateGroups(cls.students, root.groupCount, cls.incompatibilities)
    root.lastGroups = result.groups
    root.lastGroupsUnresolved = result.unresolved
  }

  function copyGroups() {
    if (root.lastGroups.length === 0) return
    var lines = []
    root.lastGroups.forEach(function(g, i) {
      lines.push("Groupe " + (i + 1) + " :")
      g.forEach(function(s) { lines.push("  - " + Store.studentLabel(s)) })
      lines.push("")
    })
    groupsCopyProc.command = ["wl-copy", lines.join("\n")]
    groupsCopyProc.running = false
    groupsCopyProc.running = true
  }

  Process {
    id: groupsCopyProc
    onExited: function(exitCode) {
      root.groupsCopyFeedback = exitCode === 0 ? "Copié !" : "Échec de la copie."
      groupsCopyFeedbackTimer.restart()
    }
  }
  Timer { id: groupsCopyFeedbackTimer; interval: 2000; repeat: false; onTriggered: root.groupsCopyFeedback = "" }

  property bool incompatOpen: false
  function openIncompat() { root.incompatOpen = true }
  function closeIncompat() { root.incompatOpen = false }

  function addIncompatibilitySet(ids) {
    var cls = root.activeClass()
    if (!cls || !ids || ids.length < 2) return
    if (cls.incompatibilities.length >= Store.MAX_INCOMPATIBILITY_SETS) return
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities.concat([ids]) }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
  }

  function removeIncompatibilitySet(index) {
    var cls = root.activeClass()
    if (!cls) return
    var list = cls.incompatibilities.slice()
    list.splice(index, 1)
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: list }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
  }

  // ---- feature 3: appréciations ---------------------------------------------

  property string appreciationMode: "copies" // copies | bulletin
  property string maxCharsOption: "300"
  property bool generatingAppreciation: false
  property string appreciationResult: ""
  property string appreciationError: ""
  property string appreciationCopyFeedback: ""

  function generateAppreciation() {
    var values = root.appreciationMode === "bulletin"
      ? { travail: travailField.text, comportement: comportementField.text, axe: axeField.text }
      : { methode: methodeField.text, contenu: contenuField.text, expression: expressionField.text }
    var prompt = PromptBuilder.buildAppreciationPrompt(root.appreciationMode, values, parseInt(root.maxCharsOption, 10))
    root.generatingAppreciation = true
    root.appreciationError = ""
    root.appreciationResult = ""
    appreciationProc.command = ClaudeRunner.buildCommand(prompt)
    appreciationProc.running = false
    appreciationProc.running = true
  }

  Process {
    id: appreciationProc
    stdout: StdioCollector { id: appreciationOut; waitForEnd: true }
    stderr: StdioCollector { id: appreciationErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.generatingAppreciation = false
      if (exitCode !== 0) {
        root.appreciationError = (appreciationErr.text || "Échec de la génération.").slice(0, 500)
        return
      }
      root.appreciationResult = (appreciationOut.text || "").trim()
    }
  }

  function copyAppreciation() {
    if (!root.appreciationResult) return
    appreciationCopyProc.command = ["wl-copy", root.appreciationResult]
    appreciationCopyProc.running = false
    appreciationCopyProc.running = true
  }

  Process {
    id: appreciationCopyProc
    onExited: function(exitCode) {
      root.appreciationCopyFeedback = exitCode === 0 ? "Copié !" : "Échec de la copie."
      appreciationCopyFeedbackTimer.restart()
    }
  }
  Timer { id: appreciationCopyFeedbackTimer; interval: 2000; repeat: false; onTriggered: root.appreciationCopyFeedback = "" }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: "GH Classes"
    color: root.background
    implicitWidth: Style.space(820)
    implicitHeight: Style.space(780)
    minimumSize: Qt.size(Style.space(680), Style.space(600))
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("io.github.gabrielharfield.ghclasses")
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: methodeField.activeFocus || contenuField.activeFocus || expressionField.activeFocus
          || travailField.activeFocus || comportementField.activeFocus || axeField.activeFocus
          || root.classSettingsOpen || root.incompatOpen || root.pathBarMode !== ""
          || root.deleteClassPendingId !== ""
        onCloseRequested: root.requestClose()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(18)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            width: scrollArea.availableWidth
            spacing: Style.spacing.huge

            // ---------------------------------------------------- header

            Item {
              width: parent.width
              height: Math.max(titleText.implicitHeight, settingsButton.implicitHeight)

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "GH Classes"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Button {
                id: settingsButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "⚙ Paramètres"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.openClassSettings()
              }
            }

            PanelSeparator { foreground: root.foreground; width: parent.width }

            // -------------------------------------------------- class tabs

            ButtonGroup {
              visible: root.classes.length > 0
              width: parent.width
              options: root.classes.map(function(c) { return { value: c.id, label: c.name } })
              value: root.activeClass() ? root.activeClass().id : ""
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(value) { root.selectClass(value) }
            }

            Column {
              visible: root.classes.length === 0
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                text: "Aucune classe pour le moment."
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                width: parent.width
                text: "Créez votre première classe depuis les Paramètres : donnez-lui un nom et joignez un fichier .md listant vos élèves (une ligne par élève, \"NOM Prénom\")."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Button {
                text: "⚙ Créer une classe"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.openClassSettings()
              }
            }

            // ----------------------------------------------- feature tabs

            Column {
              visible: root.classes.length > 0
              width: parent.width
              spacing: Style.spacing.huge

              ButtonGroup {
                width: parent.width
                options: [
                  { value: "tirage", label: "🎲 Tirage au sort" },
                  { value: "groupes", label: "👥 Groupes" },
                  { value: "appreciations", label: "✍ Appréciations" },
                  { value: "exercices", label: "📚 Exercices" }
                ]
                value: root.activeFeatureTab
                foreground: root.foreground
                background: root.background
                accent: root.accent
                fontFamily: root.fontFamily
                onChanged: function(value) { root.activeFeatureTab = value }
              }

              PanelSeparator { foreground: root.foreground; width: parent.width }

              // ===================================================== tirage

              Column {
                visible: root.activeFeatureTab === "tirage"
                width: parent.width
                spacing: Style.spacing.huge

                Text {
                  visible: root.activeClass() && root.activeClass().students.length === 0
                  width: parent.width
                  text: "Cette classe n'a aucun élève."
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.controlGap

                  Button {
                    text: "🎲 Tirer au sort"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.performDraw()
                  }
                  Button {
                    text: "📊 Statistiques (.csv)"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.exportStats()
                  }
                }

                Text {
                  visible: root.statsExportedPath !== ""
                  width: parent.width
                  text: "Statistiques exportées : " + root.statsExportedPath
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                }

                Column {
                  visible: root.lastDraw.length > 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    visible: root.lastDraw.length > 0
                    text: "🥇 " + (root.lastDraw.length > 0 ? Store.studentLabel(root.lastDraw[0]) : "")
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.displayLarge
                    font.bold: true
                    textFormat: Text.PlainText
                  }
                  Text {
                    visible: root.lastDraw.length > 1
                    text: "🥈 " + (root.lastDraw.length > 1 ? Store.studentLabel(root.lastDraw[1]) : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    textFormat: Text.PlainText
                  }
                  Text {
                    visible: root.lastDraw.length > 2
                    text: "🥉 " + (root.lastDraw.length > 2 ? Store.studentLabel(root.lastDraw[2]) : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    textFormat: Text.PlainText
                  }
                }

                Text {
                  visible: root.lastDraw.length === 0
                  text: "Aucun tirage effectué pour cette classe."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Column {
                  visible: root.pathBarMode === "exportStats"
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: "Exporter les statistiques (.csv) vers :"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Item {
                    width: parent.width
                    height: Math.max(pathBarField.implicitHeight, pathBarButtons.implicitHeight)

                    Row {
                      id: pathBarButtons
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.controlGap

                      Button {
                        text: "Confirmer"
                        bordered: true
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.confirmPathEntry()
                      }
                      Button {
                        text: "Annuler"
                        bordered: true
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.cancelPathEntry()
                      }
                    }

                    TextField {
                      id: pathBarField
                      anchors.left: parent.left
                      anchors.right: pathBarButtons.left
                      anchors.rightMargin: Style.spacing.controlGap
                      anchors.verticalCenter: parent.verticalCenter
                      focus: root.pathBarMode !== ""
                      foreground: root.foreground
                      accent: root.accent
                      Keys.onReturnPressed: root.confirmPathEntry()
                      Keys.onEnterPressed: root.confirmPathEntry()
                      Keys.onEscapePressed: root.cancelPathEntry()
                    }
                  }
                }
              }

              // ==================================================== groupes

              Column {
                visible: root.activeFeatureTab === "groupes"
                width: parent.width
                spacing: Style.spacing.huge

                Flow {
                  width: parent.width
                  spacing: Style.spacing.huge

                  Button {
                    text: "⚠ Élèves incompatibles"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.openIncompat()
                  }

                  NumberField {
                    label: "Nombre de groupes"
                    value: root.groupCount
                    from: 1
                    to: Math.max(1, root.activeClass() ? root.activeClass().students.length : 10)
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onModified: function(value) { root.groupCount = value }
                  }
                }

                Button {
                  text: "🔀 Générer les groupes"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.generateGroupsForActiveClass()
                }

                Text {
                  visible: root.lastGroupsUnresolved.length > 0
                  width: parent.width
                  text: "⚠ " + root.lastGroupsUnresolved.length + " incompatibilité(s) n'ont pas pu être respectée(s) avec ce nombre de groupes."
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.huge

                  Repeater {
                    model: root.lastGroups
                    delegate: Rectangle {
                      required property var modelData
                      required property int index
                      width: Style.space(220)
                      height: groupColumn.implicitHeight + Style.space(24)
                      radius: Style.cornerRadius
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                      border.width: 1

                      Column {
                        id: groupColumn
                        anchors.fill: parent
                        anchors.margins: Style.space(12)
                        spacing: Style.spacing.xs

                        Text {
                          text: "Groupe " + (index + 1)
                          color: root.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }
                        Repeater {
                          model: modelData
                          delegate: Text {
                            required property var modelData
                            text: "• " + Store.studentLabel(modelData)
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: groupColumn.width
                            textFormat: Text.PlainText
                          }
                        }
                      }
                    }
                  }
                }

                Row {
                  visible: root.lastGroups.length > 0
                  spacing: Style.spacing.controlGap

                  Button {
                    text: "📋 Copier"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.copyGroups()
                  }
                }

                Text {
                  visible: root.groupsCopyFeedback !== ""
                  text: root.groupsCopyFeedback
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // ============================================= appréciations

              Column {
                visible: root.activeFeatureTab === "appreciations"
                width: parent.width
                spacing: Style.spacing.huge

                ButtonGroup {
                  options: [{ value: "copies", label: "Copie" }, { value: "bulletin", label: "Bulletin" }]
                  value: root.appreciationMode
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(value) { root.appreciationMode = value }
                }

                Column {
                  visible: root.appreciationMode === "copies"
                  width: parent.width
                  spacing: Style.spacing.md

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Méthode"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: methodeField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne pour la méthode…"
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Contenu"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: contenuField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne pour le contenu…"
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Expression"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: expressionField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne pour l'expression…"
                      }
                    }
                  }
                }

                Column {
                  visible: root.appreciationMode === "bulletin"
                  width: parent.width
                  spacing: Style.spacing.md

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Travail"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: travailField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne sur le travail…"
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Comportement"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: comportementField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne sur le comportement…"
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Axe de progression"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Rectangle {
                      width: parent.width
                      height: Style.space(76)
                      radius: Style.cornerRadius
                      color: Style.normalFillFor(root.foreground, root.accent)
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                      border.width: 1
                      TextArea {
                        id: axeField
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Consigne sur l'axe de progression…"
                      }
                    }
                  }
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.huge

                  Dropdown {
                    label: "Longueur max"
                    options: [
                      { value: "200", label: "200 caractères" },
                      { value: "300", label: "300 caractères" },
                      { value: "500", label: "500 caractères" },
                      { value: "800", label: "800 caractères" },
                      { value: "1000", label: "1000 caractères" }
                    ]
                    value: root.maxCharsOption
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(value) { root.maxCharsOption = value }
                  }

                  Button {
                    text: root.generatingAppreciation ? "Génération en cours…" : "🪄 Générer l'appréciation"
                    bordered: true
                    enabled: !root.generatingAppreciation
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.generateAppreciation()
                  }
                }

                Text {
                  visible: root.appreciationError !== ""
                  width: parent.width
                  text: root.appreciationError
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }

                Column {
                  visible: root.appreciationResult !== ""
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: "Résultat"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Rectangle {
                    width: parent.width
                    height: resultText.implicitHeight + Style.space(16)
                    radius: Style.cornerRadius
                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.06)
                    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                    border.width: 1

                    Text {
                      id: resultText
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.space(10)
                      text: root.appreciationResult
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WordWrap
                      textFormat: Text.PlainText
                    }
                  }

                  Row {
                    spacing: Style.spacing.controlGap

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.appreciationResult.length + " / " + root.maxCharsOption + " caractères"
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      text: "📋 Copier"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.copyAppreciation()
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.appreciationCopyFeedback !== ""
                      text: root.appreciationCopyFeedback
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }

              // ================================================= exercices

              Column {
                visible: root.activeFeatureTab === "exercices"
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  text: "Générateur d'exercices — à venir"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: "Cette fonctionnalité arrivera dans une prochaine version, une fois la base d'exercices (classés par niveau et difficulté) constituée."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }

      // ---------------------------------------------------------- overlays

      ClassSettingsPopover {
        id: classSettingsPopover
        anchors.fill: parent
        opened: root.classSettingsOpen
        classes: root.classes
        importing: root.classImporting
        importError: root.classImportError
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCreateRequested: function(name, path) { root.requestCreateClass(name, path) }
        onDeleteRequested: function(classId) { root.requestDeleteClass(classId) }
        onCanceled: root.closeClassSettings()
      }

      IncompatibilityPopover {
        anchors.fill: parent
        opened: root.incompatOpen
        students: root.activeClass() ? root.activeClass().students : []
        incompatibilities: root.activeClass() ? root.activeClass().incompatibilities : []
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onSetAdded: function(studentIds) { root.addIncompatibilitySet(studentIds) }
        onSetRemoved: function(index) { root.removeIncompatibilitySet(index) }
        onCanceled: root.closeIncompat()
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.deleteClassPendingId !== ""
        message: "Supprimer la classe \"" + root.pendingDeleteClassName() + "\" ? Cette action est irréversible."
        cancelText: "Annuler"
        confirmText: "Supprimer"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelDeleteClass()
        onConfirmed: root.confirmDeleteClass()
      }
    }
  }
}

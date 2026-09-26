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
import "lib/Files.js" as Files
import "lib/CompetencyGrids.js" as CompetencyGrids
import "lib/Spellcheck.js" as Spellcheck
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
    if (root.syncDir) root.runSync()
  }

  function close() {
    root.flushEvaluationFieldsIfPending()
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
  Component.onCompleted: {
    ensureDirsProc.running = true
    spellcheckDictDiscoverProc.running = true
  }

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

  // Keeps one prior generation of classes.json around as a safety net
  // against a bad write — real per-student data (draw history, incompat
  // sets) lives only here, with no other undo mechanism. Best-effort:
  // the cp is skipped/fails harmlessly the very first time (nothing to
  // back up yet), and this only protects saves made through the app
  // itself, not the file being edited/replaced from outside it.
  property string _pendingClassesJson: ""

  function persistClasses() {
    root._pendingClassesJson = Store.serializeClasses(root.classes)
    backupClassesProc.command = ["cp", "-f", "--", root.classesPath, root.classesPath + ".bak"]
    backupClassesProc.running = false
    backupClassesProc.running = true
  }

  Process {
    id: backupClassesProc
    onExited: classesFile.setText(root._pendingClassesJson)
  }

  // ---- persisted: settings (last active class tab + sync folder) ----------

  property string activeClassId: ""
  property string syncDir: "" // "" = sync disabled

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var s = Store.parseSettings(settingsFile.text())
      root.activeClassId = s.activeClassId
      root.syncDir = s.syncDir
    }
    onLoadFailed: { root.activeClassId = ""; root.syncDir = "" }
  }

  function persistSettings() {
    settingsFile.setText(Store.serializeSettings({ activeClassId: root.activeClassId, syncDir: root.syncDir }))
  }

  function setSyncDir(dir) {
    var clean = root.expandHome(dir).slice(0, 1024)
    if (clean === root.syncDir) return
    root.syncDir = clean
    root.persistSettings()
  }

  // ---- sync settings popover ------------------------------------------------

  property bool syncSettingsOpen: false
  function openSyncSettings() { root.syncSettingsOpen = true }
  function closeSyncSettings() { root.syncSettingsOpen = false }
  function confirmSyncDir(dir) {
    root.setSyncDir(dir)
    root.syncSettingsOpen = false
    if (root.syncDir) root.runSync()
  }
  function clearSyncDir() {
    root.setSyncDir("")
    root.syncSettingsOpen = false
  }

  // ---- classes.json sync (additive merge via a user-chosen folder) --------
  //
  // Same shape as GH Grilles' own criteria-bank sync (mkdir the folder,
  // bounded-read its classes.json, merge, write the merged result to both
  // sides — a failed write to an unreachable folder is tolerated silently
  // since local state is already correct by then). The merge itself is
  // Store.mergeClasses(), which — unlike Grilles' plain array union —
  // reconciles mutable per-student draw history and respects a reset done
  // on either machine. See that function's own header comment for the full
  // reasoning, including the "class must be created once, then synced, not
  // re-imported independently on each machine" limitation.

  property bool syncInFlight: false
  property string _syncPendingDir: ""

  function runSync() {
    if (!root.syncDir || root.syncInFlight) return
    root.syncInFlight = true
    syncInFlightTimeout.restart()
    root._syncPendingDir = root.syncDir
    ensureSyncDirProc.command = ["mkdir", "-p", "--", root._syncPendingDir]
    ensureSyncDirProc.running = false
    ensureSyncDirProc.running = true
  }

  // Quickshell's FileView exposes no onSaveFailed signal, so a write to an
  // unreachable sync folder has no failure event to catch — this timer is
  // the fallback that still clears syncInFlight in that case, so one bad
  // sync folder can never permanently wedge every later sync attempt.
  Timer {
    id: syncInFlightTimeout
    interval: 8000
    repeat: false
    onTriggered: root.syncInFlight = false
  }

  Process {
    id: ensureSyncDirProc
    onExited: function(exitCode) {
      if (exitCode !== 0) { syncInFlightTimeout.stop(); root.syncInFlight = false; return }
      var cmd = Files.readCommand(root._syncPendingDir, "classes.json", 4194304, 5)
      if (!cmd) { syncInFlightTimeout.stop(); root.syncInFlight = false; return }
      syncReadProc.command = cmd
      syncReadProc.running = false
      syncReadProc.running = true
    }
  }

  Process {
    id: syncReadProc
    stdout: StdioCollector { id: syncReadOut; waitForEnd: true }
    onExited: function(exitCode) {
      var remoteClasses = Store.parseClasses(syncReadOut.text || "[]")
      var merged = Store.mergeClasses(root.classes, remoteClasses)
      root.classes = merged
      root.persistClasses()
      syncWriteFile.path = root._syncPendingDir + "/classes.json"
      Qt.callLater(function() { syncWriteFile.setText(Store.serializeClasses(merged)) })
    }
  }

  FileView {
    id: syncWriteFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: { syncInFlightTimeout.stop(); root.syncInFlight = false }
  }

  function activeClass() {
    var found = Store.findClass(root.classes, root.activeClassId)
    if (found) return found
    return root.classes.length > 0 ? root.classes[0] : null
  }

  function selectClass(id) {
    if (id === root.activeClassId) return
    root.flushEvaluationFieldsIfPending()
    root.activeClassId = id
    root.persistSettings()
    root.lastDraw = []
    root.lastGroups = []
    root.lastGroupsUnresolved = []
    root.appreciationStudentId = ""
    root.evaluationStudentId = ""
    root.evalCopyFeedback = ""
    root.evalPdfExportedPath = ""
    root.evalPdfExportError = ""
    root.loadEvaluationFields()
  }

  property string activeFeatureTab: "tirage" // tirage | groupes | appreciations | evaluation | exercices

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
        incompatibilities: [],
        lastResetAt: "",
        competencyIntitules: {}
      }
      root.classes = root.classes.concat([newClass])
      root.persistClasses()
      root.activeClassId = newClass.id
      root.persistSettings()
      root.classSettingsOpen = false
      if (classSettingsPopover) classSettingsPopover.clearDraft()
      if (root.syncDir) root.runSync()
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
    if (root.syncDir) root.runSync()
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
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    var byId = {}
    updatedStudents.forEach(function(s) { byId[s.id] = s })
    root.lastDraw = ids.map(function(id) { return byId[id] })
    if (root.syncDir) root.runSync()
  }

  property bool resetDrawsConfirmOpen: false
  function requestResetDraws() {
    var cls = root.activeClass()
    if (!cls || cls.students.length === 0) return
    root.resetDrawsConfirmOpen = true
  }
  function cancelResetDraws() { root.resetDrawsConfirmOpen = false }
  function confirmResetDraws() {
    var cls = root.activeClass()
    root.resetDrawsConfirmOpen = false
    if (!cls) return
    var resetStudents = cls.students.map(function(s) {
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: 0, drawHistory: [] }
    })
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: resetStudents, incompatibilities: cls.incompatibilities, lastResetAt: new Date().toISOString(), competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
    root.lastDraw = []
    if (root.syncDir) root.runSync()
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
    else if (mode === "exportEvalPdf") root.startEvalPdfExport(path)
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
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities.concat([ids]), lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  function removeIncompatibilitySet(index) {
    var cls = root.activeClass()
    if (!cls) return
    var list = cls.incompatibilities.slice()
    list.splice(index, 1)
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: list, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  // ---- feature 3: appréciations ---------------------------------------------

  property string appreciationMode: "copies" // copies | bulletin
  property string maxCharsOption: "300"
  property bool generatingAppreciation: false
  property string appreciationResult: ""
  property string appreciationError: ""
  property string appreciationCopyFeedback: ""
  // Copie-only: which student the copied "commande" is attributed to (ex.
  // "CATIN Mathieu : appréciation générée"). Never used for bulletin mode.
  property string appreciationStudentId: ""

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

  function resetAppreciationForm() {
    methodeField.text = ""
    contenuField.text = ""
    expressionField.text = ""
    travailField.text = ""
    comportementField.text = ""
    axeField.text = ""
    root.appreciationResult = ""
    root.appreciationError = ""
    root.appreciationCopyFeedback = ""
    root.appreciationStudentId = ""
  }

  // Empty unless mode is "copies" and the selected id still matches a
  // student of the currently active class (guards against a stale
  // selection surviving a class switch).
  function selectedAppreciationStudentLabel() {
    if (root.appreciationMode !== "copies" || !root.appreciationStudentId) return ""
    var cls = root.activeClass()
    if (!cls) return ""
    for (var i = 0; i < cls.students.length; i++) {
      if (cls.students[i].id === root.appreciationStudentId) return Store.studentLabel(cls.students[i])
    }
    return ""
  }

  function copyAppreciation() {
    if (!root.appreciationResult) return
    var label = root.selectedAppreciationStudentLabel()
    var text = label ? (label + " : " + root.appreciationResult) : root.appreciationResult
    appreciationCopyProc.command = ["wl-copy", text]
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

  // Placeholder for the "ajouter à la planche d'étiquettes" button — wired
  // up but inert until the physical label-sheet Typst template exists (see
  // conversation with Gabriel, 2026-09-05: waiting on the Amazon sheet he's
  // ordering to reverse-engineer its exact grid dimensions).
  property string labelSheetFeedback: ""
  function addAppreciationToLabelSheet() {
    root.labelSheetFeedback = "Bientôt disponible — en attente du gabarit d'étiquettes."
    labelSheetFeedbackTimer.restart()
  }
  Timer { id: labelSheetFeedbackTimer; interval: 2500; repeat: false; onTriggered: root.labelSheetFeedback = "" }

  // ---- feature 4: évaluation par compétences ---------------------------------

  property string evaluationGridId: CompetencyGrids.GRIDS.length > 0 ? CompetencyGrids.GRIDS[0].id : ""
  property string evaluationStudentId: ""
  // Checkbox columns stay a fixed, narrow width; the "Critères" column
  // takes whatever's left of the row, so it grows/shrinks with the window
  // and stays as wide as possible. Column headers wrap onto 2-3 lines at
  // this width (e.g. "Insuffisamment maîtrisé") — accepted trade-off.
  readonly property real evalCellColWidth: Style.space(62)
  readonly property real evalCellsTotalWidth: 4 * root.evalCellColWidth + 4 * Style.spacing.xs

  function activeEvaluationGrid() {
    return CompetencyGrids.findGrid(root.evaluationGridId)
  }

  function evaluationStudent() {
    var cls = root.activeClass()
    if (!cls || !root.evaluationStudentId) return null
    for (var i = 0; i < cls.students.length; i++) {
      if (cls.students[i].id === root.evaluationStudentId) return cls.students[i]
    }
    return null
  }

  function evaluationGridEntry() {
    var s = root.evaluationStudent()
    return (s && s.competencyGrids && s.competencyGrids[root.evaluationGridId]) || null
  }

  // Unlike checks/appreciation/note, the intitulé (assignment title) lives
  // on the Class, not the Student — it's the same for every student
  // evaluated on this grid, typed once rather than retyped per student.
  function evaluationIntitule() {
    var cls = root.activeClass()
    var intitules = (cls && cls.competencyIntitules) || {}
    return intitules[root.evaluationGridId] || ""
  }

  // -1 = unchecked. Reads straight off the student object (no local
  // sanitize pass on this path — see the rest of this file's convention of
  // sanitizing only on load/sync, trusting in-app mutations).
  function evaluationCheckedCol(rowIndex) {
    var entry = root.evaluationGridEntry()
    var checks = entry ? entry.checks : null
    if (!checks) return -1
    var v = checks[rowIndex]
    return (v === undefined || v === null) ? -1 : v
  }

  // Clicking an already-checked cell unchecks it (radio-with-off, not a
  // strict radio group), matching "une seule case cochée par ligne" while
  // still letting Gabriel clear a mis-click. Preserves whatever
  // appreciation/note this student/grid already has.
  function setEvaluationCheck(rowIndex, colIndex) {
    var cls = root.activeClass()
    if (!cls || !root.evaluationStudentId) return
    var updatedStudents = cls.students.map(function(s) {
      if (s.id !== root.evaluationStudentId) return s
      var grids = {}
      var existingGrids = s.competencyGrids || {}
      Object.keys(existingGrids).forEach(function(gid) { grids[gid] = existingGrids[gid] })
      var entry = grids[root.evaluationGridId] || { checks: {}, appreciation: "", note: "" }
      var checks = {}
      Object.keys(entry.checks || {}).forEach(function(k) { checks[k] = entry.checks[k] })
      if (checks[rowIndex] === colIndex) delete checks[rowIndex]
      else checks[rowIndex] = colIndex
      grids[root.evaluationGridId] = { checks: checks, appreciation: entry.appreciation || "", note: entry.note || "" }
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  // Clears this grid's data (checks/appréciation/note) for one student, or
  // for every student in the class at once — Gabriel's own workflow: he
  // revisits/harmonizes copies after the fact, so nothing here is ever
  // cleared automatically. These two buttons (next to "Exporter en PDF")
  // are the only way data is lost, and both go through a confirmation.
  // Scoped to the currently selected grid only (a student's other grid
  // types, if any, are untouched) — Gabriel's explicit call: "au pire je
  // cliquerai une nouvelle fois pour un autre type d'exercice", and he
  // values keeping a student's prior work visible for pedagogical reasons.
  // The intitulé (assignment title, on the Class) is left alone by design
  // — it's not itself an "évaluation", and stays editable as plain text.
  property bool resetEvaluationStudentConfirmOpen: false
  property bool resetEvaluationClassConfirmOpen: false

  function requestResetEvaluationStudent() {
    if (!root.evaluationStudentId) return
    root.resetEvaluationStudentConfirmOpen = true
  }
  function cancelResetEvaluationStudent() { root.resetEvaluationStudentConfirmOpen = false }
  function confirmResetEvaluationStudent() {
    root.resetEvaluationStudentConfirmOpen = false
    var cls = root.activeClass()
    if (!cls || !root.evaluationStudentId) return
    var updatedStudents = cls.students.map(function(s) {
      if (s.id !== root.evaluationStudentId) return s
      var grids = {}
      var existingGrids = s.competencyGrids || {}
      Object.keys(existingGrids).forEach(function(gid) { grids[gid] = existingGrids[gid] })
      delete grids[root.evaluationGridId]
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
    root.loadEvaluationFields()
  }

  function requestResetEvaluationClass() {
    if (!root.activeClass()) return
    root.resetEvaluationClassConfirmOpen = true
  }
  function cancelResetEvaluationClass() { root.resetEvaluationClassConfirmOpen = false }
  function confirmResetEvaluationClass() {
    root.resetEvaluationClassConfirmOpen = false
    var cls = root.activeClass()
    if (!cls) return
    var updatedStudents = cls.students.map(function(s) {
      var grids = {}
      var existingGrids = s.competencyGrids || {}
      Object.keys(existingGrids).forEach(function(gid) { grids[gid] = existingGrids[gid] })
      delete grids[root.evaluationGridId]
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
    root.loadEvaluationFields()
  }

  // ---- local spellcheck for the Appréciation field ---------------------
  // Ported from GH Typst's hunspell-based spellcheck (lib/Spellcheck.js
  // header has the full design rationale) — same two-phase detect/suggest
  // split, just sized for a short paragraph instead of a whole document:
  // no debounce needed (hunspell -l on a handful of words is sub-ms), only
  // the busy/pending guard is kept, to never run two hunspell processes at
  // once against the same scratch file.

  readonly property string spellcheckWordsPath: root.stateDir + "/.ghclasses-spellcheck-words.txt"
  readonly property string spellcheckSuggestPath: root.stateDir + "/.ghclasses-spellcheck-suggest.txt"

  property bool spellcheckAvailable: false
  property string spellcheckDict: ""

  Process {
    id: spellcheckDictDiscoverProc
    command: Spellcheck.buildDiscoverCommand()
    stderr: StdioCollector { id: spellcheckDictDiscoverOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.spellcheckDict = Spellcheck.parseDiscoverOutput(spellcheckDictDiscoverOut.text)
      root.spellcheckAvailable = root.spellcheckDict !== ""
    }
  }

  property var evalMisspelledWords: [] // unique flagged words in the current appréciation text
  property bool _evalSpellcheckBusy: false
  property bool _evalSpellcheckHasPending: false
  property string _evalSpellcheckPendingText: ""
  property var _evalSpellcheckTokens: []
  // Same no-op-write guard as GH Typst's own: FileView never fires onSaved
  // for a byte-identical write, which would otherwise wedge a same-content
  // re-check forever.
  property string _evalSpellcheckLastWordsInput: ""

  function requestEvalSpellcheck(text) {
    if (!root.spellcheckAvailable) return
    if (root._evalSpellcheckBusy) {
      root._evalSpellcheckPendingText = text
      root._evalSpellcheckHasPending = true
      return
    }
    root._runEvalSpellcheck(text)
  }

  function _runEvalSpellcheck(text) {
    root._evalSpellcheckBusy = true
    var tokens = Spellcheck.tokenize(text)
    root._evalSpellcheckTokens = tokens
    var words = Spellcheck.uniqueWords(tokens)
    if (words.length === 0) {
      root._evalSpellcheckBusy = false
      root.evalMisspelledWords = []
      root._evalSpellcheckDrainPending()
      return
    }
    var input = Spellcheck.buildDetectInput(words)
    if (input === root._evalSpellcheckLastWordsInput) {
      root._startEvalSpellcheckDetectProc()
    } else {
      root._evalSpellcheckLastWordsInput = input
      evalSpellcheckWordsFile.setText(input)
    }
  }

  function _startEvalSpellcheckDetectProc() {
    evalSpellcheckDetectProc.command = Spellcheck.buildDetectCommand(root.spellcheckDict).concat([root.spellcheckWordsPath])
    evalSpellcheckDetectProc.running = false
    evalSpellcheckDetectProc.running = true
  }

  FileView {
    id: evalSpellcheckWordsFile
    path: root.spellcheckWordsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startEvalSpellcheckDetectProc()
  }

  Process {
    id: evalSpellcheckDetectProc
    stdout: StdioCollector { id: evalSpellcheckDetectOut; waitForEnd: true }
    onExited: function(exitCode) {
      var misspelled = Spellcheck.parseDetectOutput(evalSpellcheckDetectOut.text)
      var flagged = []
      var seen = {}
      root._evalSpellcheckTokens.forEach(function(t) {
        if (misspelled[t.word] && !seen[t.word]) { seen[t.word] = true; flagged.push(t.word) }
      })
      root.evalMisspelledWords = flagged
      root._evalSpellcheckBusy = false
      root._evalSpellcheckDrainPending()
    }
  }

  function _evalSpellcheckDrainPending() {
    if (!root._evalSpellcheckHasPending) return
    root._evalSpellcheckHasPending = false
    var text = root._evalSpellcheckPendingText
    root._evalSpellcheckPendingText = ""
    root.requestEvalSpellcheck(text)
  }

  // On-demand suggestions for a clicked flagged word.
  property string evalSuggestWord: ""
  property var evalSuggestions: []
  property bool evalSuggestBusy: false
  property string _evalSuggestLastInput: ""

  function requestEvalSuggestions(word) {
    root.evalSuggestWord = word
    root.evalSuggestions = []
    root.evalSuggestBusy = true
    var input = Spellcheck.buildSuggestInput(word)
    if (input === root._evalSuggestLastInput) {
      root._startEvalSuggestProc()
    } else {
      root._evalSuggestLastInput = input
      evalSpellcheckSuggestFile.setText(input)
    }
  }

  function _startEvalSuggestProc() {
    evalSpellcheckSuggestProc.command = Spellcheck.buildSuggestCommand(root.spellcheckDict).concat([root.spellcheckSuggestPath])
    evalSpellcheckSuggestProc.running = false
    evalSpellcheckSuggestProc.running = true
  }

  FileView {
    id: evalSpellcheckSuggestFile
    path: root.spellcheckSuggestPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startEvalSuggestProc()
  }

  Process {
    id: evalSpellcheckSuggestProc
    stdout: StdioCollector { id: evalSpellcheckSuggestOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalSuggestions = Spellcheck.parseSuggestOutput(evalSpellcheckSuggestOut.text)
      root.evalSuggestBusy = false
    }
  }

  // Replaces every occurrence of `word` in the appréciation text with
  // `replacement`. Uses the exact spans from the tokenize() pass that
  // flagged it rather than a \b regex — plain JS \b treats accented French
  // letters as non-word characters, which would silently mis-split a word
  // like "récolte" right after the "é".
  function applyEvalSuggestion(word, replacement) {
    var text = evaluationAppreciationField.text
    var tokens = Spellcheck.tokenize(text)
    var out = ""
    var last = 0
    tokens.forEach(function(t) {
      if (t.word === word) {
        out += text.slice(last, t.start) + replacement
        last = t.end
      }
    })
    out += text.slice(last)
    evaluationAppreciationField.text = out
  }

  // The appréciation/note fields (declared in the tab UI below) aren't
  // bound to the model — binding TextArea.text straight to a function of
  // root.classes would fight the user's cursor on every keystroke, since
  // persisting would re-trigger that binding. Instead they're loaded
  // imperatively on student/grid switch (loadEvaluationFields) and written
  // back debounced (queueEvaluationFieldsPersist), flushed immediately
  // before any switch that would otherwise discard a pending edit
  // (flushEvaluationFieldsIfPending).
  // Guards the two onTextChanged handlers below against the programmatic
  // assignment in loadEvaluationFields itself — without it, every student/
  // grid switch would queue a pointless re-save (and re-sync) of the value
  // that was just loaded, unchanged.
  property bool _evalFieldsLoading: false

  function loadEvaluationFields() {
    root._evalFieldsLoading = true
    evaluationIntituleField.text = root.evaluationIntitule()
    var entry = root.evaluationGridEntry()
    root.evalMisspelledWords = []
    root.evalSuggestWord = ""
    root.evalSuggestions = []
    evaluationAppreciationField.text = entry ? entry.appreciation : ""
    evaluationNoteField.text = entry ? entry.note : ""
    root.evalNoteEstimate = ""
    root.evalEstimateError = ""
    root.evalGenAppreciationError = ""
    root._evalFieldsLoading = false
  }

  function queueEvaluationFieldsPersist() {
    if (root._evalFieldsLoading) return
    evalFieldsDebounceTimer.restart()
  }

  function flushEvaluationFieldsIfPending() {
    if (!evalFieldsDebounceTimer.running) return
    evalFieldsDebounceTimer.stop()
    root.persistEvaluationFields()
  }

  // Writes all three live fields at once (intitulé always, appreciation/
  // note only if a student is selected) — a no-op field is just written
  // back unchanged, simpler than tracking which one actually changed.
  function persistEvaluationFields() {
    var cls = root.activeClass()
    if (!cls || !root.evaluationGridId) return

    var intitule = evaluationIntituleField.text
    var intitules = {}
    var existingIntitules = cls.competencyIntitules || {}
    Object.keys(existingIntitules).forEach(function(gid) { intitules[gid] = existingIntitules[gid] })
    if (intitule) intitules[root.evaluationGridId] = intitule
    else delete intitules[root.evaluationGridId]

    var updatedStudents = cls.students
    if (root.evaluationStudentId) {
      var appreciation = evaluationAppreciationField.text
      var note = evaluationNoteField.text
      updatedStudents = cls.students.map(function(s) {
        if (s.id !== root.evaluationStudentId) return s
        var grids = {}
        var existingGrids = s.competencyGrids || {}
        Object.keys(existingGrids).forEach(function(gid) { grids[gid] = existingGrids[gid] })
        var entry = grids[root.evaluationGridId] || { checks: {}, appreciation: "", note: "" }
        grids[root.evaluationGridId] = { checks: entry.checks || {}, appreciation: appreciation, note: note }
        return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids }
      })
    }

    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: intitules }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  Timer { id: evalFieldsDebounceTimer; interval: 600; repeat: false; onTriggered: root.persistEvaluationFields() }

  function selectEvaluationStudent(id) {
    root.flushEvaluationFieldsIfPending()
    root.evaluationStudentId = id
    root.loadEvaluationFields()
  }

  function selectEvaluationGrid(id) {
    root.flushEvaluationFieldsIfPending()
    root.evaluationGridId = id
    root.loadEvaluationFields()
  }

  // Reads the live fields directly rather than the (possibly not-yet-
  // debounced) stored value, so Copier/Exporter always reflect exactly
  // what's on screen.
  function buildEvaluationTypst() {
    var cls = root.activeClass()
    var grid = root.activeEvaluationGrid()
    var student = root.evaluationStudent()
    if (!cls || !grid || !student) return ""
    var entry = (student.competencyGrids && student.competencyGrids[grid.id]) || {}
    var payload = {
      checks: entry.checks || {},
      appreciation: evaluationAppreciationField.text,
      note: evaluationNoteField.text
    }
    return CompetencyGrids.buildTypstSource(Store.studentLabel(student), cls.name, grid, payload, evaluationIntituleField.text)
  }

  // Grade-estimation helper ("Proposer une note"): a headless Claude call
  // reads the checked levels + written appreciation and proposes a number
  // consistent with the fixed barème in PromptBuilder.js. Purely an in-app
  // suggestion shown in parentheses next to the note field — never
  // persisted, never written into the exported Typst/PDF, and reset
  // whenever the student/grid selection changes (loadEvaluationFields).
  property string evalNoteEstimate: ""
  property bool evalEstimating: false
  property string evalEstimateError: ""

  function requestNoteEstimate() {
    var grid = root.activeEvaluationGrid()
    var student = root.evaluationStudent()
    if (!grid || !student) return
    var entry = root.evaluationGridEntry()
    var checks = entry ? entry.checks : {}
    var prompt = PromptBuilder.buildNoteEstimatePrompt(grid.name, grid.rows, CompetencyGrids.COLUMNS, checks, evaluationAppreciationField.text)
    root.evalEstimating = true
    root.evalEstimateError = ""
    root.evalNoteEstimate = ""
    evalEstimateProc.command = ClaudeRunner.buildCommand(prompt)
    evalEstimateProc.running = false
    evalEstimateProc.running = true
  }

  Process {
    id: evalEstimateProc
    stdout: StdioCollector { id: evalEstimateOut; waitForEnd: true }
    stderr: StdioCollector { id: evalEstimateErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalEstimating = false
      if (exitCode !== 0) {
        root.evalEstimateError = (evalEstimateErr.text || "Échec de l'estimation.").slice(0, 300)
        return
      }
      root.evalNoteEstimate = (evalEstimateOut.text || "").trim().slice(0, 20)
    }
  }

  // Appréciation-generation helper ("Générer une appréciation"): unlike the
  // note estimate, this one writes straight into the Appréciation field
  // (it's text meant to be read/edited there anyway, not a number to
  // transcribe) — overwrites whatever was already typed, same as
  // "🆕 Nouvelle appréciation" does on the other tab. Fixed house rules
  // (Gabriel, 2026-09-26): vouvoiement, never discouraging, always
  // méthode → contenu → expression — enforced in the prompt itself
  // (PromptBuilder.buildEvalAppreciationPrompt), not re-checked here.
  property bool evalGeneratingAppreciation: false
  property string evalGenAppreciationError: ""

  function requestGenerateEvalAppreciation() {
    var grid = root.activeEvaluationGrid()
    var student = root.evaluationStudent()
    if (!grid || !student) return
    var entry = root.evaluationGridEntry()
    var checks = entry ? entry.checks : {}
    var prompt = PromptBuilder.buildEvalAppreciationPrompt(grid.name, grid.rows, CompetencyGrids.COLUMNS, checks, evaluationNoteField.text)
    root.evalGeneratingAppreciation = true
    root.evalGenAppreciationError = ""
    evalGenAppreciationProc.command = ClaudeRunner.buildCommand(prompt)
    evalGenAppreciationProc.running = false
    evalGenAppreciationProc.running = true
  }

  Process {
    id: evalGenAppreciationProc
    stdout: StdioCollector { id: evalGenAppreciationOut; waitForEnd: true }
    stderr: StdioCollector { id: evalGenAppreciationErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalGeneratingAppreciation = false
      if (exitCode !== 0) {
        root.evalGenAppreciationError = (evalGenAppreciationErr.text || "Échec de la génération.").slice(0, 500)
        return
      }
      var result = (evalGenAppreciationOut.text || "").trim()
      if (result) evaluationAppreciationField.text = result
    }
  }

  property string evalCopyFeedback: ""

  function copyEvaluationTypst() {
    var src = root.buildEvaluationTypst()
    if (!src) return
    evalCopyProc.command = ["wl-copy", src]
    evalCopyProc.running = false
    evalCopyProc.running = true
  }

  Process {
    id: evalCopyProc
    onExited: function(exitCode) {
      root.evalCopyFeedback = exitCode === 0 ? "Copié !" : "Échec de la copie."
      evalCopyFeedbackTimer.restart()
    }
  }
  Timer { id: evalCopyFeedbackTimer; interval: 2000; repeat: false; onTriggered: root.evalCopyFeedback = "" }

  property string evalPdfExportError: ""
  property string evalPdfExportedPath: ""
  property string _pendingEvalPdfPath: ""
  readonly property string evalExportSrcPath: root.stateDir + "/.ghclasses-eval-export.typ"

  function exportEvaluationPdf() {
    var student = root.evaluationStudent()
    if (!student) return
    root.pathBarMode = "exportEvalPdf"
    var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
    pathBarField.text = root.homeDir + "/Downloads/eval-" + root.slugify(Store.studentLabel(student)) + "-" + ts + ".pdf"
    Qt.callLater(function() { pathBarField.forceActiveFocus() })
  }

  // Same no-op-write guard as GH Typst's own spellcheck FileViews (see
  // this file's evalSpellcheckWordsFile/evalSpellcheckSuggestFile): unlike
  // statsExportFile (a fresh timestamped path every export, so always
  // "new" as far as FileView is concerned), evalExportSrcFile reuses ONE
  // fixed scratch path forever. Re-exporting a student without changing
  // anything since the last export writes byte-identical content, which
  // FileView never reports via onSaved — the compile step this depends on
  // would then just silently never run, with the button appearing to do
  // nothing. Confirmed bug in this exact shape, not a hypothetical: this
  // is what broke "Exporter en PDF" for Gabriel after a shell restart.
  property string _evalExportLastSrc: ""

  function startEvalPdfExport(destPath) {
    var src = root.buildEvaluationTypst()
    if (!src) return
    root.evalPdfExportError = ""
    root.evalPdfExportedPath = ""
    root._pendingEvalPdfPath = destPath
    if (src === root._evalExportLastSrc) {
      root._startEvalPdfCompile()
    } else {
      root._evalExportLastSrc = src
      evalExportSrcFile.setText(src)
    }
  }

  function _startEvalPdfCompile() {
    evalPdfCompileProc.command = ["typst", "compile", root.evalExportSrcPath, root._pendingEvalPdfPath]
    evalPdfCompileProc.running = false
    evalPdfCompileProc.running = true
  }

  FileView {
    id: evalExportSrcFile
    path: root.evalExportSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startEvalPdfCompile()
  }

  Process {
    id: evalPdfCompileProc
    stderr: StdioCollector { id: evalPdfCompileErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.evalPdfExportError = (evalPdfCompileErr.text || "Échec de l'export PDF.").slice(0, 500)
        return
      }
      root.evalPdfExportedPath = root._pendingEvalPdfPath
    }
  }

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
          || evaluationIntituleField.activeFocus || evaluationAppreciationField.activeFocus || evaluationNoteField.activeFocus
          || root.classSettingsOpen || root.incompatOpen || root.pathBarMode !== ""
          || root.deleteClassPendingId !== "" || root.resetDrawsConfirmOpen || root.syncSettingsOpen
          || root.resetEvaluationStudentConfirmOpen || root.resetEvaluationClassConfirmOpen
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
              height: Math.max(titleText.implicitHeight, settingsButton.implicitHeight, syncButton.implicitHeight)

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

              Button {
                id: syncButton
                anchors.right: settingsButton.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                text: "🔄 Synchro"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                tooltipText: root.syncDir !== "" ? ("Synchronisée vers : " + root.syncDir) : "Synchronisation désactivée"
                onClicked: root.openSyncSettings()
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
                  { value: "evaluation", label: "📋 Eval. Compétences" },
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

              // Shared path-entry bar for any tab's "export to a path"
              // action (root.pathBarMode selects which one) — one TextField
              // reused across tabs rather than duplicated per tab.
              Column {
                visible: root.pathBarMode !== ""
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  text: root.pathBarMode === "exportEvalPdf" ? "Exporter la grille (.pdf) vers :" : "Exporter les statistiques (.csv) vers :"
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
                  Button {
                    text: "♻ Réinitialiser les tirages"
                    bordered: true
                    foreground: root.foreground
                    accent: Color.urgent
                    onClicked: root.requestResetDraws()
                  }
                }

                Text {
                  visible: root.activeClass() && root.activeClass().lastResetAt !== ""
                  width: parent.width
                  text: "Dernier reset le " + (root.activeClass() ? Qt.formatDateTime(new Date(root.activeClass().lastResetAt), "dd/MM/yyyy à HH:mm") : "")
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
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

                Dropdown {
                  id: appreciationStudentDropdown
                  visible: root.appreciationMode === "copies"
                  label: "Élève (pour la copie)"
                  options: [{ value: "", label: "— Sélectionner un élève —" }].concat(
                    root.activeClass()
                      ? root.activeClass().students.map(function(s) { return { value: s.id, label: Store.studentLabel(s) } })
                      : []
                  )
                  value: root.appreciationStudentId
                  foreground: root.foreground
                  background: root.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(value) { root.appreciationStudentId = value }
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
                    id: maxCharsDropdown
                    label: "Longueur max"
                    options: [
                      { value: "100", label: "100 caractères" },
                      { value: "120", label: "120 caractères" },
                      { value: "140", label: "140 caractères" },
                      { value: "160", label: "160 caractères" },
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

                  // Wrapped in an Item matching the dropdown's full height
                  // (label + gap + control) and anchored to its bottom, so
                  // this button's box lines up with the dropdown's actual
                  // trigger control rather than its label row — a bare Flow
                  // top-aligns mismatched-height children, which is what
                  // made these buttons sit visibly too high before.
                  Item {
                    width: generateButton.implicitWidth
                    height: maxCharsDropdown.implicitHeight
                    Button {
                      id: generateButton
                      anchors.bottom: parent.bottom
                      text: root.generatingAppreciation ? "Génération en cours…" : "🪄 Générer l'appréciation"
                      bordered: true
                      enabled: !root.generatingAppreciation
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.generateAppreciation()
                    }
                  }

                  Item {
                    width: newAppreciationButton.implicitWidth
                    height: maxCharsDropdown.implicitHeight
                    Button {
                      id: newAppreciationButton
                      anchors.bottom: parent.bottom
                      text: "🆕 Nouvelle appréciation"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.resetAppreciationForm()
                    }
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
                    Button {
                      visible: root.appreciationMode === "copies"
                      text: "🏷 Ajouter à la planche d'étiquettes"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Bientôt disponible — en attente du gabarit d'étiquettes"
                      onClicked: root.addAppreciationToLabelSheet()
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

                  Text {
                    visible: root.labelSheetFeedback !== ""
                    width: parent.width
                    text: root.labelSheetFeedback
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }
              }

              // ================================================ évaluation

              Column {
                visible: root.activeFeatureTab === "evaluation"
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
                  spacing: Style.spacing.huge

                  Dropdown {
                    id: evaluationStudentDropdown
                    label: "Élève"
                    options: [{ value: "", label: "— Sélectionner un élève —" }].concat(
                      root.activeClass()
                        ? root.activeClass().students.map(function(s) { return { value: s.id, label: Store.studentLabel(s) } })
                        : []
                    )
                    value: root.evaluationStudentId
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(value) { root.selectEvaluationStudent(value) }
                  }

                  Dropdown {
                    id: evaluationGridDropdown
                    label: "Type de tableau"
                    options: CompetencyGrids.GRIDS.map(function(g) { return { value: g.id, label: g.name } })
                    value: root.evaluationGridId
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(value) { root.selectEvaluationGrid(value) }
                  }

                  // One intitulé per (classe, type de tableau) — shared by
                  // every student evaluated on it, not retyped per student.
                  Column {
                    spacing: Style.spacing.xxs
                    Text {
                      text: "Intitulé de l'évaluation"
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    TextField {
                      id: evaluationIntituleField
                      width: Style.space(320)
                      foreground: root.foreground
                      accent: root.accent
                      placeholderText: "ex. Devoir sur table n°2"
                      onTextChanged: root.queueEvaluationFieldsPersist()
                    }
                  }
                }

                Text {
                  visible: root.activeClass() && root.activeClass().students.length > 0 && root.evaluationStudentId === ""
                  text: "Sélectionnez un élève pour afficher/éditer sa grille."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Column {
                  id: evalTable
                  visible: root.evaluationStudentId !== "" && root.activeEvaluationGrid() !== null
                  width: parent.width
                  spacing: Style.spacing.xs

                  Row {
                    width: parent.width
                    spacing: Style.spacing.xs

                    Text {
                      width: parent.width - root.evalCellsTotalWidth
                      text: "Critères"
                      font.bold: true
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Repeater {
                      model: CompetencyGrids.COLUMNS
                      delegate: Text {
                        required property string modelData
                        width: root.evalCellColWidth
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
                    model: root.activeEvaluationGrid() ? root.activeEvaluationGrid().rows : []
                    delegate: Column {
                      id: rowRoot
                      required property var modelData
                      required property int index
                      width: evalTable.width

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
                          width: parent.width - root.evalCellsTotalWidth
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
                            width: root.evalCellColWidth
                            height: Style.space(28)
                            radius: Style.cornerRadius
                            property bool checked: root.evaluationCheckedCol(rowRoot.index) === cell.index
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
                              onClicked: root.setEvaluationCheck(rowRoot.index, cell.index)
                            }
                          }
                        }
                      }
                    }
                  }
                }

                Column {
                  visible: root.evaluationStudentId !== "" && root.activeEvaluationGrid() !== null
                  width: parent.width
                  spacing: Style.spacing.xxs

                  Text {
                    text: "Appréciation"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(160)
                    radius: Style.cornerRadius
                    color: Style.normalFillFor(root.foreground, root.accent)
                    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                    border.width: 1
                    clip: true

                    ScrollView {
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      clip: true
                      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                      TextArea {
                        id: evaluationAppreciationField
                        wrapMode: TextArea.Wrap
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        background: null
                        placeholderText: "Appréciation pour cet élève…"
                        onTextChanged: {
                          root.queueEvaluationFieldsPersist()
                          root.requestEvalSpellcheck(text)
                        }
                      }
                    }
                  }

                  // Local spellcheck (hunspell, offline) — one chip per
                  // misspelled word; click for suggestions, click a
                  // suggestion to replace every occurrence of that word.
                  Flow {
                    visible: root.spellcheckAvailable && root.evalMisspelledWords.length > 0
                    width: parent.width
                    spacing: Style.spacing.xs

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Orthographe :"
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Repeater {
                      model: root.evalMisspelledWords
                      delegate: Rectangle {
                        id: spellChip
                        required property string modelData
                        radius: Style.cornerRadius
                        width: spellChipText.implicitWidth + Style.space(16)
                        height: spellChipText.implicitHeight + Style.space(6)
                        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
                        border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)
                        border.width: 1

                        Text {
                          id: spellChipText
                          anchors.centerIn: parent
                          text: spellChip.modelData
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          textFormat: Text.PlainText
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.requestEvalSuggestions(spellChip.modelData)
                            evalSpellSuggestMenu.targetWord = spellChip.modelData
                            evalSpellSuggestMenu.popup()
                          }
                        }
                      }
                    }

                    Menu {
                      id: evalSpellSuggestMenu
                      property string targetWord: ""
                      readonly property bool resultReady: !root.evalSuggestBusy && root.evalSuggestWord === targetWord

                      MenuItem {
                        visible: !evalSpellSuggestMenu.resultReady
                        enabled: false
                        text: "Recherche de suggestions…"
                      }
                      MenuItem {
                        visible: evalSpellSuggestMenu.resultReady && root.evalSuggestions.length === 0
                        enabled: false
                        text: "Aucune suggestion"
                      }
                      Repeater {
                        model: evalSpellSuggestMenu.resultReady ? root.evalSuggestions : []
                        MenuItem {
                          required property string modelData
                          text: modelData
                          onTriggered: root.applyEvalSuggestion(evalSpellSuggestMenu.targetWord, modelData)
                        }
                      }
                    }
                  }
                }

                Column {
                  visible: root.evaluationStudentId !== "" && root.activeEvaluationGrid() !== null
                  spacing: Style.spacing.xxs

                  Text {
                    text: "Note"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Row {
                    spacing: Style.spacing.xs

                    TextField {
                      id: evaluationNoteField
                      width: Style.space(80)
                      foreground: root.foreground
                      accent: root.accent
                      placeholderText: "—"
                      onTextChanged: root.queueEvaluationFieldsPersist()
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "/ 20"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.evalEstimating ? "Estimation…" : "🎯 Proposer une note"
                      bordered: true
                      enabled: !root.evalEstimating
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.requestNoteEstimate()
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.evalGeneratingAppreciation ? "Génération…" : "🧠 Générer une appréciation"
                      bordered: true
                      enabled: !root.evalGeneratingAppreciation
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Remplace le texte actuel de l'Appréciation ci-dessus"
                      onClicked: root.requestGenerateEvalAppreciation()
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.evalNoteEstimate !== ""
                      text: "(estimation : " + root.evalNoteEstimate + " / 20)"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                    }
                  }

                  Text {
                    visible: root.evalEstimateError !== ""
                    width: Style.space(320)
                    text: root.evalEstimateError
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Text {
                    visible: root.evalGenAppreciationError !== ""
                    width: Style.space(320)
                    text: root.evalGenAppreciationError
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }
                }

                Row {
                  visible: root.evaluationStudentId !== ""
                  spacing: Style.spacing.controlGap

                  Button {
                    text: "📋 Copier le code Typst"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.copyEvaluationTypst()
                  }
                  Button {
                    text: "📄 Exporter en PDF"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.exportEvaluationPdf()
                  }
                  Button {
                    text: "🗑 Réinitialiser cet élève"
                    bordered: true
                    foreground: root.foreground
                    accent: Color.urgent
                    onClicked: root.requestResetEvaluationStudent()
                  }
                  Button {
                    text: "🗑 Réinitialiser la classe"
                    bordered: true
                    foreground: root.foreground
                    accent: Color.urgent
                    onClicked: root.requestResetEvaluationClass()
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.evalCopyFeedback !== ""
                    text: root.evalCopyFeedback
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Text {
                  visible: root.evalPdfExportedPath !== ""
                  width: parent.width
                  text: "Grille exportée : " + root.evalPdfExportedPath
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                }

                Text {
                  visible: root.evalPdfExportError !== ""
                  width: parent.width
                  text: root.evalPdfExportError
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
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

      SyncSettingsPopover {
        anchors.fill: parent
        opened: root.syncSettingsOpen
        currentDir: root.syncDir
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onDirConfirmed: function(dir) { root.confirmSyncDir(dir) }
        onDirCleared: root.clearSyncDir()
        onCanceled: root.closeSyncSettings()
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

      ConfirmDialog {
        anchors.fill: parent
        opened: root.resetDrawsConfirmOpen
        message: "Réinitialiser le décompte des tirages pour \"" + (root.activeClass() ? root.activeClass().name : "") + "\" ? L'historique de tous les élèves sera effacé. Cette action est irréversible."
        cancelText: "Annuler"
        confirmText: "Réinitialiser"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelResetDraws()
        onConfirmed: root.confirmResetDraws()
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.resetEvaluationStudentConfirmOpen
        message: "Réinitialiser l'évaluation \"" + (root.activeEvaluationGrid() ? root.activeEvaluationGrid().name : "") + "\" de " + (root.evaluationStudent() ? Store.studentLabel(root.evaluationStudent()) : "") + " ? Le tableau, l'appréciation et la note de cet élève pour ce type de tableau seront effacés. Cette action est irréversible."
        cancelText: "Annuler"
        confirmText: "Réinitialiser"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelResetEvaluationStudent()
        onConfirmed: root.confirmResetEvaluationStudent()
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.resetEvaluationClassConfirmOpen
        message: "Réinitialiser toutes les évaluations \"" + (root.activeEvaluationGrid() ? root.activeEvaluationGrid().name : "") + "\" de la classe \"" + (root.activeClass() ? root.activeClass().name : "") + "\" ? Le tableau, l'appréciation et la note de CHAQUE élève pour ce type de tableau seront effacés. Cette action est irréversible."
        cancelText: "Annuler"
        confirmText: "Réinitialiser"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelResetEvaluationClass()
        onConfirmed: root.confirmResetEvaluationClass()
      }
    }
  }
}

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
import "lib/CorrectionsStore.js" as CorrectionsStore
import "lib/CopyMatcher.js" as CopyMatcher
import "lib/CorrectionPromptBuilder.js" as CorrectionPromptBuilder
import "lib/FilesCheckPromptBuilder.js" as FilesCheckPromptBuilder
import "lib/ExerciseTypes.js" as ExerciseTypes
import "lib/ConsignesBuilder.js" as ConsignesBuilder
import "lib/ConsignesTemplateCommentaire.js" as TemplateCommentaire
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
  // No theme token for "validated/success" exists in this shell (only
  // foreground/accent/urgent) — a literal green, legible on both light and
  // dark panel backgrounds, marks a grade Gabriel has clicked to validate.
  // Same rationale as GH Slide's own literal warningColor.
  readonly property color gradeValidatedColor: "#4c9a52"

  // ---- paths ------------------------------------------------------------

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateDir: root.homeDir + "/.local/state/omarchy/plugins/io.github.gabrielharfield.ghclasses"
  readonly property string classesPath: root.stateDir + "/classes.json"
  readonly property string settingsPath: root.stateDir + "/settings.json"
  readonly property string correctionsPath: root.stateDir + "/corrections.json"
  readonly property string correctionRunsDir: root.stateDir + "/corrections-runs"

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
    root.activeClassId = id
    root.persistSettings()
    root.lastDraw = []
    root.lastGroups = []
    root.lastGroupsUnresolved = []
    root.appreciationStudentId = ""
    root.resetCorrectionDraft()
  }

  property string activeFeatureTab: "tirage" // tirage | groupes | appreciations | corrections | exercices

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
        lastResetAt: ""
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
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt }
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
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: resetStudents, incompatibilities: cls.incompatibilities, lastResetAt: new Date().toISOString() }
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

  // Markdown variant for pasting straight into École Directe (n'accepte que
  // du markdown) — groups in bold, "NOM Prénom" with nom in caps and prénom
  // title-cased regardless of the roster's own stored casing.
  function copyGroupsMarkdown() {
    if (root.lastGroups.length === 0) return
    var lines = []
    root.lastGroups.forEach(function(g, i) {
      lines.push("**Groupe " + (i + 1) + "**")
      g.forEach(function(s) { lines.push("- " + Store.studentLabelFormatted(s)) })
      lines.push("")
    })
    groupsCopyProc.command = ["wl-copy", lines.join("\n").trim()]
    groupsCopyProc.running = false
    groupsCopyProc.running = true
  }

  property bool incompatOpen: false
  function openIncompat() { root.incompatOpen = true }
  function closeIncompat() { root.incompatOpen = false }

  function addIncompatibilitySet(ids) {
    var cls = root.activeClass()
    if (!cls || !ids || ids.length < 2) return
    if (cls.incompatibilities.length >= Store.MAX_INCOMPATIBILITY_SETS) return
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities.concat([ids]), lastResetAt: cls.lastResetAt }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  function removeIncompatibilitySet(index) {
    var cls = root.activeClass()
    if (!cls) return
    var list = cls.incompatibilities.slice()
    list.splice(index, 1)
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: list, lastResetAt: cls.lastResetAt }
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

  // ---- feature 4: corrections ------------------------------------------
  //
  // One évaluation (devoir) at a time per class — creating a new one for a
  // class replaces the previous one (confirmed with Gabriel 2026-09-13).
  // State lives in its own corrections.json (NOT synced via GH Classes'
  // classes.json mechanism: an Evaluation is anchored to local filesystem
  // paths — dossier du devoir, copies PDF — that mean nothing on another
  // machine). The correction agent itself is a per-student headless Claude
  // Code run with file access (ClaudeRunner.buildFileCommand), triggered
  // one row at a time from the table and serialized through a small queue
  // so at most one such process ever runs at once.

  property var corrections: ({}) // { [classId]: Evaluation }

  FileView {
    id: correctionsFile
    path: root.correctionsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.corrections = CorrectionsStore.parseCorrections(correctionsFile.text())
    onLoadFailed: root.corrections = {}
  }

  function persistCorrections() {
    correctionsFile.setText(CorrectionsStore.serializeCorrections(root.corrections))
  }

  function currentCorrectionsClassId() {
    var cls = root.activeClass()
    return cls ? cls.id : ""
  }

  function activeEvaluation() {
    return CorrectionsStore.getEvaluation(root.corrections, root.currentCorrectionsClassId())
  }

  function setCorrectionStudentPatch(classId, studentId, patch) {
    var ev = CorrectionsStore.getEvaluation(root.corrections, classId)
    if (!ev) return
    var updated = CorrectionsStore.withStudentPatch(ev, studentId, patch)
    root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
    root.persistCorrections()
  }

  // ---- creation form (draft fields, reset on class switch) ----
  //
  // consignes.md is no longer a path Gabriel points at or hand-writes: it's
  // generated from these fields (+ exerciseType's own fixed template, if any
  // — see ConsignesBuilder.js/ExerciseTypes.js) and written automatically
  // into correctionDraftFolder at creation time. The old, separate
  // "Assistant — Consignes" popover (ui/ConsignesWizardPopover.qml) is
  // retired from this flow — Gabriel, 2026-09-24.

  property string correctionDraftTitle: ""
  property string correctionDraftFolder: ""
  property string correctionDraftSujet: ""
  property string correctionDraftCorrige: ""
  property string correctionDraftAgent: ""
  property string correctionDraftExerciseType: ""
  property string correctionDraftNature: "tp_individuel"
  property string correctionDraftType: "formative"
  property int correctionDraftDuree: 60
  property string correctionDraftNiveauClasse: "1ere"
  property int correctionDraftBienveillance: 5
  property bool correctionDraftPriseDeNotes: false
  property bool correctionDraftCompletudeExigee: true
  property real correctionDraftEcart: 2
  property string correctionDraftSurinterpretation: "neutre"
  property string correctionDraftNiveauDetail: "moyen"
  property string correctionDraftComplements: ""
  property string correctionDraftWritingMode: "manuscrit"
  property var correctionDraftWritingExceptions: []
  property string correctionCreateError: ""
  property bool correctionCreating: false
  property var _pendingCorrectionDraft: null
  property var _correctionValidateQueue: []

  function resetCorrectionDraft() {
    root.correctionDraftTitle = ""
    root.correctionDraftFolder = ""
    root.correctionDraftSujet = ""
    root.correctionDraftCorrige = ""
    root.correctionDraftAgent = ""
    root.correctionDraftExerciseType = ""
    root.correctionDraftNature = "tp_individuel"
    root.correctionDraftType = "formative"
    root.correctionDraftDuree = 60
    root.correctionDraftNiveauClasse = "1ere"
    root.correctionDraftBienveillance = 5
    root.correctionDraftPriseDeNotes = false
    root.correctionDraftCompletudeExigee = true
    root.correctionDraftEcart = 2
    root.correctionDraftSurinterpretation = "neutre"
    root.correctionDraftNiveauDetail = "moyen"
    root.correctionDraftComplements = ""
    root.correctionDraftWritingMode = "manuscrit"
    root.correctionDraftWritingExceptions = []
    root.correctionCreateError = ""
    root.correctionCreating = false
  }

  // The fixed consignes corpus for the currently-selected exerciseType, or
  // "" if none is written yet (ExerciseTypes.hasTemplate() is false) — the
  // one place that knows how to resolve an exerciseType to its template
  // module, since ConsignesBuilder.js deliberately doesn't import
  // ExerciseTypes.js/ConsignesTemplateCommentaire.js itself (see that file's
  // header comment).
  function fixedConsignesBlockFor(exerciseType) {
    if (exerciseType === "commentaire") return TemplateCommentaire.fixedBlock()
    return ""
  }

  function requestCreateEvaluation() {
    var classId = root.currentCorrectionsClassId()
    var cls = root.activeClass()
    if (!classId || !cls) { root.correctionCreateError = "Sélectionnez une classe."; return }
    var title = String(root.correctionDraftTitle || "").trim().slice(0, CorrectionsStore.MAX_TITLE_LEN)
    var folder = root.expandHome(root.correctionDraftFolder).replace(/\/+$/, "")
    var sujet = root.expandHome(root.correctionDraftSujet)
    var corrige = root.expandHome(root.correctionDraftCorrige)
    var agent = root.expandHome(root.correctionDraftAgent)
    if (!root.correctionDraftExerciseType) { root.correctionCreateError = "Choisissez un type d'exercice."; return }
    if (!title) { root.correctionCreateError = "Donnez un titre au devoir."; return }
    if (!folder) { root.correctionCreateError = "Indiquez le dossier du devoir."; return }
    // Corrigé is optional: some devoirs have no single correct answer to
    // hand the agent (ex. une fiche de lecture où chaque élève a lu un
    // livre différent) — see Gabriel, 2026-09-13.
    if (!sujet || !agent) {
      root.correctionCreateError = "Indiquez au moins le sujet et l'agent (le corrigé est facultatif)."
      return
    }
    var consignesText = ConsignesBuilder.build({
      exerciseType: root.correctionDraftExerciseType,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      ecartSevereBienveillante: root.correctionDraftEcart,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      complements: root.correctionDraftComplements,
      fixedBlock: root.fixedConsignesBlockFor(root.correctionDraftExerciseType)
    })
    root._pendingCorrectionDraft = {
      classId: classId, title: title, folder: folder,
      sujet: sujet, corrige: corrige, agent: agent,
      consignesPath: folder + "/consigne.md", consignesText: consignesText,
      exerciseType: root.correctionDraftExerciseType,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      ecartSevereBienveillante: root.correctionDraftEcart,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      complements: root.correctionDraftComplements,
      writingMode: root.correctionDraftWritingMode, writingExceptions: root.correctionDraftWritingExceptions
    }
    root.correctionCreating = true
    root.correctionCreateError = ""
    // Each path is checked with its own plain `test` invocation (argv
    // only, no shell) — chained one at a time rather than combined into a
    // single script string. consigne.md itself isn't checked here: it
    // doesn't exist yet (see finishCorrectionCreation() below, which checks
    // for a pre-existing file at that generated path before writing it).
    root._correctionValidateQueue = [
      { flag: "-d", path: folder },
      { flag: "-f", path: sujet },
      { flag: "-f", path: agent }
    ]
    if (corrige) root._correctionValidateQueue.push({ flag: "-f", path: corrige })
    root.runNextCorrectionValidation()
  }

  function runNextCorrectionValidation() {
    if (root._correctionValidateQueue.length === 0) {
      // correctionCreating stays true through the consigne.md write below —
      // finalizeCorrectionCreation()/cancelCorrectionConsignesOverwrite()
      // clear it, so the "Créer l'évaluation" button can't be double-clicked
      // during that last async step.
      root.finishCorrectionCreation()
      return
    }
    var next = root._correctionValidateQueue[0]
    root._correctionValidateQueue = root._correctionValidateQueue.slice(1)
    correctionValidateProc.command = ["test", next.flag, next.path]
    correctionValidateProc.running = false
    correctionValidateProc.running = true
  }

  Process {
    id: correctionValidateProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.correctionCreating = false
        root._pendingCorrectionDraft = null
        root._correctionValidateQueue = []
        root.correctionCreateError = "Chemin(s) introuvable(s) — vérifiez le dossier du devoir, le sujet, l'agent, et le corrigé si vous en avez indiqué un."
        return
      }
      root.runNextCorrectionValidation()
    }
  }

  // ---- final step of évaluation creation: write the generated consigne.md
  // then persist the évaluation itself ------------------------------------
  // Same caution as classes.json/corrections.json — see
  // feedback_never-overwrite-plugin-state-for-testing: consigne.md's path is
  // computed from the dossier du devoir, which Gabriel could point at a
  // folder that already has one (ex. re-creating an évaluation after
  // deleting it) — `test -f` first, confirm only if something's already
  // there, same pattern as the old consignes wizard's save step.

  property bool correctionConsignesOverwriteConfirmOpen: false

  function finishCorrectionCreation() {
    var d = root._pendingCorrectionDraft
    if (!d) return
    correctionConsignesExistsProc.command = ["test", "-f", d.consignesPath]
    correctionConsignesExistsProc.running = false
    correctionConsignesExistsProc.running = true
  }

  Process {
    id: correctionConsignesExistsProc
    onExited: function(exitCode) {
      if (exitCode === 0) root.correctionConsignesOverwriteConfirmOpen = true
      else root.finalizeCorrectionCreation()
    }
  }

  function cancelCorrectionConsignesOverwrite() {
    root.correctionConsignesOverwriteConfirmOpen = false
    root._pendingCorrectionDraft = null
    root.correctionCreating = false
    root.correctionCreateError = "Un fichier consigne.md existe déjà dans ce dossier — renommez-le ou déplacez-le avant de créer l'évaluation."
  }

  function finalizeCorrectionCreation() {
    var d = root._pendingCorrectionDraft
    root._pendingCorrectionDraft = null
    root.correctionConsignesOverwriteConfirmOpen = false
    root.correctionCreating = false
    if (!d) return
    var cls = Store.findClass(root.classes, d.classId)
    if (!cls) return
    correctionConsignesSaveFile.path = d.consignesPath
    correctionConsignesSaveFile.setText(d.consignesText)
    var studentIds = cls.students.map(function(s) { return s.id })
    var evaluation = CorrectionsStore.createEvaluation({
      title: d.title, folderPath: d.folder, sujetPath: d.sujet,
      corrigePath: d.corrige, consignesPath: d.consignesPath, agentPath: d.agent,
      studentIds: studentIds,
      writingMode: d.writingMode, writingExceptions: d.writingExceptions,
      exerciseType: d.exerciseType,
      natureEvaluation: d.natureEvaluation, typeEvaluation: d.typeEvaluation,
      dureeEpreuve: d.dureeEpreuve, niveauClasse: d.niveauClasse,
      bienveillance: d.bienveillance, priseDeNotes: d.priseDeNotes,
      completudeExigee: d.completudeExigee, ecartSevereBienveillante: d.ecartSevereBienveillante,
      surinterpretation: d.surinterpretation, niveauDetail: d.niveauDetail,
      complements: d.complements
    })
    root.corrections = CorrectionsStore.setEvaluation(root.corrections, d.classId, evaluation)
    root.persistCorrections()
    root.resetCorrectionDraft()
    root.refreshCorrectionCopies()
  }

  FileView {
    id: correctionConsignesSaveFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // ---- pre-launch file check (optional) ----------------------------------
  // Gabriel, 2026-09-17: reads sujet/corrigé/consignes/agent together and
  // reports any unclear point or cross-file inconsistency BEFORE creating
  // the évaluation — separate from requestCreateEvaluation()'s own `test
  // -f` existence check, which only confirms the paths exist, not that
  // their content makes sense together.

  property bool filesCheckPopoverOpen: false
  property bool filesCheckRunning: false
  property string filesCheckResult: ""
  property string filesCheckError: ""

  // consigne.md doesn't exist on disk yet at this point in the flow (it's
  // only written once "Créer l'évaluation" succeeds, see
  // finalizeCorrectionCreation()) — so the check renders the SAME draft
  // fields through ConsignesBuilder and writes that text to a throwaway
  // scratch file under the plugin's own state dir (not the dossier du
  // devoir) purely so the read-only check agent has a real path to open.
  function requestCheckCorrectionFiles() {
    var sujet = root.expandHome(root.correctionDraftSujet)
    var corrige = root.expandHome(root.correctionDraftCorrige)
    var agent = root.expandHome(root.correctionDraftAgent)
    root.filesCheckResult = ""
    root.filesCheckPopoverOpen = true
    if (!sujet || !agent || !root.correctionDraftExerciseType) {
      root.filesCheckError = "Choisissez un type d'exercice et indiquez au moins le sujet et l'agent avant de vérifier (le corrigé est facultatif)."
      return
    }
    root.filesCheckError = ""
    root.filesCheckRunning = true
    var consignesText = ConsignesBuilder.build({
      exerciseType: root.correctionDraftExerciseType,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      ecartSevereBienveillante: root.correctionDraftEcart,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      complements: root.correctionDraftComplements,
      fixedBlock: root.fixedConsignesBlockFor(root.correctionDraftExerciseType)
    })
    var consignesCheckPath = root.stateDir + "/consignes-check-draft.md"
    filesCheckConsignesFile.path = consignesCheckPath
    filesCheckConsignesFile.setText(consignesText)
    var prompt = FilesCheckPromptBuilder.build({
      sujetPath: sujet, corrigePath: corrige, consignesPath: consignesCheckPath, agentPath: agent
    })
    filesCheckProc.command = ClaudeRunner.buildCheckCommand(prompt)
    filesCheckProc.running = false
    filesCheckProc.running = true
  }

  FileView {
    id: filesCheckConsignesFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: filesCheckProc
    stdout: StdioCollector { id: filesCheckOut; waitForEnd: true }
    stderr: StdioCollector { id: filesCheckErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.filesCheckRunning = false
      if (exitCode !== 0) {
        root.filesCheckError = (filesCheckErr.text || "Échec de la vérification.").slice(0, 500)
        return
      }
      root.filesCheckResult = (filesCheckOut.text || "").trim()
    }
  }

  function closeFilesCheckPopover() { root.filesCheckPopoverOpen = false }

  property bool correctionReplaceConfirmOpen: false
  function requestNewEvaluation() { root.correctionReplaceConfirmOpen = true }
  function cancelNewEvaluation() { root.correctionReplaceConfirmOpen = false }
  function confirmNewEvaluation() {
    var classId = root.currentCorrectionsClassId()
    root.correctionReplaceConfirmOpen = false
    if (!classId) return
    root.corrections = CorrectionsStore.deleteEvaluation(root.corrections, classId)
    root.persistCorrections()
    root.resetCorrectionDraft()
  }

  // ---- rattachement des copies (matching folder contents to students) ----

  property bool correctionMatching: false

  function refreshCorrectionCopies() {
    var ev = root.activeEvaluation()
    if (!ev) return
    var cmd = CopyMatcher.listPdfCommand(ev.folderPath)
    if (!cmd) return
    root.correctionMatching = true
    correctionListProc.command = cmd
    correctionListProc.running = false
    correctionListProc.running = true
  }

  Process {
    id: correctionListProc
    stdout: StdioCollector { id: correctionListOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.correctionMatching = false
      var classId = root.currentCorrectionsClassId()
      var cls = root.activeClass()
      var ev = CorrectionsStore.getEvaluation(root.corrections, classId)
      if (!cls || !ev) return
      var files = CopyMatcher.parseFileList(correctionListOut.text || "")
      var matches = CopyMatcher.matchCopies(files, cls.students)
      var updated = ev
      for (var i = 0; i < cls.students.length; i++) {
        var sid = cls.students[i].id
        if (matches[sid]) updated = CorrectionsStore.withStudentPatch(updated, sid, { copyPath: matches[sid], excluded: false })
      }
      root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
      root.persistCorrections()
    }
  }

  // ---- per-copy correction runs (queued, one Claude process at a time) --

  property var correctionQueue: [] // [{classId, studentId}, ...]
  property string correctionRunningStudentId: ""
  property var _correctionRunContext: null // {classId, studentId, runDir, appreciationPath, logPath}
  property string _correctionStderr: ""

  function requestCorrectStudent(studentId) {
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!classId || !ev) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    if (!entry.copyPath) return
    if (root.correctionRunningStudentId === studentId) return
    for (var i = 0; i < root.correctionQueue.length; i++) {
      if (root.correctionQueue[i].studentId === studentId) return
    }
    root.correctionQueue = root.correctionQueue.concat([{ classId: classId, studentId: studentId }])
    root.processCorrectionQueue()
  }

  function processCorrectionQueue() {
    if (root.correctionRunningStudentId !== "") return
    if (root.correctionQueue.length === 0) return
    var next = root.correctionQueue[0]
    root.correctionQueue = root.correctionQueue.slice(1)
    root.startCorrectionRun(next.classId, next.studentId)
  }

  function startCorrectionRun(classId, studentId) {
    var ev = CorrectionsStore.getEvaluation(root.corrections, classId)
    var cls = Store.findClass(root.classes, classId)
    if (!ev || !cls) { root.processCorrectionQueue(); return }
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    if (!entry.copyPath) { root.processCorrectionQueue(); return }

    root.correctionRunningStudentId = studentId
    root.setCorrectionStudentPatch(classId, studentId, { status: "running", error: "" })

    var runId = Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss-zzz")
    var runDir = root.correctionRunsDir + "/" + ev.id + "/" + studentId + "-" + runId
    root._correctionRunContext = {
      classId: classId, studentId: studentId, runDir: runDir,
      appreciationPath: runDir + "/appreciation.typ", logPath: runDir + "/log.md",
      notesPath: runDir + "/notes.txt",
      // Anonymized copy of the student's PDF, read by Claude instead of the
      // original — the original's filename follows "NOM-Prénom-Classe.pdf"
      // (see CopyMatcher.js), which would otherwise be the only thing in
      // this whole run identifying the student to Anthropic's servers (the
      // prompt itself never names the student — see CorrectionPromptBuilder,
      // Gabriel, 2026-09-19). studentId in the run dir path above is an
      // opaque internal id, not the student's name, so it's fine as-is.
      anonymizedCopyPath: runDir + "/copie.pdf"
    }
    correctionMkdirProc.command = ["mkdir", "-p", "--", runDir]
    correctionMkdirProc.running = false
    correctionMkdirProc.running = true
  }

  Process {
    id: correctionMkdirProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.finalizeCorrectionError("Impossible de créer le dossier de travail de la correction.")
        return
      }
      root.copyCorrectionCopyForRun()
    }
  }

  // Rebuilds the student's original (name-bearing) PDF under an anonymous
  // filename inside the run's own directory, so that's what gets named in
  // the prompt/Read call sent to Claude — the original stays untouched on
  // disk for "👁 Voir la copie" and everything else. Deliberately a qpdf
  // page-by-page reconstruction rather than a plain `cp`: a straight copy
  // renames the file but carries over the PDF's own /Info metadata dict
  // verbatim (Title/Author/Producer...) — some scan/export tools populate
  // that from the original filename or a signed-in account name, which
  // would silently defeat the whole point of renaming the file. Verified
  // (Gabriel, 2026-09-19) that this reconstruction drops /Info entirely
  // (checked with qpdf --show-object=trailer + pdfinfo on a real copy)
  // while leaving the page count/content untouched.
  function copyCorrectionCopyForRun() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    var ev = CorrectionsStore.getEvaluation(root.corrections, ctx.classId)
    var entry = ev ? CorrectionsStore.studentEntry(ev, ctx.studentId) : null
    if (!entry || !entry.copyPath) { root.finalizeCorrectionError("Copie introuvable pour cet élève."); return }
    correctionAnonymizeCopyProc.command = ["qpdf", "--empty", "--pages", entry.copyPath, "1-z", "--", ctx.anonymizedCopyPath]
    correctionAnonymizeCopyProc.running = false
    correctionAnonymizeCopyProc.running = true
  }

  Process {
    id: correctionAnonymizeCopyProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.finalizeCorrectionError("Impossible de préparer une copie anonymisée du fichier.")
        return
      }
      root.startCorrectionClaude()
    }
  }

  function startCorrectionClaude() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    var ev = CorrectionsStore.getEvaluation(root.corrections, ctx.classId)
    var cls = Store.findClass(root.classes, ctx.classId)
    if (!ev || !cls) { root.finalizeCorrectionError("Évaluation introuvable."); return }
    var student = null
    for (var i = 0; i < cls.students.length; i++) if (cls.students[i].id === ctx.studentId) student = cls.students[i]
    var entry = CorrectionsStore.studentEntry(ev, ctx.studentId)
    if (!student || !entry.copyPath) { root.finalizeCorrectionError("Copie introuvable pour cet élève."); return }

    // Computed from `ev` (the evaluation fetched for ctx.classId above),
    // not via root.studentWritingMode()/root.activeEvaluation() — this run
    // may finish after Gabriel has switched to another class, and those
    // helpers read whatever class is CURRENTLY active, not the one this
    // run belongs to.
    var isWritingException = ev.writingExceptions.indexOf(ctx.studentId) !== -1
    var writingMode = isWritingException
      ? (ev.writingMode === "manuscrit" ? "tapuscrit" : "manuscrit")
      : ev.writingMode

    var prompt = CorrectionPromptBuilder.build({
      sujetPath: ev.sujetPath, corrigePath: ev.corrigePath,
      consignesPath: ev.consignesPath, agentPath: ev.agentPath,
      copyPath: ctx.anonymizedCopyPath,
      writingMode: writingMode,
      addendum: entry.addendum,
      appreciationOutputPath: ctx.appreciationPath,
      logOutputPath: ctx.logPath,
      notesOutputPath: ctx.notesPath,
      exerciseType: ev.exerciseType,
      usesPlanExtraction: ExerciseTypes.usesPlanExtraction(ev.exerciseType),
      niveauDetail: ev.niveauDetail,
      niveauClasse: ev.niveauClasse,
      bienveillance: ev.bienveillance
    })

    root._correctionStderr = ""
    correctionPromptFile.path = ctx.runDir + "/prompt.txt"
    correctionPromptFile.setText(prompt)

    correctionProc.workingDirectory = ctx.runDir
    correctionProc.command = ClaudeRunner.buildFileCommand(prompt)
    correctionProc.running = false
    correctionProc.running = true
  }

  FileView {
    id: correctionPromptFile
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: correctionProc
    stderr: StdioCollector { id: correctionErrOut; waitForEnd: true; onStreamFinished: root._correctionStderr = text }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.finalizeCorrectionError(root._correctionStderr !== "" ? root._correctionStderr.slice(0, 500)
          : ("Claude Code s'est arrêté avec le code " + exitCode + "."))
        return
      }
      root.readCorrectionOutputs()
    }
  }

  property string _correctionAppreciationText: ""

  function readCorrectionOutputs() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    correctionAppreciationReadFile.path = ctx.appreciationPath
  }

  FileView {
    id: correctionAppreciationReadFile
    watchChanges: false
    printErrors: false
    onLoaded: {
      root._correctionAppreciationText = correctionAppreciationReadFile.text()
      var ctx = root._correctionRunContext
      if (ctx) correctionLogReadFile.path = ctx.logPath
    }
    onLoadFailed: root.finalizeCorrectionError("Claude Code n'a pas produit le fichier d'appréciation attendu.")
  }

  property string _correctionLogText: ""

  FileView {
    id: correctionLogReadFile
    watchChanges: false
    printErrors: false
    onLoaded: {
      root._correctionLogText = correctionLogReadFile.text()
      var ctx = root._correctionRunContext
      if (ctx) correctionNotesReadFile.path = ctx.notesPath
    }
    onLoadFailed: {
      root._correctionLogText = ""
      var ctx = root._correctionRunContext
      if (ctx) correctionNotesReadFile.path = ctx.notesPath
    }
  }

  // notes.txt is optional in practice (a missing/unparseable file just
  // leaves all three grades blank via CorrectionPromptBuilder.parseGrades)
  // — never fails the whole correction the way a missing appreciation does.
  FileView {
    id: correctionNotesReadFile
    watchChanges: false
    printErrors: false
    onLoaded: root.finalizeCorrectionSuccess(root._correctionLogText, correctionNotesReadFile.text())
    onLoadFailed: root.finalizeCorrectionSuccess(root._correctionLogText, "")
  }

  function finalizeCorrectionSuccess(logTextRaw, notesTextRaw) {
    var ctx = root._correctionRunContext
    if (!ctx) return
    var appreciation = (root._correctionAppreciationText || "").trim()
    var logTrim = String(logTextRaw || "").trim()
    var grades = CorrectionPromptBuilder.parseGrades(notesTextRaw)
    var lisibilite = CorrectionPromptBuilder.parseLisibilite(notesTextRaw)
    // An illisible copy always needs review, even if the agent's log
    // otherwise says RAS — Gabriel should never rely on an appreciation the
    // agent itself flagged as guesswork.
    var needsReview = (logTrim !== "" && logTrim.toUpperCase() !== "RAS") || lisibilite === "illisible"
    root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, {
      status: "done", appreciation: appreciation,
      log: (logTrim !== "" && logTrim.toUpperCase() !== "RAS") ? logTrim : "", needsReview: needsReview, error: "",
      reviewed: false, // a fresh (or re-run) correction always starts unreviewed
      grades: grades, selectedGrade: "", // fresh grades need a fresh validation
      addendum: "", // one-shot: consumed by the run that just succeeded
      logItemStates: {}, // a fresh log has different items at each index — old per-item triage no longer applies
      lisibilite: lisibilite
    })
    root._correctionRunContext = null
    root.correctionRunningStudentId = ""
    root.processCorrectionQueue()
  }

  function finalizeCorrectionError(message) {
    var ctx = root._correctionRunContext
    if (ctx) root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, { status: "error", error: String(message || "").slice(0, 500) })
    root._correctionRunContext = null
    root.correctionRunningStudentId = ""
    root.processCorrectionQueue()
  }

  function isCorrectionQueued(studentId) {
    for (var i = 0; i < root.correctionQueue.length; i++) if (root.correctionQueue[i].studentId === studentId) return true
    return false
  }

  // ---- row actions: open copy / copy typst code -------------------------

  Process { id: correctionOpenProc }
  function openCorrectionCopy(path) {
    if (!path) return
    correctionOpenProc.command = ["xdg-open", path]
    correctionOpenProc.running = false
    correctionOpenProc.running = true
  }

  property string correctionCopyFeedback: ""
  Process {
    id: correctionCopyProc
    onExited: function(exitCode) {
      root.correctionCopyFeedback = exitCode === 0 ? "Copié !" : "Échec de la copie."
      correctionCopyFeedbackTimer.restart()
    }
  }
  Timer { id: correctionCopyFeedbackTimer; interval: 2000; repeat: false; onTriggered: root.correctionCopyFeedback = "" }
  function copyCorrectionAppreciation(text) {
    if (!text) return
    correctionCopyProc.command = ["wl-copy", text]
    correctionCopyProc.running = false
    correctionCopyProc.running = true
  }

  // ---- log popover --------------------------------------------------------

  property string correctionLogPopoverStudentId: ""
  function openCorrectionLog(studentId) { root.correctionLogPopoverStudentId = studentId }
  function closeCorrectionLog() { root.correctionLogPopoverStudentId = "" }

  function correctionLogEntry() {
    var ev = root.activeEvaluation()
    if (!ev || !root.correctionLogPopoverStudentId) return CorrectionsStore.emptyStudentEntry()
    return CorrectionsStore.studentEntry(ev, root.correctionLogPopoverStudentId)
  }

  function correctionLogStudentLabel() {
    var cls = root.activeClass()
    if (!cls) return ""
    for (var i = 0; i < cls.students.length; i++) {
      if (cls.students[i].id === root.correctionLogPopoverStudentId) return Store.studentLabel(cls.students[i])
    }
    return ""
  }

  // Parsed one-item-per-line view of the currently open student's log —
  // empty for RAS or for an older free-text log written before this
  // format existed (CorrectionLogPopover falls back to the raw text then).
  function correctionLogItems() {
    return CorrectionsStore.parseLogItems(root.correctionLogEntry().log)
  }

  function setCorrectionLogItemState(studentId, index, status, comment) {
    var classId = root.currentCorrectionsClassId()
    var ev = CorrectionsStore.getEvaluation(root.corrections, classId)
    if (!ev) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    var states = {}
    for (var k in entry.logItemStates) states[k] = entry.logItemStates[k]
    states[String(index)] = { status: status, comment: String(comment || "") }
    root.setCorrectionStudentPatch(classId, studentId, { logItemStates: states })
  }

  // ---- reformulation: revise the existing appreciation from log comments,
  // without a full recorrection (Gabriel, 2026-09-18 — "long, lent et
  // inutilement cher"). Only folds in items Gabriel actually commented on;
  // validated/ignored items are left alone.

  property bool correctionReformulating: false
  property var _reformulateContext: null // {classId, studentId, addressedIndexes: [...]}

  function requestReformulateAppreciation(studentId) {
    var ev = root.activeEvaluation()
    var classId = root.currentCorrectionsClassId()
    if (!ev || !classId) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    if (!entry.appreciation) return
    var items = CorrectionsStore.parseLogItems(entry.log)
    var comments = []
    var addressedIndexes = []
    for (var i = 0; i < items.length; i++) {
      var st = entry.logItemStates[String(i)]
      if (st && st.status === "commented" && st.comment) {
        comments.push({ item: items[i], comment: st.comment })
        addressedIndexes.push(i)
      }
    }
    if (comments.length === 0) return
    root._reformulateContext = { classId: classId, studentId: studentId, addressedIndexes: addressedIndexes }
    root.correctionReformulating = true
    var prompt = CorrectionPromptBuilder.buildReformulatePrompt({
      currentAppreciation: entry.appreciation, comments: comments
    })
    reformulateProc.command = ClaudeRunner.buildCommand(prompt)
    reformulateProc.running = false
    reformulateProc.running = true
  }

  Process {
    id: reformulateProc
    stdout: StdioCollector { id: reformulateOut; waitForEnd: true }
    stderr: StdioCollector { id: reformulateErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.correctionReformulating = false
      var ctx = root._reformulateContext
      root._reformulateContext = null
      if (!ctx) return
      if (exitCode !== 0) {
        root.correctionCopyFeedback = (reformulateErr.text || "Échec de la reformulation.").slice(0, 200)
        correctionCopyFeedbackTimer.restart()
        return
      }
      var newText = (reformulateOut.text || "").trim()
      if (!newText) return
      var ev = CorrectionsStore.getEvaluation(root.corrections, ctx.classId)
      var entry = ev ? CorrectionsStore.studentEntry(ev, ctx.studentId) : CorrectionsStore.emptyStudentEntry()
      var states = {}
      for (var k in entry.logItemStates) states[k] = entry.logItemStates[k]
      for (var i = 0; i < ctx.addressedIndexes.length; i++) {
        states[String(ctx.addressedIndexes[i])] = { status: "validated", comment: "" }
      }
      root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, { appreciation: newText, logItemStates: states })
    }
  }

  // Gabriel's own progress marker (see CorrectionsStore.js header comment
  // on the `reviewed` field) — lets a multi-day review session (several
  // flagged copies to re-read) pick up where it left off.
  function toggleCorrectionReviewed(studentId) {
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!ev) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    root.setCorrectionStudentPatch(classId, studentId, { reviewed: !entry.reviewed })
  }

  // Validates one of the agent's three proposed grades for a student —
  // clicking the already-selected one clears the selection instead of
  // re-selecting it (see Gabriel, 2026-09-13: click turns it green).
  function selectCorrectionGrade(studentId, gradeKey) {
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!ev) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    var next = entry.selectedGrade === gradeKey ? "" : gradeKey
    root.setCorrectionStudentPatch(classId, studentId, { selectedGrade: next })
  }

  // ---- log popover actions: hand-edit / one-shot addendum + recorrect ----

  // Bypasses the agent entirely — a fix too small to justify a re-run.
  function saveCorrectionAppreciation(studentId, text) {
    root.setCorrectionStudentPatch(root.currentCorrectionsClassId(), studentId, { appreciation: String(text || "").trim() })
  }

  // Saved without triggering a run, so Gabriel can jot it down now and
  // relaunch later from the row's own "🔁 Recorriger" button.
  function saveCorrectionAddendum(studentId, text) {
    root.setCorrectionStudentPatch(root.currentCorrectionsClassId(), studentId, { addendum: String(text || "").trim() })
  }

  function recorrectWithAddendum(studentId, addendumText) {
    root.saveCorrectionAddendum(studentId, addendumText)
    root.requestCorrectStudent(studentId)
    root.closeCorrectionLog()
  }

  // ---- manuscrit/tapuscrit settings popover -------------------------------
  //
  // Before the évaluation exists, this popover edits the draft fields
  // above; after, it edits the live evaluation directly (evaluation-level
  // fields, distinct from setCorrectionStudentPatch which only ever
  // touches one student's entry).

  property bool correctionWritingPopoverOpen: false
  function openCorrectionWritingSettings() { root.correctionWritingPopoverOpen = true }
  function closeCorrectionWritingSettings() { root.correctionWritingPopoverOpen = false }

  function applyCorrectionWritingSettings(mode, exceptionIds) {
    var ev = root.activeEvaluation()
    if (ev) {
      var classId = root.currentCorrectionsClassId()
      var updated = CorrectionsStore.withWritingSettings(ev, mode, exceptionIds)
      root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
      root.persistCorrections()
    } else {
      root.correctionDraftWritingMode = mode === "tapuscrit" ? "tapuscrit" : "manuscrit"
      root.correctionDraftWritingExceptions = exceptionIds || []
    }
    root.correctionWritingPopoverOpen = false
  }

  // The medium for ONE student's copy: the evaluation's overall mode,
  // flipped if that student is listed as an exception.
  function studentWritingMode(studentId) {
    var ev = root.activeEvaluation()
    if (!ev) return "manuscrit"
    var isException = ev.writingExceptions.indexOf(studentId) !== -1
    if (!isException) return ev.writingMode
    return ev.writingMode === "manuscrit" ? "tapuscrit" : "manuscrit"
  }

  // ---- agent "générer" wizard placeholder ---------------------------------
  // The consignes counterpart (ui/ConsignesWizardPopover.qml + its save
  // plumbing) is retired — consigne.md is now generated automatically at
  // évaluation-creation time, see finishCorrectionCreation()/
  // finalizeCorrectionCreation() above (Gabriel, 2026-09-24). The popover
  // file itself is left on disk, unwired, rather than deleted (this plugin
  // has uncommitted work, so there's no git history to recover it from).

  property bool agentWizardOpen: false

  // ---- final Typst export placeholder (waiting on the sticker-sheet
  // template, same status as addAppreciationToLabelSheet() above) --------

  property string correctionsTypstFeedback: ""
  function generateCorrectionsTypstPage() {
    root.correctionsTypstFeedback = "Bientôt disponible — en attente du gabarit Typst pour les corrections."
    correctionsTypstFeedbackTimer.restart()
  }
  Timer { id: correctionsTypstFeedbackTimer; interval: 2500; repeat: false; onTriggered: root.correctionsTypstFeedback = "" }

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
          || correctionTitleField.activeFocus || correctionFolderField.activeFocus
          || correctionSujetField.activeFocus || correctionCorrigeField.activeFocus
          || correctionAgentField.activeFocus || correctionComplementsField.activeFocus
          || root.classSettingsOpen || root.incompatOpen || root.pathBarMode !== ""
          || root.deleteClassPendingId !== "" || root.resetDrawsConfirmOpen || root.syncSettingsOpen
          || root.agentWizardOpen || root.correctionReplaceConfirmOpen
          || root.correctionConsignesOverwriteConfirmOpen
          || root.filesCheckPopoverOpen
          || root.correctionWritingPopoverOpen
          || root.correctionLogPopoverStudentId !== ""
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
                  { value: "corrections", label: "📝 Corrections" },
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
                  Button {
                    text: "📋 Copier en markdown"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.copyGroupsMarkdown()
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

              // ============================================== corrections

              Column {
                visible: root.activeFeatureTab === "corrections"
                width: parent.width
                spacing: Style.spacing.huge

                // ---- no evaluation yet for this class: creation form ----

                Column {
                  visible: !root.activeEvaluation()
                  width: parent.width
                  spacing: Style.spacing.md

                  Text {
                    text: "Nouvelle évaluation"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Type d'exercice"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Dropdown {
                      width: parent.width
                      options: [{ value: "", label: "— Choisir un type d'exercice —" }].concat(ExerciseTypes.TYPES)
                      value: root.correctionDraftExerciseType
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftExerciseType = v }
                    }
                    Text {
                      visible: root.correctionDraftExerciseType !== "" && !ExerciseTypes.hasTemplate(root.correctionDraftExerciseType)
                      width: parent.width
                      text: "Aucun gabarit de consignes n'est encore rédigé pour ce type d'exercice — les compléments ci-dessous devront porter l'intégralité des attentes."
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Titre du devoir"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: correctionTitleField
                      width: parent.width
                      text: root.correctionDraftTitle
                      placeholderText: "ex. Contrôle chapitre 3"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 160
                      onTextChanged: root.correctionDraftTitle = text
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Dossier du devoir (contiendra les copies des élèves)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: correctionFolderField
                      width: parent.width
                      text: root.correctionDraftFolder
                      placeholderText: "chemin du dossier…"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 2000
                      onTextChanged: root.correctionDraftFolder = text
                    }
                  }

                  Row {
                    spacing: Style.spacing.controlGap

                    Button {
                      text: "✏ Manuscrit / Tapuscrit"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.openCorrectionWritingSettings()
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: (root.correctionDraftWritingMode === "manuscrit" ? "Manuscrit" : "Tapuscrit")
                        + (root.correctionDraftWritingExceptions.length > 0
                          ? (" · " + root.correctionDraftWritingExceptions.length + " exception(s)")
                          : "")
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Sujet (PDF)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: correctionSujetField
                      width: parent.width
                      text: root.correctionDraftSujet
                      placeholderText: "chemin du fichier .pdf…"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 2000
                      onTextChanged: root.correctionDraftSujet = text
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Corrigé (PDF) — facultatif"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: correctionCorrigeField
                      width: parent.width
                      text: root.correctionDraftCorrige
                      placeholderText: "chemin du fichier .pdf…"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 2000
                      onTextChanged: root.correctionDraftCorrige = text
                    }
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.md
                    Text { text: "Paramètres de cette évaluation"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }

                    Dropdown {
                      width: parent.width
                      label: "Nature de l'évaluation"
                      options: ConsignesBuilder.NATURE_OPTIONS
                      value: root.correctionDraftNature
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftNature = v }
                    }

                    Dropdown {
                      width: parent.width
                      label: "Type d'évaluation"
                      options: ConsignesBuilder.TYPE_OPTIONS
                      value: root.correctionDraftType
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftType = v }
                    }

                    NumberField {
                      label: "Durée de l'épreuve (minutes)"
                      value: root.correctionDraftDuree
                      from: 5
                      to: 600
                      stepSize: 5
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onModified: function(v) { root.correctionDraftDuree = v }
                    }

                    Dropdown {
                      width: parent.width
                      label: "Niveau de classe"
                      options: ConsignesBuilder.NIVEAU_CLASSE_OPTIONS
                      value: root.correctionDraftNiveauClasse
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftNiveauClasse = v }
                    }

                    Column {
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Text { text: "Niveau de bienveillance : " + root.correctionDraftBienveillance + "/10"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      PanelSlider {
                        width: parent.width
                        bar: null
                        minimum: 0
                        maximum: 10
                        integer: true
                        value: root.correctionDraftBienveillance
                        onMoved: function(v) { root.correctionDraftBienveillance = v }
                      }
                    }

                    Toggle {
                      width: parent.width
                      label: "Prise de notes acceptée"
                      description: "Sinon, une rédaction complète est exigée."
                      checked: root.correctionDraftPriseDeNotes
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftPriseDeNotes = !root.correctionDraftPriseDeNotes
                    }

                    Toggle {
                      width: parent.width
                      label: "Sujet à traiter intégralement"
                      description: "Coché = une copie incomplète doit être signalée comme telle."
                      checked: root.correctionDraftCompletudeExigee
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftCompletudeExigee = !root.correctionDraftCompletudeExigee
                    }

                    Column {
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Text { text: "Écart sévère / bienveillante : " + root.correctionDraftEcart.toFixed(1) + " pts (neutre = moyenne)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      PanelSlider {
                        width: parent.width
                        bar: null
                        minimum: 0.5
                        maximum: 3
                        step: 0.5
                        value: root.correctionDraftEcart
                        onMoved: function(v) { root.correctionDraftEcart = Math.round(v * 2) / 2 }
                      }
                    }

                    Dropdown {
                      width: parent.width
                      label: "Niveau de surinterprétation"
                      options: ConsignesBuilder.SURINTERPRETATION_OPTIONS
                      value: root.correctionDraftSurinterpretation
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftSurinterpretation = v }
                    }

                    Dropdown {
                      width: parent.width
                      label: "Niveau de détail de l'appréciation"
                      options: ConsignesBuilder.DETAIL_OPTIONS
                      value: root.correctionDraftNiveauDetail
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftNiveauDetail = v }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Compléments propres à cette évaluation"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
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
                          id: correctionComplementsField
                          wrapMode: TextArea.Wrap
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          background: null
                          text: root.correctionDraftComplements
                          placeholderText: "Contexte, niveau, attentes propres à cette évaluation…"
                          onTextChanged: root.correctionDraftComplements = text
                        }
                      }
                    }
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Agent (markdown)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Item {
                      width: parent.width
                      height: Math.max(correctionAgentField.implicitHeight, agentWizardButton.implicitHeight)

                      TextField {
                        id: correctionAgentField
                        anchors.left: parent.left
                        anchors.right: agentWizardButton.left
                        anchors.rightMargin: Style.spacing.controlGap
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.correctionDraftAgent
                        placeholderText: "chemin du fichier .md…"
                        foreground: root.foreground
                        accent: root.accent
                        maximumLength: 2000
                        onTextChanged: root.correctionDraftAgent = text
                      }
                      Button {
                        id: agentWizardButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "🪄 Générer"
                        bordered: true
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.agentWizardOpen = true
                      }
                    }
                  }

                  Text {
                    visible: root.correctionCreateError !== ""
                    width: parent.width
                    text: root.correctionCreateError
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Row {
                    spacing: Style.spacing.controlGap

                    Button {
                      text: root.correctionCreating ? "Vérification…" : "✅ Créer l'évaluation"
                      bordered: true
                      enabled: !root.correctionCreating
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.requestCreateEvaluation()
                    }
                    Button {
                      text: root.filesCheckRunning ? "Vérification en cours…" : "🔍 Vérifier les fichiers (facultatif)"
                      bordered: true
                      enabled: !root.filesCheckRunning
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.requestCheckCorrectionFiles()
                    }
                  }
                }

                // ---- evaluation exists: results table ----

                Column {
                  visible: !!root.activeEvaluation()
                  width: parent.width
                  spacing: Style.spacing.huge

                  Item {
                    width: parent.width
                    height: Math.max(correctionEvalTitle.implicitHeight, correctionHeaderButtons.implicitHeight)

                    Column {
                      id: correctionEvalTitle
                      anchors.left: parent.left
                      anchors.right: correctionHeaderButtons.left
                      anchors.rightMargin: Style.spacing.controlGap
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Text {
                        text: "📝 " + (root.activeEvaluation() ? root.activeEvaluation().title : "")
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        font.bold: true
                        wrapMode: Text.WordWrap
                        width: parent.width
                        textFormat: Text.PlainText
                      }
                      Text {
                        text: root.activeEvaluation() ? root.activeEvaluation().folderPath : ""
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WrapAnywhere
                        width: parent.width
                        textFormat: Text.PlainText
                      }
                      Text {
                        visible: !!root.activeEvaluation()
                        text: root.activeEvaluation()
                          ? ((root.activeEvaluation().writingMode === "manuscrit" ? "Manuscrit" : "Tapuscrit")
                            + (root.activeEvaluation().writingExceptions.length > 0
                              ? (" · " + root.activeEvaluation().writingExceptions.length + " exception(s)")
                              : ""))
                          : ""
                        color: Qt.darker(root.foreground, 1.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                      }
                    }

                    Row {
                      id: correctionHeaderButtons
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.controlGap

                      Button {
                        text: "✏ Manuscrit / Tapuscrit"
                        bordered: true
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.openCorrectionWritingSettings()
                      }
                      Button {
                        text: root.correctionMatching ? "Recherche…" : "🔄 Rattacher les copies"
                        bordered: true
                        enabled: !root.correctionMatching
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.refreshCorrectionCopies()
                      }
                      Button {
                        text: "🆕 Nouvelle évaluation"
                        bordered: true
                        foreground: root.foreground
                        accent: Color.urgent
                        onClicked: root.requestNewEvaluation()
                      }
                    }
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.lg

                    Repeater {
                      model: root.activeClass() ? root.activeClass().students : []
                      delegate: Column {
                        id: correctionRow
                        required property var modelData
                        width: parent.width
                        spacing: Style.spacing.xs

                        readonly property var entry: root.activeEvaluation() ? CorrectionsStore.studentEntry(root.activeEvaluation(), modelData.id) : CorrectionsStore.emptyStudentEntry()
                        readonly property bool queued: root.isCorrectionQueued(modelData.id)
                        readonly property bool isWritingException: root.activeEvaluation() ? root.activeEvaluation().writingExceptions.indexOf(modelData.id) !== -1 : false
                        readonly property color statusColor: entry.status === "error" ? Color.urgent
                          : (entry.status === "done" && entry.needsReview && !entry.reviewed) ? "#c98a3a"
                          : root.accent

                        // Readability dot next to "Copier le code" — the agent's own
                        // self-reported reading-difficulty level for this copy (see
                        // CorrectionPromptBuilder's LISIBILITE step and Gabriel, 2026-09-18).
                        // "" (no signal, ex. a pre-existing correction) shows no dot at all.
                        readonly property color lisibiliteColor: entry.lisibilite === "illisible" ? Color.urgent
                          : entry.lisibilite === "difficile" ? "#c98a3a"
                          : root.gradeValidatedColor
                        readonly property string lisibiliteLabel: entry.lisibilite === "illisible"
                          ? "Copie jugée illisible par l'agent : il a renoncé à surinterpréter, appréciation et notes non fiables — à relire vous-même."
                          : entry.lisibilite === "difficile"
                          ? "Quelques passages ont gêné la lecture de l'agent (graphie ou organisation) — voir le log pour le détail."
                          : "Copie bien lisible pour l'agent, aucun souci de compréhension."

                        Text {
                          text: Store.studentLabel(correctionRow.modelData)
                            + (correctionRow.isWritingException
                              ? ("  ·  " + (root.activeEvaluation().writingMode === "manuscrit" ? "tapuscrit" : "manuscrit") + " (exception)")
                              : "")
                            + (correctionRow.entry.excluded ? "  ·  retiré(e)" : "")
                          color: correctionRow.entry.excluded ? Qt.darker(root.foreground, 1.4)
                            : (correctionRow.entry.copyPath === "" ? Color.urgent : root.foreground)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: parent.width
                          text: correctionRow.entry.excluded ? "Retiré(e) de la correction."
                            : correctionRow.entry.status === "running" ? "Correction en cours…"
                            : correctionRow.entry.status === "error" ? ("Échec : " + correctionRow.entry.error)
                            : correctionRow.entry.appreciation !== "" ? correctionRow.entry.appreciation
                            : correctionRow.entry.copyPath !== "" ? "Copie rattachée, pas encore corrigée."
                            : "Copie non rattachée."
                          color: correctionRow.entry.excluded ? Qt.darker(root.foreground, 1.4) : correctionRow.statusColor
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          wrapMode: Text.WordWrap
                          textFormat: Text.PlainText
                        }

                        ButtonGroup {
                          visible: !correctionRow.entry.excluded && correctionRow.entry.status === "done"
                          width: parent.width
                          options: [
                            { value: "severe", label: "Sévère : " + (correctionRow.entry.grades.severe || "—") },
                            { value: "neutre", label: "Neutre : " + (correctionRow.entry.grades.neutre || "—") },
                            { value: "bienveillante", label: "Bienveillante : " + (correctionRow.entry.grades.bienveillante || "—") }
                          ]
                          value: correctionRow.entry.selectedGrade
                          foreground: root.foreground
                          background: root.background
                          accent: root.gradeValidatedColor
                          fontFamily: root.fontFamily
                          onChanged: function(value) { root.selectCorrectionGrade(correctionRow.modelData.id, value) }
                        }

                        Flow {
                          width: parent.width
                          spacing: Style.spacing.controlGap

                          Button {
                            visible: !correctionRow.entry.excluded
                            text: correctionRow.queued ? "⏳ En file d'attente"
                              : correctionRow.entry.status === "running" ? "⏳ En cours…"
                              : correctionRow.entry.appreciation !== "" ? "🔁 Recorriger"
                              : "🚀 Corriger"
                            bordered: true
                            enabled: correctionRow.entry.copyPath !== "" && correctionRow.entry.status !== "running" && !correctionRow.queued
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.requestCorrectStudent(correctionRow.modelData.id)
                          }
                          Button {
                            visible: !correctionRow.entry.excluded
                            text: "👁 Voir la copie"
                            bordered: true
                            enabled: correctionRow.entry.copyPath !== ""
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.openCorrectionCopy(correctionRow.entry.copyPath)
                          }
                          Row {
                            visible: !correctionRow.entry.excluded
                            spacing: Style.spacing.xs

                            Button {
                              text: "📋 Copier le code"
                              bordered: true
                              enabled: correctionRow.entry.appreciation !== ""
                              foreground: root.foreground
                              accent: root.accent
                              onClicked: root.copyCorrectionAppreciation(correctionRow.entry.appreciation)
                            }

                            Rectangle {
                              visible: correctionRow.entry.lisibilite !== ""
                              anchors.verticalCenter: parent.verticalCenter
                              width: 10
                              height: 10
                              radius: 5
                              color: correctionRow.lisibiliteColor

                              MouseArea {
                                id: lisibiliteDotArea
                                anchors.fill: parent
                                anchors.margins: -4
                                hoverEnabled: true
                              }
                              ToolTip {
                                visible: lisibiliteDotArea.containsMouse
                                text: correctionRow.lisibiliteLabel
                                delay: 300
                              }
                            }
                          }
                          Button {
                            visible: !correctionRow.entry.excluded
                            text: "📄 Log"
                            bordered: true
                            foreground: root.foreground
                            accent: correctionRow.statusColor
                            onClicked: root.openCorrectionLog(correctionRow.modelData.id)
                          }
                          Button {
                            visible: !correctionRow.entry.excluded && correctionRow.entry.status === "done"
                            text: correctionRow.entry.reviewed ? "✔ Vérifié" : "☐ Marquer vérifié"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.toggleCorrectionReviewed(correctionRow.modelData.id)
                          }
                          Button {
                            visible: !correctionRow.entry.excluded && correctionRow.entry.copyPath === ""
                            text: "🚫 Retirer"
                            bordered: true
                            foreground: root.foreground
                            accent: Color.urgent
                            onClicked: root.setCorrectionStudentPatch(root.currentCorrectionsClassId(), correctionRow.modelData.id, { excluded: true })
                          }
                          Button {
                            visible: correctionRow.entry.excluded
                            text: "↩ Réintégrer"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.setCorrectionStudentPatch(root.currentCorrectionsClassId(), correctionRow.modelData.id, { excluded: false })
                          }
                        }
                      }
                    }
                  }

                  Text {
                    visible: root.correctionCopyFeedback !== ""
                    text: root.correctionCopyFeedback
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Row {
                    spacing: Style.spacing.controlGap

                    Button {
                      text: "📄 Générer la page Typst (toutes les corrections)"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Bientôt disponible — en attente du gabarit Typst"
                      onClicked: root.generateCorrectionsTypstPage()
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.correctionsTypstFeedback !== ""
                      text: root.correctionsTypstFeedback
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
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

      WizardPlaceholderPopover {
        anchors.fill: parent
        opened: root.agentWizardOpen
        title: "Assistant — Agent"
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.agentWizardOpen = false
      }

      WritingModePopover {
        anchors.fill: parent
        opened: root.correctionWritingPopoverOpen
        mode: root.activeEvaluation() ? root.activeEvaluation().writingMode : root.correctionDraftWritingMode
        exceptionIds: root.activeEvaluation() ? root.activeEvaluation().writingExceptions : root.correctionDraftWritingExceptions
        students: root.activeClass() ? root.activeClass().students : []
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onApplied: function(mode, exceptionIds) { root.applyCorrectionWritingSettings(mode, exceptionIds) }
        onCanceled: root.closeCorrectionWritingSettings()
      }

      CorrectionLogPopover {
        anchors.fill: parent
        opened: root.correctionLogPopoverStudentId !== ""
        studentLabel: root.correctionLogStudentLabel()
        status: root.correctionLogEntry().status
        log: root.correctionLogEntry().log
        needsReview: root.correctionLogEntry().needsReview
        reviewed: root.correctionLogEntry().reviewed
        error: root.correctionLogEntry().error
        appreciation: root.correctionLogEntry().appreciation
        addendum: root.correctionLogEntry().addendum
        copyPath: root.correctionLogEntry().copyPath
        logItems: root.correctionLogItems()
        logItemStates: root.correctionLogEntry().logItemStates
        reformulating: root.correctionReformulating
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeCorrectionLog()
        onReviewedToggled: root.toggleCorrectionReviewed(root.correctionLogPopoverStudentId)
        onAppreciationSaved: function(text) { root.saveCorrectionAppreciation(root.correctionLogPopoverStudentId, text) }
        onAddendumSaved: function(text) { root.saveCorrectionAddendum(root.correctionLogPopoverStudentId, text) }
        onRecorrectRequested: function(addendumText) { root.recorrectWithAddendum(root.correctionLogPopoverStudentId, addendumText) }
        onLogItemStatusChanged: function(index, status, comment) { root.setCorrectionLogItemState(root.correctionLogPopoverStudentId, index, status, comment) }
        onReformulateRequested: root.requestReformulateAppreciation(root.correctionLogPopoverStudentId)
        onCopyOpenRequested: root.openCorrectionCopy(root.correctionLogEntry().copyPath)
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
        opened: root.correctionReplaceConfirmOpen
        message: "Remplacer l'évaluation en cours pour cette classe par une nouvelle ? Le tableau actuel (copies rattachées, corrections générées) sera définitivement perdu."
        cancelText: "Annuler"
        confirmText: "Remplacer"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelNewEvaluation()
        onConfirmed: root.confirmNewEvaluation()
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.correctionConsignesOverwriteConfirmOpen
        message: "Un fichier consigne.md existe déjà dans ce dossier. L'écraser avec les consignes générées pour cette évaluation ?"
        cancelText: "Annuler"
        confirmText: "Écraser"
        selectedIndex: 0
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelCorrectionConsignesOverwrite()
        onConfirmed: root.finalizeCorrectionCreation()
      }

      FilesCheckPopover {
        anchors.fill: parent
        opened: root.filesCheckPopoverOpen
        running: root.filesCheckRunning
        result: root.filesCheckResult
        error: root.filesCheckError
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeFilesCheckPopover()
      }
    }
  }
}

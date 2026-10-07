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
import "lib/ExerciseTypes.js" as ExerciseTypes
import "lib/ConsignesBuilder.js" as ConsignesBuilder
import "lib/CompetencyGrids.js" as CompetencyGrids
import "lib/Spellcheck.js" as Spellcheck
import "lib/CompetencyPromptBuilder.js" as CompetencyPromptBuilder
import "lib/CorrectionAssistantPromptBuilder.js" as CorrectionAssistantPromptBuilder
import "lib/EvalTemplatesStore.js" as EvalTemplatesStore
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
  // Saved évaluation-creation presets (Gabriel, 2026-10-03) — see
  // lib/EvalTemplatesStore.js's header comment for why this is its own file,
  // synced the same way as classes.json rather than left inside
  // corrections.json.
  readonly property string evalTemplatesPath: root.stateDir + "/eval_templates.json"

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

  // ---- persisted: évaluation-creation templates ("modèles") --------------

  property var evalTemplates: []

  FileView {
    id: evalTemplatesFile
    path: root.evalTemplatesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.evalTemplates = EvalTemplatesStore.parseTemplates(evalTemplatesFile.text())
    onLoadFailed: root.evalTemplates = []
  }

  function persistEvalTemplates() {
    evalTemplatesFile.setText(EvalTemplatesStore.serializeTemplates(root.evalTemplates))
  }

  // ---- persisted: settings (last active class tab + sync folder) ----------

  property string activeClassId: ""
  property string syncDir: "" // "" = sync disabled
  // Panel-wide UI zoom (Gabriel, 2026-10-02) — same idea as GH Typst's
  // editor zoom, but scales the whole panel's content, not one editor
  // pane; for when he wants bigger text/controls without touching the
  // whole desktop's scale. See setUiZoom() and the zoomWrapper Item below.
  property real uiZoom: 1.0
  // agent.md's path — global now, set once here rather than re-pointed at
  // for every évaluation (Gabriel, 2026-10-03). Local-only, like syncDir:
  // never synced (it's a filesystem path, meaningless on another machine).
  property string agentPath: ""

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
      root.uiZoom = s.uiZoom
      root.agentPath = s.agentPath
      root.seedDefaultAgentPathIfEmpty()
    }
    onLoadFailed: {
      root.activeClassId = ""; root.syncDir = ""; root.uiZoom = 1.0; root.agentPath = ""
      root.seedDefaultAgentPathIfEmpty()
    }
  }

  // First run after agent.md became a global setting (Gabriel, 2026-10-03,
  // "tu peux importer mon agent.md... comme modèle pour moi") — seeds it
  // from the copy imported into stateDir once, rather than leaving the
  // field empty until he repoints it by hand. Only ever fires once: it
  // persists immediately, so agentPath is non-empty on every later load.
  function seedDefaultAgentPathIfEmpty() {
    if (root.agentPath !== "") return
    root.agentPath = root.stateDir + "/agent.md"
    root.persistSettings()
  }

  function persistSettings() {
    settingsFile.setText(Store.serializeSettings({ activeClassId: root.activeClassId, syncDir: root.syncDir, uiZoom: root.uiZoom, agentPath: root.agentPath }))
  }

  function setAgentPath(path) {
    var clean = root.expandHome(path).slice(0, 1024)
    if (clean === root.agentPath) return
    root.agentPath = clean
    root.persistSettings()
  }

  function setUiZoom(zoom) {
    root.uiZoom = Math.max(0.6, Math.min(2.5, Math.round(zoom * 10) / 10))
    root.persistSettings()
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
    // classes.json done → chain into eval_templates.json rather than
    // clearing syncInFlight here (see runTemplatesSync() below) — one
    // "sync" action now covers both files.
    onSaved: root.runTemplatesSync()
  }

  // ---- eval_templates.json sync — plain union by id (see
  // EvalTemplatesStore.mergeTemplates()'s own header comment for why this
  // is simpler than classes.json's reconciliation) — chained after classes
  // sync above, same ensured directory, same syncInFlight flag.

  function runTemplatesSync() {
    var cmd = Files.readCommand(root._syncPendingDir, "eval_templates.json", 4194304, 5)
    if (!cmd) { syncInFlightTimeout.stop(); root.syncInFlight = false; return }
    syncTemplatesReadProc.command = cmd
    syncTemplatesReadProc.running = false
    syncTemplatesReadProc.running = true
  }

  Process {
    id: syncTemplatesReadProc
    stdout: StdioCollector { id: syncTemplatesReadOut; waitForEnd: true }
    onExited: function(exitCode) {
      var remoteTemplates = EvalTemplatesStore.parseTemplates(syncTemplatesReadOut.text || "[]")
      var merged = EvalTemplatesStore.mergeTemplates(root.evalTemplates, remoteTemplates)
      root.evalTemplates = merged
      root.persistEvalTemplates()
      syncTemplatesWriteFile.path = root._syncPendingDir + "/eval_templates.json"
      Qt.callLater(function() { syncTemplatesWriteFile.setText(EvalTemplatesStore.serializeTemplates(merged)) })
    }
  }

  FileView {
    id: syncTemplatesWriteFile
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
    root.resetCorrectionDraft()
    root.evaluationStudentId = ""
    root.evalCopyFeedback = ""
    root.evalPdfExportedPath = ""
    root.evalPdfExportError = ""
    root.loadEvaluationFields()
  }

  property string activeFeatureTab: "tirage" // tirage | groupes | appreciations | corrections | evaluation | assistant | exercices

  // Every feature tab lives in the same ScrollView (siblings toggled by
  // `visible`), so they share one contentY. Leaving a long tab scrolled
  // far down (Corrections) for a shorter one kept that contentY — the
  // Flickable never clamps it when contentHeight shrinks — so the viewport
  // sat below the new content and the panel looked empty until scrolled
  // back up. Intermittent because it depends on how far down you were.
  // Fix: start every tab/class at the top, and clamp on any shrink
  // (zoom, collapsing sections, cleared results...).
  onActiveFeatureTabChanged: root.scrollPanelToTop()
  onActiveClassIdChanged: root.scrollPanelToTop()

  function scrollPanelToTop() {
    if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
  }

  function clampPanelScroll() {
    var f = scrollArea ? scrollArea.contentItem : null
    if (!f) return
    var maxY = Math.max(0, f.contentHeight - f.height)
    if (f.contentY > maxY) f.contentY = maxY
  }

  Connections {
    target: scrollArea ? scrollArea.contentItem : null
    function onContentHeightChanged() { root.clampPanelScroll() }
    function onHeightChanged() { root.clampPanelScroll() }
  }

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
        competencyIntitules: {},
        competencyWeights: {},
        competencyBaremeTotal: {}
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
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
      // Bug found 2026-10-01: this used to omit competencyGrids/
      // competencyClearedAt entirely, silently wiping every student's
      // "Eval. Compétences" answers on a plain tirage reset — an unrelated
      // feature. Preserved explicitly now, same as every other field here.
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: 0, drawHistory: [], competencyGrids: s.competencyGrids, competencyClearedAt: s.competencyClearedAt }
    })
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: resetStudents, incompatibilities: cls.incompatibilities, lastResetAt: new Date().toISOString(), competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
    else if (mode === "exportCompetencyPdf") root.startCompetencyPdfExport(path)
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
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities.concat([ids]), lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
    root.classes = Store.replaceClass(root.classes, updated)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  function removeIncompatibilitySet(index) {
    var cls = root.activeClass()
    if (!cls) return
    var list = cls.incompatibilities.slice()
    list.splice(index, 1)
    var updated = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: list, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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

  // Gabriel, 2026-10-03: "j'ai oublié de cocher court" — niveauDetail used
  // to be set once at creation with no way back short of recreating the
  // whole évaluation. Patches the live évaluation AND regenerates
  // consigne.md from its own stored fields (ConsignesBuilder.build(), same
  // call as at creation) — leaving the old text there would silently
  // contradict the fresh instruction CorrectionPromptBuilder.build() sends
  // directly for the next copy corrected, exactly the kind of inconsistency
  // this whole feature set has been trying to avoid. Circuit A (gridId set)
  // never reads niveauDetail/consigne.md at all — not offered there.
  function setEvaluationNiveauDetail(niveauDetail) {
    var classId = root.currentCorrectionsClassId()
    var ev = CorrectionsStore.getEvaluation(root.corrections, classId)
    if (!ev || ev.gridId || ev.niveauDetail === niveauDetail) return
    var updated = {}
    for (var k in ev) updated[k] = ev[k]
    updated.niveauDetail = niveauDetail
    root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
    root.persistCorrections()
    var consignesText = ConsignesBuilder.build({
      exerciseType: updated.exerciseType, natureEvaluation: updated.natureEvaluation, typeEvaluation: updated.typeEvaluation,
      dureeEpreuve: updated.dureeEpreuve, niveauClasse: updated.niveauClasse, bienveillance: updated.bienveillance,
      priseDeNotes: updated.priseDeNotes, completudeExigee: updated.completudeExigee,
      surinterpretation: updated.surinterpretation, niveauDetail: updated.niveauDetail,
      complements: updated.complements, notee: updated.notee, bareme: updated.bareme
    })
    correctionConsignesSaveFile.path = updated.consignesPath
    correctionConsignesSaveFile.setText(consignesText)
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
  // Sujet/corrigé are no longer typed in — Gabriel, 2026-10-03: "sujet.pdf"
  // et "corrigé.pdf" doivent toujours être rangés sous ces noms exacts dans
  // le dossier du devoir ci-dessous, pour une bricole de moins. Derived in
  // requestCreateEvaluation() (sujet mandatory, corrigé only if the file
  // actually exists there — see correctionCorrigeCheckProc).
  property string correctionDraftFolder: ""
  property string correctionDraftExerciseType: ""
  // Which CompetencyGrids.GRIDS entry this évaluation will use — "" means
  // the older free-form single-shot pipeline (CorrectionPromptBuilder),
  // any other value switches this évaluation to the grid-first pipeline
  // (CompetencyPromptBuilder) for every student in it. See Gabriel,
  // 2026-09-27 — [[gh-corrections-plugin]].
  property string correctionDraftGridId: ""
  // { "<rowIndex>": points (0-10) } — distributed via the "⚖️ Répartir les
  // points" popover, only meaningful when correctionDraftGridId is set.
  property var correctionDraftWeights: ({})
  property bool correctionDraftWeightsPopoverOpen: false
  function openDraftWeightsPopover() { root.correctionDraftWeightsPopoverOpen = true }
  function closeDraftWeightsPopover() { root.correctionDraftWeightsPopoverOpen = false }
  function setDraftWeight(rowIndex, points) {
    var w = {}
    for (var k in root.correctionDraftWeights) w[k] = root.correctionDraftWeights[k]
    w[String(rowIndex)] = Math.max(0, Math.min(20, points))
    root.correctionDraftWeights = w
  }
  property string correctionDraftNature: "tp_individuel"
  property string correctionDraftType: "formative"
  property int correctionDraftDuree: 60
  property string correctionDraftNiveauClasse: "1ere"
  property int correctionDraftBienveillance: 5
  property bool correctionDraftPriseDeNotes: false
  property bool correctionDraftCompletudeExigee: true
  property string correctionDraftSurinterpretation: "neutre"
  property string correctionDraftNiveauDetail: "moyen"
  property string correctionDraftComplements: ""
  // Which appreciation paragraphs CorrectionPromptBuilder.build() imposes —
  // see applyStructureDefaultsForType() for the per-exerciseType precoche.
  // Each has its own list of critères précis instead of a single free-text
  // consigne (Gabriel, 2026-10-03 — "j'ai envie de faire une liste de
  // compétences", peu de place dans un champ texte unique): [{ id, text }].
  property bool correctionDraftStructMethode: false
  property bool correctionDraftStructContenu: true
  property bool correctionDraftStructLangue: true
  property var correctionDraftMethodeCriteres: []
  property var correctionDraftContenuCriteres: []
  property var correctionDraftLangueCriteres: []
  // { "<critère id>": points out of 20 } — only shown/meaningful when
  // correctionDraftNotee is true; see CorrectionPromptBuilder.build()'s
  // weightedCriteres and Panel.qml's finalizeCorrectionSuccess().
  property var correctionDraftCriteriaPoints: ({})
  property bool correctionDraftNotee: true
  property string correctionDraftBareme: ""
  property string correctionDraftWritingMode: "manuscrit"
  property var correctionDraftWritingExceptions: []
  property string correctionCreateError: ""
  property bool correctionCreating: false
  property var _pendingCorrectionDraft: null
  property var _correctionValidateQueue: []

  function resetCorrectionDraft() {
    root.correctionDraftTitle = ""
    root.correctionDraftFolder = ""
    root.correctionDraftExerciseType = ""
    root.correctionDraftGridId = ""
    root.correctionDraftWeights = {}
    root.correctionDraftNature = "tp_individuel"
    root.correctionDraftType = "formative"
    root.correctionDraftDuree = 60
    root.correctionDraftNiveauClasse = "1ere"
    root.correctionDraftBienveillance = 5
    root.correctionDraftPriseDeNotes = false
    root.correctionDraftCompletudeExigee = true
    root.correctionDraftSurinterpretation = "neutre"
    root.correctionDraftNiveauDetail = "moyen"
    root.correctionDraftComplements = ""
    root.correctionDraftStructMethode = false
    root.correctionDraftStructContenu = true
    root.correctionDraftStructLangue = true
    root.correctionDraftMethodeCriteres = []
    root.correctionDraftContenuCriteres = []
    root.correctionDraftLangueCriteres = []
    root.correctionDraftCriteriaPoints = {}
    root.correctionDraftNotee = true
    root.correctionDraftBareme = ""
    root.correctionDraftWritingMode = "manuscrit"
    root.correctionDraftWritingExceptions = []
    root.correctionCreateError = ""
    root.correctionCreating = false
  }

  // ---- évaluation-creation wizard: critère lists (Méthode/Contenu/Langue) --
  // Gabriel, 2026-10-03: same add/remove-by-id shape as GH Grilles' own rows,
  // kept inline here rather than importing that plugin's TableGen/RowsList —
  // no tags/sections needed, just a flat list of short critère texts per
  // paragraph.

  function critereListFor(category) {
    if (category === "methode") return root.correctionDraftMethodeCriteres
    if (category === "contenu") return root.correctionDraftContenuCriteres
    return root.correctionDraftLangueCriteres
  }
  function setCritereListFor(category, list) {
    if (category === "methode") root.correctionDraftMethodeCriteres = list
    else if (category === "contenu") root.correctionDraftContenuCriteres = list
    else root.correctionDraftLangueCriteres = list
  }
  function addCritere(category, text) {
    var t = String(text || "").trim()
    if (!t) return
    root.setCritereListFor(category, root.critereListFor(category).concat([{ id: Store.makeId(), text: t }]))
  }
  function removeCritere(category, id) {
    root.setCritereListFor(category, root.critereListFor(category).filter(function(c) { return c.id !== id }))
    var points = {}
    for (var k in root.correctionDraftCriteriaPoints) if (k !== id) points[k] = root.correctionDraftCriteriaPoints[k]
    root.correctionDraftCriteriaPoints = points
  }
  function setCriterionPoints(id, points) {
    var map = {}
    for (var k in root.correctionDraftCriteriaPoints) map[k] = root.correctionDraftCriteriaPoints[k]
    // Whole points only — NumberField (the shared Ui widget behind this
    // field) is strictly int-typed (value/from/to/stepSize), no half-point
    // support, see Gabriel's 2026-10-03 crash report.
    map[id] = Math.round(Math.max(0, Math.min(20, points)))
    root.correctionDraftCriteriaPoints = map
  }

  // ---- évaluation-creation wizard: save/load as a reusable "modèle" -------
  // Gabriel, 2026-10-03: il enseigne 2 classes de 2nde + 3 de 1ère, et fait
  // souvent tourner le même petit exercice sur plusieurs d'entre elles — un
  // modèle évite de tout retaper à chaque classe. Ne capture QUE les champs
  // du wizard ci-dessus (voir EvalTemplatesStore.js) — jamais folder/sujet/
  // corrigé/agent, toujours propres à cette classe-ci et ce passage-ci.

  property string evalTemplateSaveName: ""

  function requestSaveEvalTemplate() {
    var t = EvalTemplatesStore.sanitizeTemplate({
      name: root.evalTemplateSaveName,
      exerciseType: root.correctionDraftExerciseType,
      gridId: root.correctionDraftGridId,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      structMethode: root.correctionDraftStructMethode,
      structContenu: root.correctionDraftStructContenu,
      structLangue: root.correctionDraftStructLangue,
      methodeCriteres: root.correctionDraftMethodeCriteres,
      contenuCriteres: root.correctionDraftContenuCriteres,
      langueCriteres: root.correctionDraftLangueCriteres,
      criteriaPoints: root.correctionDraftCriteriaPoints,
      notee: root.correctionDraftNotee,
      bareme: root.correctionDraftBareme
    })
    if (!t) return
    root.evalTemplates = root.evalTemplates.concat([t])
    root.persistEvalTemplates()
    root.evalTemplateSaveName = ""
    if (root.syncDir) root.runSync()
  }

  function applyEvalTemplate(id) {
    var t = EvalTemplatesStore.findTemplate(root.evalTemplates, id)
    if (!t) return
    root.correctionDraftExerciseType = t.exerciseType
    root.correctionDraftGridId = t.gridId
    root.correctionDraftNature = t.natureEvaluation
    root.correctionDraftType = t.typeEvaluation
    root.correctionDraftDuree = t.dureeEpreuve
    root.correctionDraftNiveauClasse = t.niveauClasse
    root.correctionDraftBienveillance = t.bienveillance
    root.correctionDraftPriseDeNotes = t.priseDeNotes
    root.correctionDraftCompletudeExigee = t.completudeExigee
    root.correctionDraftSurinterpretation = t.surinterpretation
    root.correctionDraftNiveauDetail = t.niveauDetail
    root.correctionDraftStructMethode = t.structMethode
    root.correctionDraftStructContenu = t.structContenu
    root.correctionDraftStructLangue = t.structLangue
    root.correctionDraftMethodeCriteres = t.methodeCriteres
    root.correctionDraftContenuCriteres = t.contenuCriteres
    root.correctionDraftLangueCriteres = t.langueCriteres
    root.correctionDraftCriteriaPoints = t.criteriaPoints
    root.correctionDraftNotee = t.notee
    root.correctionDraftBareme = t.bareme
  }

  // Precoche la case "Méthode" seulement pour les types organisés en
  // axes/sous-parties (voir ExerciseTypes.usesPlanExtraction) — pour les
  // autres (questionnaire de lecture, contraction...), ce paragraphe n'a
  // rien d'organique à décrire. Contenu/Langue restent cochées dans tous
  // les cas : l'agent les remplit bien même sans consigne dédiée. Appelé au
  // choix du type d'exercice — écrase tout cochage manuel déjà fait, comme
  // un changement de type recommence le formulaire.
  function applyStructureDefaultsForType(exerciseType) {
    root.correctionDraftStructMethode = ExerciseTypes.usesPlanExtraction(exerciseType)
    root.correctionDraftStructContenu = true
    root.correctionDraftStructLangue = true
  }

  // ---- flatten the 3 critère lists (for notation + prompt building) -------
  // Fixed order (Méthode, puis Contenu, puis Langue), same order the prompt
  // lists them in — see CorrectionPromptBuilder.build(). weightsSource lets
  // callers pass either the live draft's points map or a persisted
  // évaluation's own criteriaPoints.
  function flattenCriteres(structMethode, methodeCriteres, structContenu, contenuCriteres, structLangue, langueCriteres) {
    var out = []
    if (structMethode) (methodeCriteres || []).forEach(function(c) { out.push({ label: "Méthode", id: c.id, text: c.text }) })
    if (structContenu !== false) (contenuCriteres || []).forEach(function(c) { out.push({ label: "Contenu", id: c.id, text: c.text }) })
    if (structLangue !== false) (langueCriteres || []).forEach(function(c) { out.push({ label: "Expression écrite", id: c.id, text: c.text }) })
    return out
  }

  function weightedCriteresFrom(flat, weightsSource) {
    var w = weightsSource || {}
    return flat.filter(function(c) { return Number(w[c.id] || 0) > 0 })
  }

  property string _correctionCorrigeCandidate: ""

  function requestCreateEvaluation() {
    var classId = root.currentCorrectionsClassId()
    var cls = root.activeClass()
    if (!classId || !cls) { root.correctionCreateError = "Sélectionnez une classe."; return }
    var title = String(root.correctionDraftTitle || "").trim().slice(0, CorrectionsStore.MAX_TITLE_LEN)
    var folder = root.expandHome(root.correctionDraftFolder).replace(/\/+$/, "")
    var usesGrid = root.correctionDraftGridId !== ""
    // Type d'exercice/surinterprétation/niveau de détail only feed
    // consigne.md, which the grid-first pipeline never reads (see Gabriel,
    // 2026-09-27) — not required, and consigne.md isn't generated at all,
    // when a grid is selected.
    if (!usesGrid && !root.correctionDraftExerciseType) { root.correctionCreateError = "Choisissez un type d'exercice."; return }
    if (!title) { root.correctionCreateError = "Donnez un titre au devoir."; return }
    if (!folder) { root.correctionCreateError = "Indiquez le dossier du devoir."; return }
    if (!root.agentPath) {
      root.correctionCreateError = "Indiquez le fichier agent.md par défaut via le bouton \"🔄 Synchro\" (en haut du panneau)."
      return
    }
    // sujet.pdf/corrigé.pdf doivent être rangés sous ces noms exacts dans le
    // dossier du devoir (Gabriel, 2026-10-03) — plus de champs à remplir à
    // la main. Sujet est obligatoire ; corrigé reste facultatif (ex. une
    // fiche de lecture où chaque élève a lu un livre différent) — son
    // existence est testée juste après, sans faire échouer la création s'il
    // est absent.
    var sujet = folder + "/sujet.pdf"
    var agent = root.expandHome(root.agentPath)
    var consignesText = usesGrid ? "" : ConsignesBuilder.build({
      exerciseType: root.correctionDraftExerciseType,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      complements: root.correctionDraftComplements,
      notee: root.correctionDraftNotee,
      bareme: root.correctionDraftBareme
    })
    root._pendingCorrectionDraft = {
      classId: classId, title: title, folder: folder,
      sujet: sujet, corrige: "", agent: agent,
      consignesPath: folder + "/consigne.md", consignesText: consignesText,
      exerciseType: root.correctionDraftExerciseType,
      gridId: root.correctionDraftGridId,
      criteriaWeights: root.correctionDraftWeights,
      natureEvaluation: root.correctionDraftNature,
      typeEvaluation: root.correctionDraftType,
      dureeEpreuve: root.correctionDraftDuree,
      niveauClasse: root.correctionDraftNiveauClasse,
      bienveillance: root.correctionDraftBienveillance,
      priseDeNotes: root.correctionDraftPriseDeNotes,
      completudeExigee: root.correctionDraftCompletudeExigee,
      surinterpretation: root.correctionDraftSurinterpretation,
      niveauDetail: root.correctionDraftNiveauDetail,
      complements: root.correctionDraftComplements,
      structMethode: root.correctionDraftStructMethode,
      structContenu: root.correctionDraftStructContenu,
      structLangue: root.correctionDraftStructLangue,
      methodeCriteres: root.correctionDraftMethodeCriteres,
      contenuCriteres: root.correctionDraftContenuCriteres,
      langueCriteres: root.correctionDraftLangueCriteres,
      criteriaPoints: root.correctionDraftCriteriaPoints,
      notee: root.correctionDraftNotee,
      bareme: root.correctionDraftBareme,
      writingMode: root.correctionDraftWritingMode, writingExceptions: root.correctionDraftWritingExceptions
    }
    root.correctionCreating = true
    root.correctionCreateError = ""
    root._correctionCorrigeCandidate = folder + "/corrigé.pdf"
    correctionCorrigeCheckProc.command = ["test", "-f", root._correctionCorrigeCandidate]
    correctionCorrigeCheckProc.running = false
    correctionCorrigeCheckProc.running = true
  }

  // corrigé.pdf's existence is checked on its own, outside the mandatory
  // queue below: unlike dossier/sujet/agent, its ABSENCE isn't an error —
  // see requestCreateEvaluation().
  Process {
    id: correctionCorrigeCheckProc
    onExited: function(exitCode) {
      if (!root._pendingCorrectionDraft) return
      if (exitCode === 0) root._pendingCorrectionDraft.corrige = root._correctionCorrigeCandidate
      // Each path is checked with its own plain `test` invocation (argv
      // only, no shell) — chained one at a time rather than combined into a
      // single script string. consigne.md itself isn't checked here: it
      // doesn't exist yet (see finishCorrectionCreation() below, which checks
      // for a pre-existing file at that generated path before writing it).
      root._correctionValidateQueue = [
        { flag: "-d", path: root._pendingCorrectionDraft.folder },
        { flag: "-f", path: root._pendingCorrectionDraft.sujet },
        { flag: "-f", path: root._pendingCorrectionDraft.agent }
      ]
      root.runNextCorrectionValidation()
    }
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
        root.correctionCreateError = "Chemin(s) introuvable(s) — vérifiez le dossier du devoir (doit contenir sujet.pdf), et le fichier agent.md configuré dans les réglages."
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
    // Grid-first évaluations never write consigne.md at all — skip the
    // existence check/overwrite dance entirely (Gabriel, 2026-09-27).
    if (d.gridId) { root.finalizeCorrectionCreation(); return }
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
    if (!d.gridId) {
      correctionConsignesSaveFile.path = d.consignesPath
      correctionConsignesSaveFile.setText(d.consignesText)
    }
    var studentIds = cls.students.map(function(s) { return s.id })
    var evaluation = CorrectionsStore.createEvaluation({
      title: d.title, folderPath: d.folder, sujetPath: d.sujet,
      corrigePath: d.corrige, consignesPath: d.consignesPath, agentPath: d.agent,
      studentIds: studentIds,
      writingMode: d.writingMode, writingExceptions: d.writingExceptions,
      exerciseType: d.exerciseType,
      gridId: d.gridId,
      criteriaWeights: d.criteriaWeights,
      natureEvaluation: d.natureEvaluation, typeEvaluation: d.typeEvaluation,
      dureeEpreuve: d.dureeEpreuve, niveauClasse: d.niveauClasse,
      bienveillance: d.bienveillance, priseDeNotes: d.priseDeNotes,
      completudeExigee: d.completudeExigee,
      surinterpretation: d.surinterpretation, niveauDetail: d.niveauDetail,
      complements: d.complements,
      structMethode: d.structMethode, structContenu: d.structContenu, structLangue: d.structLangue,
      methodeCriteres: d.methodeCriteres, contenuCriteres: d.contenuCriteres, langueCriteres: d.langueCriteres,
      criteriaPoints: d.criteriaPoints,
      notee: d.notee, bareme: d.bareme
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
      var ctx = root._correctionRunContext
      var ev = ctx ? CorrectionsStore.getEvaluation(root.corrections, ctx.classId) : null
      // gridId set → this évaluation uses the grid-first pipeline
      // (CompetencyPromptBuilder) instead of the older single-shot one —
      // see Gabriel, 2026-09-27, [[gh-corrections-plugin]].
      if (ev && ev.gridId) {
        root.startCompetencyGridFill()
      } else {
        root.startCorrectionClaude()
      }
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
      bienveillance: ev.bienveillance,
      structMethode: ev.structMethode,
      structContenu: ev.structContenu,
      structLangue: ev.structLangue,
      methodeCriteres: ev.methodeCriteres,
      contenuCriteres: ev.contenuCriteres,
      langueCriteres: ev.langueCriteres,
      notee: ev.notee,
      weightedCriteres: root.weightedCriteresFrom(
        root.flattenCriteres(ev.structMethode, ev.methodeCriteres, ev.structContenu, ev.contenuCriteres, ev.structLangue, ev.langueCriteres),
        ev.criteriaPoints)
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
    var ev = CorrectionsStore.getEvaluation(root.corrections, ctx.classId)
    var appreciation = (root._correctionAppreciationText || "").trim()
    var logTrim = String(logTextRaw || "").trim()
    var lisibilite = CorrectionPromptBuilder.parseLisibilite(notesTextRaw)
    // Weighted critères (Gabriel, 2026-10-03) → a deterministic note from
    // palier × points (CompetencyGrids.computeWeightedNote(), same function
    // the grid-first pipeline already uses — never the agent's own
    // arithmetic for a real grade), carried identically by all three named
    // grades so the rest of this function/the review UI doesn't need to
    // change shape. No weighted critère → the older free severe/neutre/
    // bienveillante proposal, unchanged.
    var weighted = ev ? root.weightedCriteresFrom(
      root.flattenCriteres(ev.structMethode, ev.methodeCriteres, ev.structContenu, ev.contenuCriteres, ev.structLangue, ev.langueCriteres),
      ev.criteriaPoints) : []
    var grades
    // Paliers attribués (Gabriel, 2026-10-03: "il faudrait qu'il indique
    // quel palier il a attribué à chacun des critères") — built from the
    // SAME parsed `checks` the note was computed from, never a second,
    // independent self-report by the agent: the log must always match
    // exactly what the note was actually calculated from.
    var palierLog = ""
    if (weighted.length > 0) {
      var checks = CorrectionPromptBuilder.parseCriteriaPaliers(notesTextRaw, weighted)
      var weights = {}
      weighted.forEach(function(c, idx) { weights[idx] = Number((ev.criteriaPoints || {})[c.id] || 0) })
      var pseudoGrid = { rows: weighted.map(function(c) { return { checkable: true, text: c.text } }) }
      var computed = CompetencyGrids.computeWeightedNote(pseudoGrid, checks, weights)
      grades = { severe: computed.severe, neutre: computed.severe, bienveillante: computed.bienveillante }
      var palierLines = ["## Paliers attribués"]
      weighted.forEach(function(c, idx) {
        var level = checks[idx]
        var label = (level === undefined || level === null) ? "non évalué" : ("Palier " + (level + 1) + "/4")
        palierLines.push("- [" + c.label + "] " + c.text + " : " + label)
      })
      palierLog = palierLines.join("\n")
    } else {
      grades = CorrectionPromptBuilder.parseGrades(notesTextRaw)
    }
    // An illisible copy always needs review, even if the agent's log
    // otherwise says RAS — Gabriel should never rely on an appreciation the
    // agent itself flagged as guesswork. The paliers breakdown is routine
    // info, not a vigilance signal — it's folded into the displayed log
    // text below but deliberately left OUT of needsReview, unlike the
    // "Plan restitué" section which does count (usesPlanExtraction, see
    // CorrectionPromptBuilder.build()).
    var vigilanceLog = (logTrim !== "" && logTrim.toUpperCase() !== "RAS") ? logTrim : ""
    var needsReview = vigilanceLog !== "" || lisibilite === "illisible"
    var displayedLog = palierLog ? (palierLog + (vigilanceLog ? "\n\n" + vigilanceLog : "")) : vigilanceLog
    root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, {
      status: "done", appreciation: appreciation,
      log: displayedLog, needsReview: needsReview, error: "",
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
    root._competencyGrid = null
    root.correctionRunningStudentId = ""
    root.processCorrectionQueue()
  }

  // Gabriel, 2026-09-27: launching a batch of corrections had no way to
  // stop it short of killing the underlying `claude` process by hand
  // outside the app — this button-facing function does the same thing the
  // supported way. `Process.running = false` is this codebase's own
  // established "stop it" idiom (already used everywhere else to reset a
  // Process before reusing it for a new command) — setting it on all the
  // pipeline's Process elements is safe even for the ones currently idle.
  // Unlike finalizeCorrectionError(), this ALSO empties the queue: a
  // correction Gabriel stopped on purpose must not silently cascade into
  // the next one, which is exactly what bit him here (killing one process
  // by hand just let the next queued copy start automatically).
  function cancelCorrectionRun() {
    correctionMkdirProc.running = false
    correctionAnonymizeCopyProc.running = false
    correctionProc.running = false
    competencyFillProc.running = false
    competencyAppreciationProc.running = false
    var ctx = root._correctionRunContext
    if (ctx) root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, { status: "error", error: "Correction annulée." })
    root._correctionRunContext = null
    root._competencyGrid = null
    root.correctionRunningStudentId = ""
    root.correctionQueue = []
  }

  // ---- grid-first pipeline (Gabriel, 2026-09-27) -------------------------
  //
  // Two chained headless calls, reusing the SAME queue/mkdir/anonymize
  // context as the older single-shot pipeline above (branched at
  // correctionAnonymizeCopyProc.onExited): (1) read the copy and fill the
  // évaluation's competency grid — read-only (ClaudeRunner.buildCheckCommand,
  // same --allowedTools Read mechanism already used by "Vérifier les
  // fichiers" below), answers captured on stdout, nothing written to disk;
  // (2) generate the appreciation FROM that filled grid, reusing
  // PromptBuilder.buildEvalAppreciationPrompt verbatim — the Eval.
  // Compétences tab's own, already-validated prompt. The note itself is
  // NOT a third agent call — see CompetencyGrids.computeWeightedNote(), a
  // plain deterministic calculation from the grid + Gabriel's own weights,
  // computed synchronously wherever it's needed instead. See
  // [[gh-corrections-plugin]] for why the fill/write split tested more
  // reliably than the older single-shot prompt.
  property var _competencyGrid: null
  property var _competencyChecks: ({})
  property var _competencyJustifications: ({})
  property string _competencyLog: ""
  property string _competencyAppreciation: ""
  // true when startCompetencyAppreciation() was triggered by "Régénérer
  // l'appréciation" rather than a full grid-fill run — the finalize step
  // then leaves the note (and the grid/log) untouched, only overwriting
  // appreciation. See Gabriel, 2026-09-27: he wants the two regenerations
  // fully independent (agreeing with the note but not the appreciation,
  // or vice versa, must be possible).
  property bool _competencyAppreciationOnly: false
  // One-shot free text Gabriel can attach before regenerating the
  // appreciation only (ex. "l'axe II, bien que complet, est bâclé") —
  // reuses StudentCorrection.addendum, same one-shot/consumed-after-use
  // semantics as the older pipeline's addendum. Empty for a full run.
  property string _competencyAddendum: ""
  // "courte"/"moyenne"/"longue" — picked via the dropdown next to
  // "Régénérer l'appréciation" (Gabriel, 2026-09-28); "moyenne" for a full
  // grid-fill run (no UI for it there yet, and it reproduces the original
  // fixed wording unchanged).
  property string _competencyAppreciationLength: "moyenne"

  function startCompetencyGridFill() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    var ev = CorrectionsStore.getEvaluation(root.corrections, ctx.classId)
    if (!ev) { root.finalizeCorrectionError("Évaluation introuvable."); return }
    var grid = CompetencyGrids.findGrid(ev.gridId)
    if (!grid) { root.finalizeCorrectionError("Grille de compétences introuvable pour cette évaluation."); return }

    var isWritingException = ev.writingExceptions.indexOf(ctx.studentId) !== -1
    var writingMode = isWritingException
      ? (ev.writingMode === "manuscrit" ? "tapuscrit" : "manuscrit")
      : ev.writingMode

    root._competencyGrid = grid
    root._competencyAppreciationOnly = false
    root._competencyAddendum = ""
    root._competencyAppreciationLength = "moyenne"
    var prompt = CompetencyPromptBuilder.buildFillGridPrompt({
      copyPath: ctx.anonymizedCopyPath,
      writingMode: writingMode,
      sujetPath: ev.sujetPath, corrigePath: ev.corrigePath,
      niveauClasse: ev.niveauClasse, bienveillance: ev.bienveillance, complements: ev.complements,
      gridRubricText: CompetencyGrids.buildGridRubricText(grid), rows: grid.rows
    })
    competencyFillProc.command = ClaudeRunner.buildCheckCommand(prompt)
    competencyFillProc.running = false
    competencyFillProc.running = true
  }

  Process {
    id: competencyFillProc
    stdout: StdioCollector { id: competencyFillOut; waitForEnd: true }
    stderr: StdioCollector { id: competencyFillErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.finalizeCorrectionError((competencyFillErr.text || "Échec du remplissage de la grille.").slice(0, 500))
        return
      }
      var parsed = CompetencyPromptBuilder.parseFilledGrid(competencyFillOut.text || "", root._competencyGrid.rows)
      root._competencyChecks = parsed.checks
      root._competencyJustifications = parsed.justifications
      root._competencyLog = parsed.log
      root.startCompetencyAppreciation()
    }
  }

  function startCompetencyAppreciation() {
    var grid = root._competencyGrid
    if (!grid) { root.finalizeCorrectionError("Grille perdue en cours de correction."); return }
    var prompt = PromptBuilder.buildEvalAppreciationPrompt(grid.name, grid.rows, CompetencyGrids.COLUMNS, root._competencyChecks, "", root._competencyAddendum, root._competencyJustifications, root._competencyAppreciationLength)
    competencyAppreciationProc.command = ClaudeRunner.buildCommand(prompt)
    competencyAppreciationProc.running = false
    competencyAppreciationProc.running = true
  }

  Process {
    id: competencyAppreciationProc
    stdout: StdioCollector { id: competencyAppreciationOut; waitForEnd: true }
    stderr: StdioCollector { id: competencyAppreciationErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.finalizeCorrectionError((competencyAppreciationErr.text || "Échec de la génération de l'appréciation.").slice(0, 500))
        return
      }
      root._competencyAppreciation = (competencyAppreciationOut.text || "").trim()
      if (root._competencyAppreciationOnly) root.finalizeCompetencyAppreciationOnly()
      else root.finalizeCompetencyFullRun()
    }
  }

  // The note is NEVER cached at correction time (Gabriel, 2026-09-27, after
  // finding most displayed notes stale/inconsistent with the grid): it's
  // free, instant arithmetic, so caching it only creates a staleness bug —
  // see competencyLiveNote()/competencyEffectiveNote() below, computed
  // fresh every time from whatever the grid + weights currently are.
  // noteSevere/noteBienveillante on a StudentCorrection now mean ONLY "a
  // grade Gabriel typed by hand to override the automatic one" — "" means
  // no override, follow the live calculation.
  function finalizeCompetencyFullRun() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    var logTrim = String(root._competencyLog || "").trim()
    var needsReview = logTrim !== "" && logTrim.toUpperCase() !== "RAS"
    root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, {
      status: "done",
      competencyChecks: root._competencyChecks,
      competencyJustifications: root._competencyJustifications,
      appreciation: root._competencyAppreciation,
      log: needsReview ? logTrim : "",
      needsReview: needsReview,
      error: "",
      reviewed: false,
      logItemStates: {}
    })
    root._correctionRunContext = null
    root._competencyGrid = null
    root.correctionRunningStudentId = ""
    root.processCorrectionQueue()
  }

  // Companion to finalizeCompetencyFullRun() for "Régénérer l'appréciation"
  // alone — touches appreciation (and consumes the one-shot addendum) only,
  // the grid/log/note are left exactly as they were.
  function finalizeCompetencyAppreciationOnly() {
    var ctx = root._correctionRunContext
    if (!ctx) return
    root.setCorrectionStudentPatch(ctx.classId, ctx.studentId, {
      status: "done",
      appreciation: root._competencyAppreciation,
      addendum: ""
    })
    root._correctionRunContext = null
    root._competencyGrid = null
    root._competencyAppreciationOnly = false
    root.correctionRunningStudentId = ""
    root.processCorrectionQueue()
  }

  // Always-fresh automatic note for a student — pure calculation from the
  // grid's current checks and the évaluation's current weights, never
  // stored, so it can never go stale.
  function competencyLiveNote(studentId) {
    var ev = root.activeEvaluation()
    if (!ev || !ev.gridId || !studentId) return { severe: "", bienveillante: "" }
    var grid = CompetencyGrids.findGrid(ev.gridId)
    if (!grid) return { severe: "", bienveillante: "" }
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    return CompetencyGrids.computeWeightedNote(grid, entry.competencyChecks, ev.criteriaWeights)
  }

  // What's actually shown/exported for a student: Gabriel's hand-typed
  // override if he's saved one, otherwise the live automatic calculation.
  function competencyEffectiveNote(studentId) {
    var ev = root.activeEvaluation()
    var entry = ev ? CorrectionsStore.studentEntry(ev, studentId) : CorrectionsStore.emptyStudentEntry()
    if (entry.noteSevere !== "" || entry.noteBienveillante !== "") {
      return { severe: entry.noteSevere, bienveillante: entry.noteBienveillante }
    }
    return root.competencyLiveNote(studentId)
  }

  // Clears a hand-typed override, going back to the automatic calculation.
  function resetCompetencyNoteOverride(studentId) {
    var classId = root.currentCorrectionsClassId()
    if (!classId || !studentId) return
    root.setCorrectionStudentPatch(classId, studentId, { noteSevere: "", noteBienveillante: "" })
  }

  // ---- Compétences popover ------------------------------------------------

  property string competencyGridPopoverStudentId: ""
  function openCompetencyGridPopover(studentId) { root.competencyGridPopoverStudentId = studentId }
  function closeCompetencyGridPopover() { root.competencyGridPopoverStudentId = "" }

  function competencyGridPopoverGrid() {
    var ev = root.activeEvaluation()
    return (ev && ev.gridId) ? CompetencyGrids.findGrid(ev.gridId) : null
  }

  function competencyGridPopoverEntry() {
    var ev = root.activeEvaluation()
    if (!ev || !root.competencyGridPopoverStudentId) return CorrectionsStore.emptyStudentEntry()
    return CorrectionsStore.studentEntry(ev, root.competencyGridPopoverStudentId)
  }

  function competencyGridPopoverStudentLabel() {
    var cls = root.activeClass()
    if (!cls) return ""
    for (var i = 0; i < cls.students.length; i++) {
      if (cls.students[i].id === root.competencyGridPopoverStudentId) return Store.studentLabel(cls.students[i])
    }
    return ""
  }

  // Gabriel overriding one cell by hand — takes effect immediately, no
  // re-run needed; he adjusts the appreciation text himself afterward if
  // the change is significant enough to warrant it (see Gabriel,
  // 2026-09-27: appreciation stays a plain editable field either way).
  function setCompetencyCheck(rowIndex, colIndex) {
    var classId = root.currentCorrectionsClassId()
    if (!classId || !root.competencyGridPopoverStudentId) return
    var entry = root.competencyGridPopoverEntry()
    var checks = {}
    for (var k in entry.competencyChecks) checks[k] = entry.competencyChecks[k]
    checks[String(rowIndex)] = colIndex
    root.setCorrectionStudentPatch(classId, root.competencyGridPopoverStudentId, { competencyChecks: checks })
  }

  // ---- weights popover (creation AND on an existing évaluation) ----------
  //
  // Gabriel, 2026-09-27: rebalancing must be possible after creation too,
  // not just in the wizard — the whole point is testing the effect on
  // copies already corrected without recreating the évaluation.
  property bool correctionWeightsPopoverOpen: false
  function openWeightsPopover() { root.correctionWeightsPopoverOpen = true }
  function closeWeightsPopover() { root.correctionWeightsPopoverOpen = false }
  function setCriteriaWeight(rowIndex, points) {
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!classId || !ev) return
    var weights = {}
    for (var k in ev.criteriaWeights) weights[k] = ev.criteriaWeights[k]
    weights[String(rowIndex)] = Math.max(0, Math.min(20, points))
    var updated = CorrectionsStore.withCriteriaWeights(ev, weights)
    root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
    root.persistCorrections()
  }

  function resetCriteriaWeights() {
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!classId || !ev) return
    var updated = CorrectionsStore.withCriteriaWeights(ev, {})
    root.corrections = CorrectionsStore.setEvaluation(root.corrections, classId, updated)
    root.persistCorrections()
  }

  // Direct hand-edit of the appreciation text, bypassing the agent
  // entirely — same posture as saveCorrectionAppreciation() for the older
  // pipeline's log popover.
  function saveCompetencyAppreciation(studentId, text) {
    var classId = root.currentCorrectionsClassId()
    if (!classId || !studentId) return
    root.setCorrectionStudentPatch(classId, studentId, { appreciation: String(text || "").trim() })
  }

  // Single exact note now (Gabriel, 2026-09-27) — stored in both
  // noteSevere/noteBienveillante (kept equal) so competencyEffectiveNote()'s
  // override detection doesn't need to change shape.
  function saveCompetencyNote(studentId, note) {
    var classId = root.currentCorrectionsClassId()
    if (!classId || !studentId) return
    var clean = String(note || "").trim()
    root.setCorrectionStudentPatch(classId, studentId, {
      noteSevere: clean,
      noteBienveillante: clean
    })
  }

  function findStudentById(cls, studentId) {
    if (!cls) return null
    for (var i = 0; i < cls.students.length; i++) if (cls.students[i].id === studentId) return cls.students[i]
    return null
  }

  function openCompetencyGridCopy() {
    root.openCorrectionCopy(root.competencyGridPopoverEntry().copyPath)
  }

  // Re-runs the appreciation ONLY, from the grid AS IT CURRENTLY STANDS —
  // never re-reads the copy, and never touches the note (Gabriel,
  // 2026-09-27: the two regenerations are independent on purpose — he may
  // agree with one and not the other). addendumText is an optional one-shot
  // instruction ("l'axe II, bien que complet, est bâclé") taken into
  // account for this rédaction only, then consumed. lengthOption is
  // "courte"/"moyenne"/"longue" from the dropdown beside the button
  // (Gabriel, 2026-09-28), defaulting to "moyenne".
  function requestRegenerateCompetencyAppreciation(studentId, addendumText, lengthOption) {
    if (root.correctionRunningStudentId !== "") return
    var classId = root.currentCorrectionsClassId()
    var ev = root.activeEvaluation()
    if (!classId || !ev || !ev.gridId || !studentId) return
    var grid = CompetencyGrids.findGrid(ev.gridId)
    if (!grid) return
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    root.correctionRunningStudentId = studentId
    root.setCorrectionStudentPatch(classId, studentId, { status: "running", error: "" })
    root._correctionRunContext = { classId: classId, studentId: studentId }
    root._competencyGrid = grid
    root._competencyChecks = entry.competencyChecks
    root._competencyJustifications = entry.competencyJustifications
    root._competencyLog = entry.log
    root._competencyAppreciationOnly = true
    root._competencyAddendum = String(addendumText || "").trim()
    root._competencyAppreciationLength = lengthOption || "moyenne"
    root.startCompetencyAppreciation()
  }

  // ---- Compétences popover: PDF export (Gabriel, 2026-09-27) -------------
  //
  // Reuses the exact same shared path-entry bar as "Eval. Compétences" own
  // export (root.pathBarMode, see confirmPathEntry()) — the popover closes
  // first since it's a full-screen modal that would otherwise sit on top
  // of that bar. `includeJustifications` is carried across that gap as a
  // plain property rather than a function argument, set by the popover's
  // own toggle right before it closes.
  property bool competencyExportIncludeJustifications: false
  property string _competencyExportStudentId: ""
  property string competencyPdfExportError: ""
  property string competencyPdfExportedPath: ""
  property string _pendingCompetencyPdfPath: ""
  readonly property string competencyExportSrcPath: root.stateDir + "/.ghclasses-competency-export.typ"
  property string _competencyExportLastSrc: ""

  function requestExportCompetencyPdf(studentId, includeJustifications) {
    root._competencyExportStudentId = studentId
    root.competencyExportIncludeJustifications = includeJustifications
    root.closeCompetencyGridPopover()
    var cls = root.activeClass()
    var student = root.findStudentById(cls, studentId)
    root.pathBarMode = "exportCompetencyPdf"
    var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
    pathBarField.text = root.homeDir + "/Downloads/competences-" + root.slugify(student ? Store.studentLabel(student) : studentId) + "-" + ts + ".pdf"
    Qt.callLater(function() { pathBarField.forceActiveFocus() })
  }

  function buildCompetencyTypst(studentId) {
    var ev = root.activeEvaluation()
    var cls = root.activeClass()
    if (!ev || !ev.gridId || !cls) return ""
    var grid = CompetencyGrids.findGrid(ev.gridId)
    var student = root.findStudentById(cls, studentId)
    if (!grid || !student) return ""
    var entry = CorrectionsStore.studentEntry(ev, studentId)
    var effectiveNote = root.competencyEffectiveNote(studentId)
    var payload = {
      checks: entry.competencyChecks,
      appreciation: entry.appreciation,
      note: effectiveNote.severe || "",
      justifications: entry.competencyJustifications,
      includeJustifications: root.competencyExportIncludeJustifications,
      // Gabriel, 2026-09-27: note en gras à la fin du paragraphe
      // d'appréciation, plus de section séparée — voir buildTypstSource().
      inlineNote: true
    }
    return CompetencyGrids.buildTypstSource(Store.studentLabel(student), cls.name, grid, payload, ev.title)
  }

  function startCompetencyPdfExport(destPath) {
    var src = root.buildCompetencyTypst(root._competencyExportStudentId)
    if (!src) return
    root.competencyPdfExportError = ""
    root.competencyPdfExportedPath = ""
    root._pendingCompetencyPdfPath = destPath
    if (src === root._competencyExportLastSrc) {
      root._startCompetencyPdfCompile()
    } else {
      root._competencyExportLastSrc = src
      competencyExportSrcFile.setText(src)
    }
  }

  function _startCompetencyPdfCompile() {
    competencyPdfCompileProc.command = ["typst", "compile", root.competencyExportSrcPath, root._pendingCompetencyPdfPath]
    competencyPdfCompileProc.running = false
    competencyPdfCompileProc.running = true
  }

  FileView {
    id: competencyExportSrcFile
    path: root.competencyExportSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startCompetencyPdfCompile()
  }

  Process {
    id: competencyPdfCompileProc
    stderr: StdioCollector { id: competencyPdfCompileErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.competencyPdfExportError = (competencyPdfCompileErr.text || "Échec de l'export PDF.").slice(0, 500)
        return
      }
      root.competencyPdfExportedPath = root._pendingCompetencyPdfPath
    }
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


  // ---- final Typst export placeholder (waiting on the sticker-sheet
  // template, same status as addAppreciationToLabelSheet() above) --------

  property string correctionsTypstFeedback: ""
  function generateCorrectionsTypstPage() {
    root.correctionsTypstFeedback = "Bientôt disponible — en attente du gabarit Typst pour les corrections."
    correctionsTypstFeedbackTimer.restart()
  }
  Timer { id: correctionsTypstFeedbackTimer; interval: 2500; repeat: false; onTriggered: root.correctionsTypstFeedback = "" }

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

  // Gabriel, 2026-10-03: lets him spot an absent/forgotten student at a
  // glance in the "Élève" dropdown while correcting a whole class — "corrigé"
  // means an appreciation has actually been written for this grid, same
  // idiom as the Corrections tab's own entry.appreciation !== "" check.
  function evaluationStudentDone(student) {
    var entry = student && student.competencyGrids && student.competencyGrids[root.evaluationGridId]
    return !!(entry && String(entry.appreciation || "").trim() !== "")
  }

  // Unlike checks/appreciation/note, the intitulé (assignment title) lives
  // on the Class, not the Student — it's the same for every student
  // evaluated on this grid, typed once rather than retyped per student.
  function evaluationIntitule() {
    var cls = root.activeClass()
    var intitules = (cls && cls.competencyIntitules) || {}
    return intitules[root.evaluationGridId] || ""
  }

  // ---- per-criterion points ("⚖️ Répartir les points"), Gabriel 2026-10-01 ----
  // Same idea as the Corrections tab's own criteriaWeights, but scoped per
  // (classe, grille) on the Class rather than per-évaluation — see
  // Store.js's Class schema comment. Persistent, never auto-recomputed;
  // the Note is always the live sum of checked paliers × these weights
  // (evaluationComputedNote() below), there is no separate stored note
  // anymore (Gabriel, 2026-10-01: "l'emplacement des notes renvoie
  // toujours la somme des points selon les cases cochées").

  function evaluationWeights() {
    var cls = root.activeClass()
    var all = (cls && cls.competencyWeights) || {}
    return all[root.evaluationGridId] || {}
  }

  property bool evaluationWeightsPopoverOpen: false
  function openEvaluationWeightsPopover() { root.evaluationWeightsPopoverOpen = true }
  function closeEvaluationWeightsPopover() { root.evaluationWeightsPopoverOpen = false }

  function setEvaluationWeight(rowIndex, points) {
    var cls = root.activeClass()
    if (!cls || !root.evaluationGridId) return
    var all = {}
    var existingAll = cls.competencyWeights || {}
    Object.keys(existingAll).forEach(function(gid) { all[gid] = existingAll[gid] })
    var rows = {}
    var existingRows = all[root.evaluationGridId] || {}
    Object.keys(existingRows).forEach(function(k) { rows[k] = existingRows[k] })
    rows[String(rowIndex)] = Math.max(0, Math.min(root.evaluationBaremeTotal(), points))
    all[root.evaluationGridId] = rows
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: all, competencyBaremeTotal: cls.competencyBaremeTotal }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  function resetEvaluationWeights() {
    var cls = root.activeClass()
    if (!cls || !root.evaluationGridId) return
    var all = {}
    var existingAll = cls.competencyWeights || {}
    Object.keys(existingAll).forEach(function(gid) { all[gid] = existingAll[gid] })
    delete all[root.evaluationGridId]
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: all, competencyBaremeTotal: cls.competencyBaremeTotal }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  // Grading scale for this (classe, grille) — 10 or 20, Gabriel 2026-10-02.
  function evaluationBaremeTotal() {
    var cls = root.activeClass()
    var all = (cls && cls.competencyBaremeTotal) || {}
    return all[root.evaluationGridId] || 20
  }

  function setEvaluationBaremeTotal(total) {
    var cls = root.activeClass()
    if (!cls || !root.evaluationGridId) return
    var all = {}
    var existingAll = cls.competencyBaremeTotal || {}
    Object.keys(existingAll).forEach(function(gid) { all[gid] = existingAll[gid] })
    all[root.evaluationGridId] = (Number(total) === 10) ? 10 : 20
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: cls.students, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: all }
    root.classes = Store.replaceClass(root.classes, updatedClass)
    root.persistClasses()
    if (root.syncDir) root.runSync()
  }

  // The only place the Note is computed — never cached/stored (see
  // [[gh-corrections-plugin]]'s "Stale note incident" for why: a recipe
  // this cheap to recompute should never risk going stale).
  function evaluationComputedNote() {
    var grid = root.activeEvaluationGrid()
    if (!grid) return ""
    var entry = root.evaluationGridEntry()
    var checks = entry ? entry.checks : {}
    return CompetencyGrids.computeWeightedNote(grid, checks, root.evaluationWeights()).severe
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
      var entry = grids[root.evaluationGridId] || { checks: {}, appreciation: "", note: "", annotationsPositif: "", annotationsNegatif: "" }
      var checks = {}
      Object.keys(entry.checks || {}).forEach(function(k) { checks[k] = entry.checks[k] })
      if (checks[rowIndex] === colIndex) delete checks[rowIndex]
      else checks[rowIndex] = colIndex
      grids[root.evaluationGridId] = { checks: checks, appreciation: entry.appreciation || "", note: entry.note || "", annotationsPositif: entry.annotationsPositif || "", annotationsNegatif: entry.annotationsNegatif || "" }
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids, competencyClearedAt: s.competencyClearedAt }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
      // Tombstones the clear so a sync merge can't resurrect this grid's
      // data from a stale copy — bug found 2026-10-01, see
      // Store.mergeCompetencyGrids()'s own header comment.
      var clearedAt = {}
      var existingClearedAt = s.competencyClearedAt || {}
      Object.keys(existingClearedAt).forEach(function(gid) { clearedAt[gid] = existingClearedAt[gid] })
      clearedAt[root.evaluationGridId] = new Date().toISOString()
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids, competencyClearedAt: clearedAt }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
      var clearedAt = {}
      var existingClearedAt = s.competencyClearedAt || {}
      Object.keys(existingClearedAt).forEach(function(gid) { clearedAt[gid] = existingClearedAt[gid] })
      clearedAt[root.evaluationGridId] = new Date().toISOString()
      return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids, competencyClearedAt: clearedAt }
    })
    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: cls.competencyIntitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
    evaluationAnnotationsPositifField.text = entry ? (entry.annotationsPositif || "") : ""
    evaluationAnnotationsNegatifField.text = entry ? (entry.annotationsNegatif || "") : ""
    root.evalCheckResult = ""
    root.evalCheckError = ""
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
      var annotationsPositif = evaluationAnnotationsPositifField.text
      var annotationsNegatif = evaluationAnnotationsNegatifField.text
      updatedStudents = cls.students.map(function(s) {
        if (s.id !== root.evaluationStudentId) return s
        var grids = {}
        var existingGrids = s.competencyGrids || {}
        Object.keys(existingGrids).forEach(function(gid) { grids[gid] = existingGrids[gid] })
        var entry = grids[root.evaluationGridId] || { checks: {}, appreciation: "", note: "", annotationsPositif: "", annotationsNegatif: "" }
        // note is no longer stored — always the live sum of checks × weights
        // now, see evaluationComputedNote().
        grids[root.evaluationGridId] = { checks: entry.checks || {}, appreciation: appreciation, note: "", annotationsPositif: annotationsPositif, annotationsNegatif: annotationsNegatif }
        return { id: s.id, nom: s.nom, prenom: s.prenom, drawCount: s.drawCount, drawHistory: s.drawHistory, competencyGrids: grids, competencyClearedAt: s.competencyClearedAt }
      })
    }

    var updatedClass = { id: cls.id, name: cls.name, createdAt: cls.createdAt, students: updatedStudents, incompatibilities: cls.incompatibilities, lastResetAt: cls.lastResetAt, competencyIntitules: intitules, competencyWeights: cls.competencyWeights, competencyBaremeTotal: cls.competencyBaremeTotal }
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
      note: root.evaluationComputedNote()
    }
    return CompetencyGrids.buildTypstSource(Store.studentLabel(student), cls.name, grid, payload, evaluationIntituleField.text, root.evaluationBaremeTotal())
  }

  // Same payload as buildEvaluationTypst(), plain markdown instead of
  // Typst (Gabriel, 2026-10-01) — for pasting somewhere that doesn't read
  // Typst (ex. École Directe, a markdown-only destination like the
  // Groupes tab's own "📋 Copier en markdown").
  function buildEvaluationMarkdown() {
    var cls = root.activeClass()
    var grid = root.activeEvaluationGrid()
    var student = root.evaluationStudent()
    if (!cls || !grid || !student) return ""
    var entry = (student.competencyGrids && student.competencyGrids[grid.id]) || {}
    var payload = {
      checks: entry.checks || {},
      appreciation: evaluationAppreciationField.text,
      note: root.evaluationComputedNote()
    }
    return CompetencyGrids.buildMarkdownSource(Store.studentLabel(student), cls.name, grid, payload, evaluationIntituleField.text, root.evaluationBaremeTotal())
  }

  // Reinstated 2026-10-02, this time fully independent from the Corrections
  // tab's own generator ("vraiment à part, débranché", Gabriel's own words)
  // — see PromptBuilder.buildEvalCompetencesAppreciationPrompt(). Grounded
  // only in checked paliers (with their real written text) + the two
  // annotation columns below; overwrites whatever was already typed, same
  // low-friction convention as "Régénérer l'appréciation" elsewhere.
  property bool evalGeneratingAppreciation: false
  property string evalGenAppreciationError: ""

  function requestGenerateEvalAppreciation() {
    var grid = root.activeEvaluationGrid()
    var student = root.evaluationStudent()
    if (!grid || !student) return
    var entry = root.evaluationGridEntry()
    var checks = entry ? entry.checks : {}
    var prompt = PromptBuilder.buildEvalCompetencesAppreciationPrompt(grid.name, grid.rows, CompetencyGrids.COLUMNS, checks, evaluationAnnotationsPositifField.text, evaluationAnnotationsNegatifField.text)
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

  // "✓ Vérifier l'orthographe et la syntaxe" — a check ONLY of what Gabriel
  // himself already wrote/generated in the Appréciation field, fully
  // grounded (the text to review IS the whole input), no invention
  // possible by construction. Read-only report, never rewrites the field
  // itself — he decides what to fix (or uses "✅ Appliquer les
  // corrections" below).
  property bool evalCheckingAppreciation: false
  property string evalCheckResult: ""
  property string evalCheckError: ""

  function requestCheckAppreciation() {
    var text = evaluationAppreciationField.text
    if (!String(text || "").trim()) return
    var prompt = PromptBuilder.buildAppreciationCheckPrompt(text)
    root.evalCheckingAppreciation = true
    root.evalCheckError = ""
    root.evalCheckResult = ""
    evalCheckProc.command = ClaudeRunner.buildCommand(prompt)
    evalCheckProc.running = false
    evalCheckProc.running = true
  }

  Process {
    id: evalCheckProc
    stdout: StdioCollector { id: evalCheckOut; waitForEnd: true }
    stderr: StdioCollector { id: evalCheckErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalCheckingAppreciation = false
      if (exitCode !== 0) {
        root.evalCheckError = (evalCheckErr.text || "Échec de la vérification.").slice(0, 500)
        return
      }
      root.evalCheckResult = (evalCheckOut.text || "").trim()
    }
  }

  // "✅ Appliquer les corrections" (Gabriel, 2026-10-02) — a second, separate
  // call, constrained to the specific faults evalCheckResult already named
  // (passed in verbatim, see buildAppreciationApplyFixesPrompt), not a
  // fresh unconstrained rewrite. Overwrites the Appréciation field directly
  // on success, same low-friction convention as "Régénérer l'appréciation"
  // elsewhere in this file (no confirm dialog — this is draft text Gabriel
  // is actively editing, not a destructive delete).
  property bool evalApplyingFixes: false
  property string evalApplyFixesError: ""

  function requestApplyAppreciationFixes() {
    var text = evaluationAppreciationField.text
    if (!String(text || "").trim() || !root.evalCheckResult || root.evalCheckResult === "RAS") return
    var prompt = PromptBuilder.buildAppreciationApplyFixesPrompt(text, root.evalCheckResult)
    root.evalApplyingFixes = true
    root.evalApplyFixesError = ""
    evalApplyFixesProc.command = ClaudeRunner.buildCommand(prompt)
    evalApplyFixesProc.running = false
    evalApplyFixesProc.running = true
  }

  Process {
    id: evalApplyFixesProc
    stdout: StdioCollector { id: evalApplyFixesOut; waitForEnd: true }
    stderr: StdioCollector { id: evalApplyFixesErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalApplyingFixes = false
      if (exitCode !== 0) {
        root.evalApplyFixesError = (evalApplyFixesErr.text || "Échec de l'application des corrections.").slice(0, 500)
        return
      }
      var result = (evalApplyFixesOut.text || "").trim()
      if (result) evaluationAppreciationField.text = result
      // The report just got applied (or Gabriel can re-check to confirm) —
      // clear it so a stale report can't be re-applied a second time.
      root.evalCheckResult = ""
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

  // Shares evalCopyProc/evalCopyFeedback with copyEvaluationTypst() above —
  // same clipboard mechanics, just a different source text, no need for a
  // second Process/Timer pair.
  function copyEvaluationMarkdown() {
    var src = root.buildEvaluationMarkdown()
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

  // ---- feature 5: assistant de correction ------------------------------------
  //
  // Gabriel, 2026-10-02: a support tool, deliberately NOT an auto-correction
  // pipeline — no grade, no appréciation, just countable/structural
  // observations on one copy at a time, read-only (never writes a file),
  // each "élément de repérage" independently optional. Ephemeral, like GH
  // Grilles' own in-progress grid: nothing here is persisted to disk.

  property string assistantCopyPath: ""
  property bool assistantCheckFautes: true
  property bool assistantCheckPlan: true
  property bool assistantCheckMiseEnPage: true
  property bool assistantCheckIntroConclusion: true
  property bool assistantRunning: false
  property string assistantError: ""
  property string assistantResult: ""
  property string assistantCopyFeedback: ""

  function requestRunCorrectionAssistant() {
    var path = root.expandHome(root.assistantCopyPath)
    var items = {
      fautes: root.assistantCheckFautes,
      plan: root.assistantCheckPlan,
      miseEnPage: root.assistantCheckMiseEnPage,
      introConclusion: root.assistantCheckIntroConclusion
    }
    if (!path) { root.assistantError = "Indiquez le chemin de la copie à analyser."; return }
    if (!items.fautes && !items.plan && !items.miseEnPage && !items.introConclusion) {
      root.assistantError = "Cochez au moins un élément de repérage."
      return
    }
    root.assistantRunning = true
    root.assistantError = ""
    root.assistantResult = ""
    var prompt = CorrectionAssistantPromptBuilder.build(path, items)
    assistantProc.command = ClaudeRunner.buildCheckCommand(prompt)
    assistantProc.running = false
    assistantProc.running = true
  }

  Process {
    id: assistantProc
    stdout: StdioCollector { id: assistantOut; waitForEnd: true }
    stderr: StdioCollector { id: assistantErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.assistantRunning = false
      if (exitCode !== 0) {
        root.assistantError = (assistantErr.text || "Échec de l'analyse.").slice(0, 500)
        return
      }
      root.assistantResult = (assistantOut.text || "").trim()
    }
  }

  function copyAssistantResult() {
    if (!root.assistantResult) return
    assistantCopyProc.command = ["wl-copy", root.assistantResult]
    assistantCopyProc.running = false
    assistantCopyProc.running = true
  }

  Process {
    id: assistantCopyProc
    onExited: function(exitCode) {
      root.assistantCopyFeedback = exitCode === 0 ? "Copié !" : "Échec de la copie."
      assistantCopyFeedbackTimer.restart()
    }
  }
  Timer { id: assistantCopyFeedbackTimer; interval: 2000; repeat: false; onTriggered: root.assistantCopyFeedback = "" }

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
          || evalTemplateSaveField.activeFocus
          || methodeCritereField.activeFocus || contenuCritereField.activeFocus || langueCritereField.activeFocus
          || correctionComplementsField.activeFocus
          || evaluationIntituleField.activeFocus || evaluationAppreciationField.activeFocus
          || evaluationAnnotationsPositifField.activeFocus || evaluationAnnotationsNegatifField.activeFocus
          || root.classSettingsOpen || root.incompatOpen || root.pathBarMode !== ""
          || root.deleteClassPendingId !== "" || root.resetDrawsConfirmOpen || root.syncSettingsOpen
          || root.correctionReplaceConfirmOpen
          || root.correctionConsignesOverwriteConfirmOpen
          || root.correctionWritingPopoverOpen
          || root.correctionLogPopoverStudentId !== ""
          || root.resetEvaluationStudentConfirmOpen || root.resetEvaluationClassConfirmOpen
        onCloseRequested: root.requestClose()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(18)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          // Gabriel, 2026-10-02: panel-wide zoom via a scale transform
          // rather than multiplying every font.pixelSize in this file
          // (thousands of them) — zoomWrapper reports the REAL scaled
          // size to the ScrollView/Flickable (contentColumn.width/height
          // × uiZoom), so scrolling reaches the whole content with no
          // clipping; contentColumn's own layout width is pre-divided by
          // uiZoom so, once visually scaled back up, it still exactly
          // fills the viewport at any zoom level.
          Item {
            id: zoomWrapper
            width: contentColumn.width * root.uiZoom
            height: contentColumn.height * root.uiZoom
            // ScrollView sizes its scrollable range from the content
            // item's implicitWidth/implicitHeight, not width/height — a
            // plain Item never derives one from the other, so without
            // this the Flickable's contentHeight stayed stuck at 0 and
            // only long tabs (Corrections) exposed the missing scroll.
            implicitWidth: width
            implicitHeight: height

          Column {
            id: contentColumn
            width: scrollArea.availableWidth / root.uiZoom
            scale: root.uiZoom
            transformOrigin: Item.TopLeft
            spacing: Style.spacing.huge

            // ---------------------------------------------------- header

            Item {
              width: parent.width
              height: Math.max(titleText.implicitHeight, settingsButton.implicitHeight, syncButton.implicitHeight, zoomControls.implicitHeight)

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

              // Gabriel, 2026-10-02: whole-panel zoom, same idea as GH
              // Typst's editor zoom but applied to all of GH Classes (not
              // one editor pane) — see uiZoom/setUiZoom() and zoomWrapper
              // further down.
              Row {
                id: zoomControls
                anchors.right: syncButton.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                Button {
                  text: "−"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.setUiZoom(root.uiZoom - 0.1)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(44)
                  horizontalAlignment: Text.AlignHCenter
                  text: Math.round(root.uiZoom * 100) + "%"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Button {
                  text: "+"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.setUiZoom(root.uiZoom + 0.1)
                }
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
                tooltipText: (root.syncDir !== "" ? ("Synchronisée vers : " + root.syncDir) : "Synchronisation désactivée") + " · Agent par défaut : " + (root.agentPath || "non configuré")
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
                  { value: "evaluation", label: "📋 Eval. Compétences" },
                  { value: "assistant", label: "🔎 Assistant de correction" },
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
                  text: root.pathBarMode === "exportEvalPdf" ? "Exporter la grille (.pdf) vers :"
                    : root.pathBarMode === "exportCompetencyPdf" ? "Exporter la fiche (.pdf) vers :"
                    : "Exporter les statistiques (.csv) vers :"
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

              // Feedback for the Compétences popover's own PDF export — kept
              // top-level (not inside the "corrections" tab's own Column)
              // since the popover closes before the path bar above appears,
              // and Gabriel may have switched tabs by the time the compile
              // finishes.
              Text {
                visible: root.competencyPdfExportedPath !== ""
                width: parent.width
                text: "Fiche exportée : " + root.competencyPdfExportedPath
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
              }

              Text {
                visible: root.competencyPdfExportError !== ""
                width: parent.width
                text: root.competencyPdfExportError
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
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
                    visible: root.evalTemplates.length > 0
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Charger un modèle"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Dropdown {
                      width: parent.width
                      options: [{ value: "", label: "— Choisir un modèle enregistré —" }].concat(root.evalTemplates.map(function(t) { return { value: t.id, label: t.name } }))
                      value: ""
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { if (v) root.applyEvalTemplate(v) }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.controlGap
                    TextField {
                      id: evalTemplateSaveField
                      width: parent.width - Style.space(220)
                      placeholderText: "Nom du modèle à enregistrer…"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 160
                      text: root.evalTemplateSaveName
                      onTextChanged: root.evalTemplateSaveName = text
                    }
                    Button {
                      text: "💾 Enregistrer comme modèle"
                      bordered: true
                      enabled: root.evalTemplateSaveName.trim() !== ""
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: { root.requestSaveEvalTemplate(); evalTemplateSaveField.text = "" }
                    }
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Column {
                    visible: root.correctionDraftGridId === ""
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
                      onChanged: function(v) { root.correctionDraftExerciseType = v; root.applyStructureDefaultsForType(v) }
                    }
                    Text {
                      visible: root.correctionDraftExerciseType !== ""
                      width: parent.width
                      text: "Aucun gabarit de consignes n'est écrit pour ce type d'exercice — les compléments ci-dessous devront porter l'intégralité des attentes (le barème a sa propre case plus bas)."
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.xxs
                    Text { text: "Grille de compétences (pipeline agent)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                    Dropdown {
                      width: parent.width
                      // Filtered against CorrectionsStore.GRID_IDS (not just
                      // every CompetencyGrids.GRIDS entry): a grid added for
                      // Eval. Compétences only (ex. "Introduction") isn't
                      // valid here — picking it would silently fail to
                      // persist (sanitizeEvaluationParams resets gridId to
                      // "" on the next load), which is worse than just not
                      // offering it. Found by Gabriel, 2026-10-02.
                      options: [{ value: "", label: "— Aucune (ancien pipeline, une appréciation directe) —" }].concat(CompetencyGrids.GRIDS.filter(function(g) { return CorrectionsStore.GRID_IDS.indexOf(g.id) !== -1 }).map(function(g) { return { value: g.id, label: g.name } }))
                      value: root.correctionDraftGridId
                      foreground: root.foreground
                      background: root.background
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onChanged: function(v) { root.correctionDraftGridId = v }
                    }
                    Text {
                      visible: root.correctionDraftGridId !== ""
                      width: parent.width
                      text: "L'agent remplira cette grille en lisant chaque copie, puis en rédigera l'appréciation — au lieu de rédiger directement une appréciation libre. Le type d'exercice, le niveau de surinterprétation et le niveau de détail ci-dessus n'ont aucun effet pour ce pipeline."
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                    Button {
                      visible: root.correctionDraftGridId !== ""
                      text: "⚖️ Répartir les points par critère"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.openDraftWeightsPopover()
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

                  Text {
                    width: parent.width
                    text: "Le sujet et le corrigé sont retrouvés automatiquement dans le dossier ci-dessus, sous les noms \"sujet.pdf\" (obligatoire) et \"corrigé.pdf\" (facultatif)."
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  PanelSeparator { foreground: root.foreground; width: parent.width }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.md
                    Text { text: "Paramètres de cette évaluation"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }

                    // Only feeds consigne.md (ConsignesBuilder), never
                    // generated at all once a grille is selected — see
                    // requestCreateEvaluation()/finalizeCorrectionCreation().
                    // Gabriel, 2026-10-02: hidden in grid mode, same
                    // convention as "Type d'exercice"/"Niveau de
                    // surinterprétation"/"Niveau de détail" above.
                    Dropdown {
                      visible: root.correctionDraftGridId === ""
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
                      visible: root.correctionDraftGridId === ""
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
                      visible: root.correctionDraftGridId === ""
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
                      visible: root.correctionDraftGridId === ""
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
                      visible: root.correctionDraftGridId === ""
                      width: parent.width
                      label: "Sujet à traiter intégralement"
                      description: "Coché = une copie incomplète doit être signalée comme telle."
                      checked: root.correctionDraftCompletudeExigee
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftCompletudeExigee = !root.correctionDraftCompletudeExigee
                    }


                    Dropdown {
                      visible: root.correctionDraftGridId === ""
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
                      visible: root.correctionDraftGridId === ""
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

                  // ---- structure de l'appréciation (pipeline sans grille) ----
                  // Gabriel, 2026-10-03: chaque partie est désormais optionnelle
                  // plutôt qu'imposée — voir CorrectionPromptBuilder.build() et
                  // applyStructureDefaultsForType() pour la précoche par type.

                  Column {
                    visible: root.correctionDraftGridId === ""
                    width: parent.width
                    spacing: Style.spacing.md
                    Text { text: "Structure de l'appréciation"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }

                    Toggle {
                      width: parent.width
                      label: "Partie \"Méthode\""
                      description: "Organisation, démarche, structure du devoir — pertinent pour un exercice en rédaction continue (commentaire, dissertation, essai...), pas pour un questionnaire."
                      checked: root.correctionDraftStructMethode
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftStructMethode = !root.correctionDraftStructMethode
                    }
                    Column {
                      visible: root.correctionDraftStructMethode
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Repeater {
                        width: parent.width
                        model: root.correctionDraftMethodeCriteres
                        Row {
                          width: parent.width
                          spacing: Style.spacing.controlGap
                          Text {
                            width: parent.width - (root.correctionDraftNotee ? Style.space(170) : Style.space(40))
                            anchors.verticalCenter: parent.verticalCenter
                            text: "• " + modelData.text
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                          }
                          NumberField {
                            visible: root.correctionDraftNotee
                            width: Style.space(110)
                            value: root.correctionDraftCriteriaPoints[modelData.id] || 0
                            from: 0
                            to: 20
                            stepSize: 1
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            onModified: function(v) { root.setCriterionPoints(modelData.id, v) }
                          }
                          Button {
                            text: "✕"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.removeCritere("methode", modelData.id)
                          }
                        }
                      }
                      Row {
                        width: parent.width
                        spacing: Style.spacing.controlGap
                        TextField {
                          id: methodeCritereField
                          width: parent.width - Style.space(140)
                          placeholderText: "Ajouter un critère précis…"
                          foreground: root.foreground
                          accent: root.accent
                          maximumLength: 500
                          Keys.onReturnPressed: { root.addCritere("methode", text); text = "" }
                        }
                        Button {
                          text: "Ajouter le critère"
                          bordered: true
                          foreground: root.foreground
                          accent: root.accent
                          onClicked: { root.addCritere("methode", methodeCritereField.text); methodeCritereField.text = "" }
                        }
                      }
                    }

                    Toggle {
                      width: parent.width
                      label: "Partie \"Contenu\""
                      description: "Compréhension, analyse, interprétation du texte."
                      checked: root.correctionDraftStructContenu
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftStructContenu = !root.correctionDraftStructContenu
                    }
                    Column {
                      visible: root.correctionDraftStructContenu
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Repeater {
                        width: parent.width
                        model: root.correctionDraftContenuCriteres
                        Row {
                          width: parent.width
                          spacing: Style.spacing.controlGap
                          Text {
                            width: parent.width - (root.correctionDraftNotee ? Style.space(170) : Style.space(40))
                            anchors.verticalCenter: parent.verticalCenter
                            text: "• " + modelData.text
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                          }
                          NumberField {
                            visible: root.correctionDraftNotee
                            width: Style.space(110)
                            value: root.correctionDraftCriteriaPoints[modelData.id] || 0
                            from: 0
                            to: 20
                            stepSize: 1
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            onModified: function(v) { root.setCriterionPoints(modelData.id, v) }
                          }
                          Button {
                            text: "✕"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.removeCritere("contenu", modelData.id)
                          }
                        }
                      }
                      Row {
                        width: parent.width
                        spacing: Style.spacing.controlGap
                        TextField {
                          id: contenuCritereField
                          width: parent.width - Style.space(140)
                          placeholderText: "Ajouter un critère précis…"
                          foreground: root.foreground
                          accent: root.accent
                          maximumLength: 500
                          Keys.onReturnPressed: { root.addCritere("contenu", text); text = "" }
                        }
                        Button {
                          text: "Ajouter le critère"
                          bordered: true
                          foreground: root.foreground
                          accent: root.accent
                          onClicked: { root.addCritere("contenu", contenuCritereField.text); contenuCritereField.text = "" }
                        }
                      }
                    }

                    Toggle {
                      width: parent.width
                      label: "Partie \"Expression écrite\""
                      description: "Langue, orthographe, style, niveau de langue."
                      checked: root.correctionDraftStructLangue
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftStructLangue = !root.correctionDraftStructLangue
                    }
                    Column {
                      visible: root.correctionDraftStructLangue
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Repeater {
                        width: parent.width
                        model: root.correctionDraftLangueCriteres
                        Row {
                          width: parent.width
                          spacing: Style.spacing.controlGap
                          Text {
                            width: parent.width - (root.correctionDraftNotee ? Style.space(170) : Style.space(40))
                            anchors.verticalCenter: parent.verticalCenter
                            text: "• " + modelData.text
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                          }
                          NumberField {
                            visible: root.correctionDraftNotee
                            width: Style.space(110)
                            value: root.correctionDraftCriteriaPoints[modelData.id] || 0
                            from: 0
                            to: 20
                            stepSize: 1
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            onModified: function(v) { root.setCriterionPoints(modelData.id, v) }
                          }
                          Button {
                            text: "✕"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.removeCritere("langue", modelData.id)
                          }
                        }
                      }
                      Row {
                        width: parent.width
                        spacing: Style.spacing.controlGap
                        TextField {
                          id: langueCritereField
                          width: parent.width - Style.space(140)
                          placeholderText: "Ajouter un critère précis…"
                          foreground: root.foreground
                          accent: root.accent
                          maximumLength: 500
                          Keys.onReturnPressed: { root.addCritere("langue", text); text = "" }
                        }
                        Button {
                          text: "Ajouter le critère"
                          bordered: true
                          foreground: root.foreground
                          accent: root.accent
                          onClicked: { root.addCritere("langue", langueCritereField.text); langueCritereField.text = "" }
                        }
                      }
                    }

                    Toggle {
                      width: parent.width
                      label: "Évaluation notée ?"
                      description: "Décoché, l'agent ne propose aucune note (N/A) pour ces copies."
                      checked: root.correctionDraftNotee
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.correctionDraftNotee = !root.correctionDraftNotee
                    }
                    Text {
                      visible: root.correctionDraftNotee
                      width: parent.width
                      text: "Un critère sans points n'est pas noté (juste un point à vérifier dans la prose). Pour un critère pondéré : Palier 1 = 0 pt, Palier 2 = 1/3 des points, Palier 3 = 2/3, Palier 4 = la totalité — la note finale est la somme sur /20. Sans aucun critère pondéré, l'agent revient à proposer librement trois notes (sévère/neutre/bienveillante), calibrées par le barème ci-dessous."
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.italic: true
                      wrapMode: Text.WordWrap
                    }
                    Column {
                      visible: root.correctionDraftNotee
                      width: parent.width
                      spacing: Style.spacing.xxs
                      Text { text: "Barème"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
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
                            id: correctionBaremeField
                            wrapMode: TextArea.Wrap
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            background: null
                            text: root.correctionDraftBareme
                            placeholderText: "Paliers ou barème indicatif, pour calibrer les notes proposées…"
                            onTextChanged: root.correctionDraftBareme = text
                          }
                        }
                      }
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

                  Text {
                    width: parent.width
                    text: "Agent (markdown) : " + (root.agentPath || "non configuré") + " — réglage global, voir le bouton \"🔄 Synchro\" en haut."
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WrapAnywhere
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
                        visible: !!(root.activeEvaluation() && root.activeEvaluation().gridId)
                        text: "⚖️ Répartir les points"
                        bordered: true
                        foreground: root.foreground
                        accent: root.accent
                        onClicked: root.openWeightsPopover()
                      }
                      Dropdown {
                        visible: !!(root.activeEvaluation() && !root.activeEvaluation().gridId)
                        width: Style.space(160)
                        options: ConsignesBuilder.DETAIL_OPTIONS
                        value: root.activeEvaluation() ? root.activeEvaluation().niveauDetail : "moyen"
                        foreground: root.foreground
                        background: root.background
                        accent: root.accent
                        fontFamily: root.fontFamily
                        onChanged: function(v) { root.setEvaluationNiveauDetail(v) }
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

                        readonly property bool usesGrid: !!(root.activeEvaluation() && root.activeEvaluation().gridId)

                        ButtonGroup {
                          visible: !correctionRow.entry.excluded && correctionRow.entry.status === "done" && !correctionRow.usesGrid
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

                        // Grid-first pipeline's own grade: one exact number
                        // now (Gabriel, 2026-09-27), summed from points ×
                        // palier per critère — no click-to-validate here, he
                        // writes the definitive grade by hand on the copy
                        // itself. Always the EFFECTIVE note (his override if
                        // he's saved one, otherwise the live automatic
                        // calculation) — never a cached value, see
                        // competencyEffectiveNote().
                        readonly property var effectiveNote: root.competencyEffectiveNote(correctionRow.modelData.id)
                        Text {
                          visible: !correctionRow.entry.excluded && correctionRow.entry.status === "done" && correctionRow.usesGrid
                          text: "Note : " + (correctionRow.effectiveNote.severe || "—") + " / 20"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
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
                            visible: !correctionRow.entry.excluded && correctionRow.entry.status === "running"
                            text: "⏹ Stopper"
                            bordered: true
                            foreground: root.foreground
                            accent: Color.urgent
                            // Stops the run in progress AND drops everything
                            // still queued behind it — see cancelCorrectionRun()
                            // and Gabriel, 2026-09-27 (a batch launched by
                            // mistake had no way to be stopped short of
                            // killing the underlying process by hand).
                            onClicked: root.cancelCorrectionRun()
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
                            visible: !correctionRow.entry.excluded && correctionRow.usesGrid
                            text: "🧩 Compétences"
                            bordered: true
                            foreground: root.foreground
                            accent: root.accent
                            onClicked: root.openCompetencyGridPopover(correctionRow.modelData.id)
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
                        ? root.activeClass().students.map(function(s) { return { value: s.id, label: (root.evaluationStudentDone(s) ? "✅ " : "") + Store.studentLabel(s) } })
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

                  Dropdown {
                    visible: root.activeEvaluationGrid() !== null
                    label: "Barème"
                    width: Style.space(100)
                    options: [{ value: "20", label: "/ 20" }, { value: "10", label: "/ 10" }]
                    value: String(root.evaluationBaremeTotal())
                    foreground: root.foreground
                    background: root.background
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onChanged: function(v) { root.setEvaluationBaremeTotal(v) }
                  }

                  // Wrapped in a plain Item, same pattern as "🪄 Générer
                  // l'appréciation" elsewhere in this file — a Flow doesn't
                  // allow anchoring its own direct children (breaks the
                  // Flow's positioning entirely, not just this button), so
                  // the anchor goes on an inner Item instead.
                  Item {
                    width: evalWeightsButton.implicitWidth
                    height: evaluationGridDropdown.implicitHeight
                    visible: root.activeEvaluationGrid() !== null
                    Button {
                      id: evalWeightsButton
                      anchors.bottom: parent.bottom
                      text: "⚖️ Répartir les points par critère"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: root.openEvaluationWeightsPopover()
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
                    text: "Annotations"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    text: "Notes libres prises en lisant la copie — base, avec la grille, de \"🧠 Générer une appréciation\" ci-dessous. Deux colonnes séparées (Gabriel, 2026-10-02) pour plus de précision."
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.md

                    Column {
                      width: (parent.width - Style.spacing.md) / 2
                      spacing: Style.spacing.xxs

                      Text {
                        text: "Points positifs"
                        color: Qt.darker(root.foreground, 1.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Rectangle {
                        width: parent.width
                        height: Style.space(100)
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
                            id: evaluationAnnotationsPositifField
                            wrapMode: TextArea.Wrap
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            background: null
                            placeholderText: "Ce qui fonctionne…"
                            onTextChanged: root.queueEvaluationFieldsPersist()
                          }
                        }
                      }
                    }

                    Column {
                      width: (parent.width - Style.spacing.md) / 2
                      spacing: Style.spacing.xxs

                      Text {
                        text: "Points négatifs"
                        color: Qt.darker(root.foreground, 1.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Rectangle {
                        width: parent.width
                        height: Style.space(100)
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
                            id: evaluationAnnotationsNegatifField
                            wrapMode: TextArea.Wrap
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            background: null
                            placeholderText: "Ce qui doit progresser…"
                            onTextChanged: root.queueEvaluationFieldsPersist()
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
                      // No anchors here — see the "QML Flow-anchors gotcha"
                      // memory, same mistake fixed elsewhere in this tab
                      // 2026-10-01: a direct Flow child can't be anchored at
                      // all (confirmed live in journalctl, repeated "Cannot
                      // specify anchors for items inside Flow" warnings
                      // exactly matching Gabriel's "tout a disparu" report,
                      // 2026-10-02). Flow top-aligns by default, fine here
                      // since this label and the chips are similar height.
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

                  Row {
                    spacing: Style.spacing.xs

                    // Toujours la somme des points × palier cochés (jamais
                    // une valeur stockée/éditable à la main) — Gabriel,
                    // 2026-10-01. Changer le résultat passe par "⚖️ Répartir
                    // les points par critère" ci-dessus, pas par ce champ.
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Note : " + (root.evaluationComputedNote() || "—") + " / " + root.evaluationBaremeTotal()
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.evalGeneratingAppreciation ? "Génération…" : "🧠 Générer une appréciation"
                      bordered: true
                      enabled: !root.evalGeneratingAppreciation
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Remplace le texte actuel de l'Appréciation ci-dessus, à partir de la grille et des annotations"
                      onClicked: root.requestGenerateEvalAppreciation()
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.evalCheckingAppreciation ? "Vérification…" : "✓ Vérifier l'orthographe et la syntaxe"
                      bordered: true
                      enabled: !root.evalCheckingAppreciation
                      foreground: root.foreground
                      accent: root.accent
                      tooltipText: "Relit le texte actuel de l'Appréciation ci-dessus, sans le modifier"
                      onClicked: root.requestCheckAppreciation()
                    }
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

                  Text {
                    visible: root.evalCheckError !== ""
                    width: Style.space(320)
                    text: root.evalCheckError
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Text {
                    visible: root.evalCheckResult !== ""
                    width: Style.space(420)
                    text: root.evalCheckResult
                    color: root.evalCheckResult === "RAS" ? Qt.darker(root.foreground, 1.4) : root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                  }

                  Button {
                    visible: root.evalCheckResult !== "" && root.evalCheckResult !== "RAS"
                    text: root.evalApplyingFixes ? "Application…" : "✅ Appliquer les corrections"
                    bordered: true
                    enabled: !root.evalApplyingFixes
                    foreground: root.foreground
                    accent: root.accent
                    tooltipText: "Réécrit l'Appréciation ci-dessus en corrigeant uniquement les fautes listées ci-dessus"
                    onClicked: root.requestApplyAppreciationFixes()
                  }

                  Text {
                    visible: root.evalApplyFixesError !== ""
                    width: Style.space(320)
                    text: root.evalApplyFixesError
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
                    text: "📋 Copier le code markdown"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.copyEvaluationMarkdown()
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

              // ======================================= assistant de correction

              Column {
                visible: root.activeFeatureTab === "assistant"
                width: parent.width
                spacing: Style.spacing.huge

                Text {
                  text: "Assistant de correction"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: "Un outil de soutien, pas une correction automatique : il ne propose ni note ni appréciation, seulement des observations ponctuelles sur une copie — à vous de lire et juger. Lecture seule, n'écrit jamais rien sur la copie elle-même."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Column {
                  width: parent.width
                  spacing: Style.spacing.xxs
                  Text { text: "Copie à analyser (PDF ou PNG)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  TextField {
                    id: assistantCopyField
                    width: parent.width
                    text: root.assistantCopyPath
                    placeholderText: "chemin du fichier .pdf ou .png…"
                    foreground: root.foreground
                    accent: root.accent
                    maximumLength: 2000
                    onTextChanged: root.assistantCopyPath = text
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.spacing.xs
                  Text { text: "Éléments de repérage"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }

                  Toggle {
                    width: parent.width
                    label: "Statistiques des fautes d'expression écrite par type"
                    checked: root.assistantCheckFautes
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.assistantCheckFautes = !root.assistantCheckFautes
                  }
                  Toggle {
                    width: parent.width
                    label: "Extraction du plan détaillé (problématique, axes, sous-parties)"
                    checked: root.assistantCheckPlan
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.assistantCheckPlan = !root.assistantCheckPlan
                  }
                  Toggle {
                    width: parent.width
                    label: "Analyse de la mise en page"
                    checked: root.assistantCheckMiseEnPage
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.assistantCheckMiseEnPage = !root.assistantCheckMiseEnPage
                  }
                  Toggle {
                    width: parent.width
                    label: "Analyse de l'introduction et de la conclusion"
                    checked: root.assistantCheckIntroConclusion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.assistantCheckIntroConclusion = !root.assistantCheckIntroConclusion
                  }
                }

                Row {
                  spacing: Style.spacing.controlGap
                  Button {
                    text: root.assistantRunning ? "Analyse en cours…" : "🔎 Lancer l'analyse"
                    bordered: true
                    enabled: !root.assistantRunning
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.requestRunCorrectionAssistant()
                  }
                  Button {
                    visible: root.assistantResult !== ""
                    text: "📋 Copier le résultat"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: root.copyAssistantResult()
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.assistantCopyFeedback !== ""
                    text: root.assistantCopyFeedback
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Text {
                  visible: root.assistantError !== ""
                  width: parent.width
                  text: root.assistantError
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                }

                // Résultat — défilant, hauteur bornée plutôt qu'illimitée
                // (un relevé de fautes détaillé sur une longue copie peut
                // être long) : même esprit que les autres zones de texte
                // défilantes de ce fichier.
                Rectangle {
                  visible: root.assistantResult !== "" || root.assistantRunning
                  width: parent.width
                  height: Style.space(320)
                  radius: Style.cornerRadius
                  color: Style.normalFillFor(root.foreground, root.accent)
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
                  border.width: 1
                  clip: true

                  ScrollView {
                    id: assistantResultScroll
                    anchors.fill: parent
                    anchors.margins: Style.space(10)
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    Text {
                      width: assistantResultScroll.availableWidth
                      text: root.assistantRunning ? "Analyse en cours…" : root.assistantResult
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WordWrap
                      textFormat: Text.PlainText
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
        currentAgentPath: root.agentPath
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onDirConfirmed: function(dir) { root.confirmSyncDir(dir) }
        onDirCleared: root.clearSyncDir()
        onAgentConfirmed: function(path) { root.setAgentPath(path) }
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

      CompetencyGridPopover {
        anchors.fill: parent
        opened: root.competencyGridPopoverStudentId !== ""
        studentLabel: root.competencyGridPopoverStudentLabel()
        grid: root.competencyGridPopoverGrid()
        checks: root.competencyGridPopoverEntry().competencyChecks
        justifications: root.competencyGridPopoverEntry().competencyJustifications
        appreciation: root.competencyGridPopoverEntry().appreciation
        note: root.competencyEffectiveNote(root.competencyGridPopoverStudentId).severe
        liveNote: root.competencyLiveNote(root.competencyGridPopoverStudentId).severe
        hasNoteOverride: root.competencyGridPopoverEntry().noteSevere !== "" || root.competencyGridPopoverEntry().noteBienveillante !== ""
        copyPath: root.competencyGridPopoverEntry().copyPath
        regenerating: root.correctionRunningStudentId !== "" && root.correctionRunningStudentId === root.competencyGridPopoverStudentId
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeCompetencyGridPopover()
        onCheckChanged: function(rowIndex, colIndex) { root.setCompetencyCheck(rowIndex, colIndex) }
        onAppreciationSaved: function(text) { root.saveCompetencyAppreciation(root.competencyGridPopoverStudentId, text) }
        onNoteSaved: function(note) { root.saveCompetencyNote(root.competencyGridPopoverStudentId, note) }
        onRegenerateRequested: function(addendum, length) { root.requestRegenerateCompetencyAppreciation(root.competencyGridPopoverStudentId, addendum, length) }
        onResetNoteOverrideRequested: root.resetCompetencyNoteOverride(root.competencyGridPopoverStudentId)
        onCopyOpenRequested: root.openCompetencyGridCopy()
        onExportRequested: function(includeJustifications) { root.requestExportCompetencyPdf(root.competencyGridPopoverStudentId, includeJustifications) }
      }

      CriteriaWeightsPopover {
        anchors.fill: parent
        opened: root.correctionWeightsPopoverOpen
        grid: root.activeEvaluation() ? CompetencyGrids.findGrid(root.activeEvaluation().gridId) : null
        weights: root.activeEvaluation() ? root.activeEvaluation().criteriaWeights : ({})
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeWeightsPopover()
        onWeightChanged: function(rowIndex, points) { root.setCriteriaWeight(rowIndex, points) }
        onResetRequested: root.resetCriteriaWeights()
      }

      CriteriaWeightsPopover {
        anchors.fill: parent
        opened: root.correctionDraftWeightsPopoverOpen
        grid: root.correctionDraftGridId ? CompetencyGrids.findGrid(root.correctionDraftGridId) : null
        weights: root.correctionDraftWeights
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeDraftWeightsPopover()
        onWeightChanged: function(rowIndex, points) { root.setDraftWeight(rowIndex, points) }
        onResetRequested: root.correctionDraftWeights = {}
      }

      CriteriaWeightsPopover {
        anchors.fill: parent
        opened: root.evaluationWeightsPopoverOpen
        grid: root.activeEvaluationGrid()
        weights: root.evaluationWeights()
        total: root.evaluationBaremeTotal()
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onCanceled: root.closeEvaluationWeightsPopover()
        onWeightChanged: function(rowIndex, points) { root.setEvaluationWeight(rowIndex, points) }
        onResetRequested: root.resetEvaluationWeights()
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

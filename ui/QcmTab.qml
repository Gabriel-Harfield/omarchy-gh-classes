import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../lib/QcmStore.js" as QcmStore
import "../lib/QcmPromptBuilder.js" as QcmPromptBuilder
import "../lib/ClaudeRunner.js" as ClaudeRunner

// Onglet « Questionnaire » : correction de QCM scannés (Gabriel, 2026-11-05).
//
// Chaîne : versions.json (la clé produite par le générateur de QCM) + scan
// (un PDF de toute la pile, ou un dossier de PDF) → pdftoppm découpe en une
// image par page → un appel claude par page (modèle réglable, outil Read
// SEUL) qui LIT version, nom et case cochée de chaque question → ce fichier
// calcule la note (2 points par bonne réponse sur 20, aucune pénalité) →
// tableau de relecture où chaque case se corrige d'un clic → export CSV.
//
// L'agent ne note jamais : il ne fait que lire (même principe que le
// pipeline « Questionnaire » de l'onglet Corrections).
Column {
  id: root

  // fournis par Panel.qml
  property string classId: ""
  property string className: ""
  property var students: []        // [{ id, nom, prenom }]
  property string stateDir: ""
  property string homeDir: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  width: parent ? parent.width : 600
  spacing: Style.spacing.md

  readonly property int parallelWorkers: 3

  // ---- état persisté (une entrée par classe) --------------------------------

  property var store: ({})
  property bool storeLoaded: false

  FileView {
    id: qcmFile
    path: root.stateDir !== "" ? root.stateDir + "/qcm.json" : ""
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: { root.store = QcmStore.parseState(qcmFile.text()); root.storeLoaded = true; root.reloadKey() }
    onLoadFailed: { root.store = ({}); root.storeLoaded = true }
  }

  function persist() { if (root.storeLoaded) qcmFile.setText(QcmStore.serializeState(root.store)) }

  function cstate() {
    var s = root.store[root.classId]
    return s ? s : QcmStore.emptyClassState()
  }

  // Modifie l'état d'UNE classe (celle du travail en cours, pas forcément la
  // classe affichée) puis persiste.
  function mutate(classId, fn) {
    if (!classId) return
    var st = JSON.parse(JSON.stringify(root.store))
    if (!st[classId]) st[classId] = QcmStore.emptyClassState()
    fn(st[classId])
    root.store = st
    root.persist()
  }

  function copies() { return root.cstate().copies || [] }

  onClassIdChanged: { root.message = ""; root.confirmReset = false; root.reloadKey() }

  // ---- clé (versions.json) ----------------------------------------------------

  property var key: null
  property string keyError: ""
  property string keyPathInput: ""

  FileView {
    id: keyFile
    watchChanges: false
    printErrors: false
    onLoaded: {
      var parsed = QcmStore.parseVersions(keyFile.text())
      if (parsed.ok) { root.key = parsed; root.keyError = "" }
      else { root.key = null; root.keyError = parsed.error }
    }
    onLoadFailed: { root.key = null; root.keyError = "Impossible de lire " + keyFile.path }
  }

  function expandPath(p) {
    var t = String(p || "").trim()
    if (t === "~") return root.homeDir
    if (t.indexOf("~/") === 0) return root.homeDir + t.slice(1)
    return t
  }

  function reloadKey() {
    root.key = null
    root.keyError = ""
    var p = root.cstate().versionsPath || ""
    root.keyPathInput = p
    keyFile.path = p
  }

  function loadKey() {
    var p = root.expandPath(root.keyPathInput)
    if (p.charAt(0) !== "/") { root.keyError = "Indiquez le chemin complet de versions.json."; return }
    root.mutate(root.classId, function(c) { c.versionsPath = p })
    keyFile.path = ""
    keyFile.path = p
  }

  readonly property int nOptions: {
    var n = 5
    if (root.key) {
      for (var k in root.key.versions) {
        var its = root.key.versions[k].items
        for (var i = 0; i < its.length; i++) n = Math.max(n, its[i].nOptions || 0)
        break
      }
    }
    return n
  }

  // ---- découpage du scan en pages ------------------------------------------------

  property string scanInput: ""
  property string message: ""
  property bool splitting: false
  property bool confirmReset: false
  property string _splitClassId: ""

  function runDir(classId) { return root.stateDir + "/qcm-runs/" + String(classId).replace(/[^A-Za-z0-9_-]/g, "_") }

  function startSplit() {
    var src = root.expandPath(root.scanInput)
    if (src.charAt(0) !== "/") { root.message = "Indiquez le chemin complet du scan (PDF ou dossier de PDF)."; return }
    if (!root.key) { root.message = "Chargez d'abord la clé (versions.json)."; return }
    root.message = ""
    root.splitting = true
    root._splitClassId = root.classId
    splitProc.command = ["bash", "-c",
      "set -e; in=\"$1\"; out=\"$2\"; case \"$out\" in */qcm-runs/*) ;; *) exit 2;; esac\n" +
      "rm -rf -- \"$out\"; mkdir -p -- \"$out\"; n=0\n" +
      "if [ -d \"$in\" ]; then\n" +
      "  for f in \"$in\"/*.pdf \"$in\"/*.PDF; do [ -f \"$f\" ] || continue; n=$((n+1)); pdftoppm -r 130 -png -- \"$f\" \"$out/$(printf %03d $n)-p\"; done\n" +
      "else pdftoppm -r 130 -png -- \"$in\" \"$out/001-p\"; fi\n" +
      "find \"$out\" -maxdepth 1 -name '*.png' | sort",
      "qcmsplit", src, root.runDir(root.classId)]
    splitProc.running = false
    splitProc.running = true
  }

  Process {
    id: splitProc
    stdout: StdioCollector { id: splitOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.splitting = false
      var cid = root._splitClassId
      var files = String(splitOut.text || "").split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l !== "" })
      if (exitCode !== 0 || files.length === 0) {
        root.message = "Le découpage du scan a échoué (fichier introuvable, ou PDF illisible ?)."
        return
      }
      root.mutate(cid, function(c) {
        c.source = root.expandPath(root.scanInput)
        c.copies = files.map(function(f, i) {
          return { id: "p" + (i + 1), file: f, status: "pending", error: "", version: 0, studentId: "",
                   nomLu: "", prenomLu: "", match: "none", answers: [], remarks: [], edited: false }
        })
      })
      root.message = files.length + " page(s) prête(s). Lancez la lecture."
    }
  }

  function resetClass() {
    var cid = root.classId
    root.stopReading()
    root.mutate(cid, function(c) { c.copies = []; c.source = "" })
    root.confirmReset = false
    root.message = "Résultats effacés pour cette classe."
  }

  // ---- lecture par l'agent (file d'attente + ouvriers) -------------------------------

  property string model: "sonnet"
  property var queue: []            // [{ classId, copyId }]
  property int pendingTotal: 0
  property bool reading: false

  function countStatus(st) {
    var n = 0, list = root.copies()
    for (var i = 0; i < list.length; i++) if (list[i].status === st) n++
    return n
  }

  function startReading(onlyMissing) {
    if (!root.key) { root.message = "Chargez d'abord la clé (versions.json)."; return }
    var q = []
    var list = root.copies()
    for (var i = 0; i < list.length; i++) {
      var st = list[i].status
      if (st === "pending" || st === "error" || (!onlyMissing && st === "reading")) q.push({ classId: root.classId, copyId: list[i].id })
    }
    if (q.length === 0) { root.message = "Aucune page à lire."; return }
    root.queue = q
    root.pendingTotal = q.length
    root.reading = true
    root.message = ""
    root.pump()
  }

  function stopReading() {
    root.queue = []
    root.reading = false
  }

  function findCopy(classId, copyId) {
    var s = root.store[classId]
    if (!s) return null
    for (var i = 0; i < s.copies.length; i++) if (s.copies[i].id === copyId) return s.copies[i]
    return null
  }

  function pump() {
    var workers = [worker0, worker1, worker2]
    for (var i = 0; i < workers.length; i++) {
      if (root.queue.length === 0) break
      if (workers[i].busy) continue
      var job = root.queue[0]
      root.queue = root.queue.slice(1)
      var c = root.findCopy(job.classId, job.copyId)
      if (!c) continue
      root.mutate(job.classId, function(cs) {
        for (var k = 0; k < cs.copies.length; k++) if (cs.copies[k].id === job.copyId) { cs.copies[k].status = "reading"; cs.copies[k].error = "" }
      })
      var prompt = QcmPromptBuilder.buildReadPrompt(c.file, root.key.nQuestions, root.nOptions)
      var cmd = ["timeout", "-k", "5", "240"].concat(ClaudeRunner.buildCheckCommand(prompt, { model: root.model, effort: "low" }))
      workers[i].start(job.classId, job.copyId, cmd)
    }
    var anyBusy = worker0.busy || worker1.busy || worker2.busy
    if (root.queue.length === 0 && !anyBusy) root.reading = false
  }

  function onWorkerFinished(classId, copyId, ok, text) {
    var nQ = root.key ? root.key.nQuestions : 10
    var parsed = ok ? QcmStore.parseAgentOutput(text, nQ) : { ok: false, error: "L'agent n'a pas répondu (délai dépassé ou erreur)." }
    root.mutate(classId, function(cs) {
      for (var k = 0; k < cs.copies.length; k++) {
        var c = cs.copies[k]
        if (c.id !== copyId) continue
        if (!parsed.ok) { c.status = "error"; c.error = parsed.error; break }
        c.status = "done"; c.error = ""
        c.version = parsed.version
        c.nomLu = parsed.nom; c.prenomLu = parsed.prenom
        c.answers = parsed.answers; c.remarks = parsed.remarks
        var m = QcmStore.matchStudent(root.students, parsed.nom, parsed.prenom)
        c.studentId = m.id; c.match = m.level
        break
      }
    })
    root.pump()
  }

  QcmWorker { id: worker0; onFinished: function(a, b, c, d) { root.onWorkerFinished(a, b, c, d) } }
  QcmWorker { id: worker1; onFinished: function(a, b, c, d) { root.onWorkerFinished(a, b, c, d) } }
  QcmWorker { id: worker2; onFinished: function(a, b, c, d) { root.onWorkerFinished(a, b, c, d) } }

  // ---- correction manuelle ------------------------------------------------------------

  function setField(copyId, fn) {
    root.mutate(root.classId, function(cs) {
      for (var k = 0; k < cs.copies.length; k++) if (cs.copies[k].id === copyId) { fn(cs.copies[k]); cs.copies[k].edited = true; break }
    })
  }

  function cycleAnswer(copyId, index) {
    var order = [""]
    for (var i = 0; i < root.nOptions; i++) order.push(QcmStore.LETTERS.charAt(i))
    root.setField(copyId, function(c) {
      var cur = (c.answers && c.answers[index]) || ""
      var next = order[(order.indexOf(cur) + 1) % order.length]
      if (!c.answers || c.answers.length === 0) { c.answers = []; for (var q = 0; q < root.key.nQuestions; q++) c.answers.push("") }
      c.answers[index] = next
    })
  }

  // ---- infos dérivées par copie ----------------------------------------------------------

  function versionOf(c) { return root.key && c.version ? root.key.versions[c.version] : null }

  function scoreOf(c) {
    var v = root.versionOf(c)
    return v ? QcmStore.scoreCopy(v, c.answers || [], root.key.pts) : null
  }

  function studentName(id) {
    for (var i = 0; i < root.students.length; i++)
      if (root.students[i].id === id) return String(root.students[i].nom).toUpperCase() + " " + root.students[i].prenom
    return ""
  }

  function duplicateIds() {
    var seen = {}, dup = {}, list = root.copies()
    for (var i = 0; i < list.length; i++) {
      var id = list[i].studentId
      if (!id) continue
      if (seen[id]) dup[id] = true
      seen[id] = true
    }
    return dup
  }

  function issuesOf(c, dups) {
    var out = []
    if (c.status === "error") { out.push("lecture échouée : " + c.error); return out }
    if (c.status !== "done") return out
    var v = root.versionOf(c)
    if (!v) out.push(c.version ? "version " + c.version + " inconnue de la clé" : "version illisible")
    else if (root.className && v.classe && QcmStore.normalize(v.classe) !== QcmStore.normalize(root.className)
             && QcmStore.normalize(root.className).indexOf(QcmStore.normalize(v.classe)) !== 0)
      out.push("version de la classe " + v.classe)
    if (!c.studentId) out.push("élève non reconnu (« " + (c.nomLu + " " + c.prenomLu).trim() + " »)")
    else if (c.match === "maybe" && !c.edited) out.push("élève à confirmer")
    else if (dups[c.studentId]) out.push("élève présent sur deux copies")
    var blanks = 0, noted = 0
    for (var i = 0; i < (c.answers || []).length; i++) {
      if (c.answers[i] === "") blanks++
      if (c.remarks && c.remarks[i]) noted++
    }
    if (blanks > 0) out.push(blanks + " question(s) sans réponse lue")
    if (noted > 0) out.push(noted + " remarque(s) de lecture")
    return out
  }

  // Copies sans élève affecté d'abord (à traiter en premier, dans l'ordre de la
  // pile), puis les autres par ordre alphabétique de l'élève.
  function sortedEntries() {
    var list = root.copies(), out = []
    for (var i = 0; i < list.length; i++) out.push({ copy: list[i], page: i + 1 })
    out.sort(function(a, b) {
      var ua = a.copy.studentId ? 1 : 0, ub = b.copy.studentId ? 1 : 0
      if (ua !== ub) return ua - ub
      if (!ua) return a.page - b.page
      var x = QcmStore.normalize(root.studentName(a.copy.studentId)), y = QcmStore.normalize(root.studentName(b.copy.studentId))
      return x < y ? -1 : (x > y ? 1 : a.page - b.page)
    })
    return out
  }

  // Résumé en tête de tableau.
  function summaryText() {
    var list = root.copies(), dups = root.duplicateIds()
    var recognized = 0, toCheck = 0, assigned = {}
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (c.studentId) { recognized++; if (c.status === "done") assigned[c.studentId] = true }
      if (c.status !== "done" || root.issuesOf(c, dups).length > 0) toCheck++
    }
    var absent = []
    for (var s = 0; s < root.students.length; s++)
      if (!assigned[root.students[s].id]) absent.push(String(root.students[s].nom).toUpperCase() + " " + root.students[s].prenom)
    absent.sort()
    return list.length + " copie(s) · " + recognized + " avec un élève affecté · " + toCheck + " à vérifier"
      + " · sans copie (" + absent.length + ") : " + (absent.length ? absent.join(", ") : "aucun")
  }

  function openCopy(path) {
    if (!path) return
    viewProc.command = ["xdg-open", String(path)]
    viewProc.running = false
    viewProc.running = true
  }

  Process { id: viewProc }

  // ---- export CSV ------------------------------------------------------------------------

  property string exportPath: ""
  property string exportedPath: ""

  FileView {
    id: csvFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root.exportedPath = csvFile.path
  }

  function slug(s) { return String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") }

  function defaultExportPath() {
    var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
    return root.homeDir + "/Downloads/qcm-" + root.slug(root.className) + "-" + ts + ".csv"
  }

  function exportCsv() {
    var dest = root.expandPath(root.exportPath !== "" ? root.exportPath : root.defaultExportPath())
    if (dest.charAt(0) !== "/") { root.message = "Chemin d'export invalide."; return }
    var byStudent = {}, list = root.copies()
    for (var i = 0; i < list.length; i++) if (list[i].studentId && list[i].status === "done") byStudent[list[i].studentId] = list[i]
    var rows = []
    var sorted = root.students.slice().sort(function(a, b) {
      var x = QcmStore.normalize(a.nom + a.prenom), y = QcmStore.normalize(b.nom + b.prenom)
      return x < y ? -1 : (x > y ? 1 : 0)
    })
    for (var s = 0; s < sorted.length; s++) {
      var st = sorted[s], c = byStudent[st.id]
      var sc = c ? root.scoreOf(c) : null
      rows.push({ classe: root.className, eleve: String(st.nom).toUpperCase() + " " + st.prenom,
                  version: c && c.version ? c.version : "", bonnes: sc ? sc.correct : "",
                  note: sc ? QcmStore.formatPoints(sc.points) : "" })
    }
    root.exportedPath = ""
    csvFile.path = dest
    var csv = QcmStore.buildCsv(root.key ? root.key.titre : "QCM", rows)
    Qt.callLater(function() { csvFile.setText(csv) })
  }

  // =============================================================================
  // Interface
  // =============================================================================

  Text {
    text: "Correction de questionnaire (QCM)"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }

  Text {
    width: parent.width
    text: "Chargez la clé du QCM (versions.json, produite par le générateur), puis le scan des copies (un PDF de toute la pile, ou un dossier de PDF). L'agent lit seulement la version, le nom et la case cochée de chaque question ; la note (2 points par bonne réponse) est calculée ici. Vous relisez ensuite le tableau, où chaque case se corrige d'un clic."
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // ---- 1. clé ----

  Column {
    width: parent.width
    spacing: Style.spacing.xxs
    Text { text: "1. Clé du QCM (versions.json)"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    Row {
      width: parent.width
      spacing: Style.spacing.controlGap
      TextField {
        width: parent.width - Style.space(130)
        placeholderText: "/chemin/vers/versions.json"
        foreground: root.foreground
        accent: root.accent
        text: root.keyPathInput
        onTextChanged: root.keyPathInput = text
        onAccepted: root.loadKey()
      }
      Button {
        text: "Charger"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        onClicked: root.loadKey()
      }
    }
    Text {
      width: parent.width
      visible: root.key !== null || root.keyError !== ""
      text: root.key
        ? "✓ " + Object.keys(root.key.versions).length + " versions, " + root.key.nQuestions + " questions, "
          + QcmStore.formatPoints(root.key.pts) + " pt par bonne réponse · versions de cette classe : " + QcmStore.versionsOfClass(root.key, root.className).length
        : root.keyError
      color: root.key ? Qt.darker(root.foreground, 1.4) : "#d9534f"
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // ---- 2. scan ----

  Column {
    width: parent.width
    spacing: Style.spacing.xxs
    Text { text: "2. Scan des copies"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    Row {
      width: parent.width
      spacing: Style.spacing.controlGap
      TextField {
        width: parent.width - Style.space(190)
        placeholderText: "/chemin/vers/scan.pdf (ou un dossier de PDF)"
        foreground: root.foreground
        accent: root.accent
        text: root.scanInput
        onTextChanged: root.scanInput = text
        onAccepted: root.startSplit()
      }
      Button {
        text: root.splitting ? "Découpage…" : "✂ Découper en pages"
        bordered: true
        enabled: !root.splitting && root.copies().length === 0 && !root.reading
        foreground: root.foreground
        accent: root.accent
        onClicked: root.startSplit()
      }
    }
    Text {
      visible: root.copies().length > 0
      width: parent.width
      text: root.copies().length + " page(s) · lues : " + root.countStatus("done") + " · en cours : " + root.countStatus("reading")
        + " · en attente : " + root.countStatus("pending") + " · en erreur : " + root.countStatus("error")
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // ---- 3. lecture ----

  Column {
    visible: root.copies().length > 0
    width: parent.width
    spacing: Style.spacing.xxs
    Text { text: "3. Lecture par l'agent"; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    Row {
      width: parent.width
      spacing: Style.spacing.controlGap
      Dropdown {
        width: Style.space(220)
        options: [
          { value: "sonnet", label: "Sonnet (rapide, économique)" },
          { value: "opus", label: "Opus (plus sûr, plus coûteux)" }
        ]
        value: root.model
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        onChanged: function(v) { root.model = v }
      }
      Button {
        text: root.reading ? "Lecture en cours…" : "▶ Lire les pages en attente (" + (root.countStatus("pending") + root.countStatus("error")) + " appel(s))"
        bordered: true
        enabled: !root.reading && (root.countStatus("pending") + root.countStatus("error")) > 0 && root.key !== null
        foreground: root.foreground
        accent: root.accent
        onClicked: root.startReading(true)
      }
      Button {
        visible: root.reading
        text: "⏹ Arrêter"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        onClicked: root.stopReading()
      }
    }
    Text {
      width: parent.width
      text: "Un appel par page (3 en parallèle), l'outil Read seul : l'agent ne peut rien écrire ni exécuter. Les pages déjà lues ne sont jamais relancées."
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  Text {
    visible: root.message !== ""
    width: parent.width
    text: root.message
    color: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // ---- 4. résultats ----

  Column {
    id: results
    visible: root.copies().length > 0
    width: parent.width
    spacing: Style.spacing.sm

    PanelSeparator { foreground: root.foreground; width: parent.width }
    Text { text: "4. Relecture et notes"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
    Text {
      width: parent.width
      text: root.summaryText()
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
    Text {
      width: parent.width
      text: "Classement : copies sans élève reconnu d'abord, puis ordre alphabétique des élèves."
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.sortedEntries()

      delegate: Rectangle {
        id: row
        readonly property var copy: modelData.copy
        readonly property var info: root.scoreOf(copy)
        readonly property var issues: root.issuesOf(copy, root.duplicateIds())
        width: results.width
        height: rowCol.implicitHeight + Style.space(12)
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
        border.width: issues.length > 0 ? 1 : 0
        border.color: "#d9a441"

        Column {
          id: rowCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(6)
          spacing: Style.spacing.xxs

          Row {
            spacing: Style.spacing.controlGap
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Page " + modelData.page
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: Style.space(52)
            }
            Dropdown {
              width: Style.space(230)
              options: [{ value: "", label: "— élève ? —" }].concat(root.students.slice().sort(function(a, b) {
                var x = QcmStore.normalize(a.nom + a.prenom), y = QcmStore.normalize(b.nom + b.prenom)
                return x < y ? -1 : (x > y ? 1 : 0)
              }).map(function(s) { return { value: s.id, label: String(s.nom).toUpperCase() + " " + s.prenom } }))
              value: row.copy.studentId
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.setField(row.copy.id, function(c) { c.studentId = v; c.match = v ? "sure" : "none" }) }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "version"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            TextField {
              width: Style.space(64)
              foreground: root.foreground
              accent: root.accent
              text: row.copy.version ? String(row.copy.version) : ""
              validator: IntValidator { bottom: 0; top: 9999 }
              onEditingFinished: {
                var n = parseInt(text)
                root.setField(row.copy.id, function(c) { c.version = n > 0 ? n : 0 })
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.info !== null
              text: row.info ? ("→ " + QcmStore.formatPoints(row.info.points) + " / 20  (" + row.info.correct + "/" + row.info.total + ")") : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.copy.status === "reading" || row.copy.status === "pending"
              text: row.copy.status === "reading" ? "lecture…" : "en attente"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // cases : une par question, cliquables
          Flow {
            visible: row.copy.status === "done"
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: row.info ? row.info.detail : []
              delegate: Rectangle {
                readonly property var d: modelData
                width: Style.space(46)
                height: Style.space(34)
                radius: Style.cornerRadius
                color: d.given === "" ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                  : (d.ok ? Qt.rgba(0.25, 0.65, 0.35, 0.28) : Qt.rgba(0.85, 0.30, 0.28, 0.28))
                Column {
                  anchors.centerIn: parent
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: d.n + ". " + (d.given === "" ? "–" : d.given)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !d.ok
                    text: "→ " + d.expected
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cycleAnswer(row.copy.id, d.n - 1)
                }
              }
            }
          }

          Row {
            spacing: Style.spacing.controlGap
            Button {
              text: "🖼 Voir la copie"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: root.openCopy(row.copy.file)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.copy.status === "done" && row.copy.nomLu !== ""
              text: "Lu sur la copie : « " + (row.copy.nomLu + " " + row.copy.prenomLu).trim() + " »"
              color: Qt.darker(root.foreground, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            visible: row.issues.length > 0
            width: parent.width
            text: "⚠ " + row.issues.join(" · ")
            color: "#d9a441"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            readonly property string remarkText: {
              var out = [], r = row.copy.remarks || []
              for (var i = 0; i < r.length; i++) if (r[i]) out.push("Q" + (i + 1) + " : " + r[i])
              return out.join(" · ")
            }
            visible: remarkText !== ""
            width: parent.width
            text: remarkText
            color: Qt.darker(root.foreground, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    // ---- export + remise à zéro ----

    PanelSeparator { foreground: root.foreground; width: parent.width }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap
      TextField {
        width: parent.width - Style.space(250)
        placeholderText: root.defaultExportPath()
        foreground: root.foreground
        accent: root.accent
        text: root.exportPath
        onTextChanged: root.exportPath = text
      }
      Button {
        text: "📊 Exporter les notes (.csv)"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        onClicked: root.exportCsv()
      }
    }
    Text {
      visible: root.exportedPath !== ""
      text: "Exporté : " + root.exportedPath
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WrapAnywhere
      width: parent.width
    }

    Row {
      spacing: Style.spacing.controlGap
      Button {
        text: root.confirmReset ? "⚠ Confirmer : effacer toutes les lectures de cette classe" : "↺ Recommencer avec un autre scan"
        bordered: true
        enabled: !root.reading
        foreground: root.foreground
        accent: root.accent
        onClicked: { if (root.confirmReset) root.resetClass(); else root.confirmReset = true }
      }
      Button {
        visible: root.confirmReset
        text: "Annuler"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        onClicked: root.confirmReset = false
      }
    }
  }
}

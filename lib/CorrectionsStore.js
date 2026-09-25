// Persistence shapes + sanitizers for the "Corrections" feature tab.
//
// Kept in its own corrections.json (NOT inside classes.json / its sync):
// unlike a Class, an Evaluation is anchored to local, machine-specific
// filesystem paths (dossier du devoir, copies PDF) that have no meaning on
// another machine, so syncing it via GH Classes' existing folder-based
// mechanism would just import broken paths on the other side.
//
// corrections.json: { [classId]: Evaluation }
//   Evaluation: {
//     id, title, folderPath, sujetPath, corrigePath, consignesPath,
//     agentPath, createdAt,
//     exerciseType: "" | one of ExerciseTypes.TYPES,
//     natureEvaluation, typeEvaluation, dureeEpreuve, niveauClasse,
//     bienveillance (0-10 int), priseDeNotes, completudeExigee,
//     ecartSevereBienveillante, surinterpretation, niveauDetail, complements,
//       (see ConsignesBuilder.js — these are the évaluation-creation wizard's
//       own fields, used to auto-generate consignes.md at creation time; the
//       old, separate "Assistant — Consignes" popover is retired, Gabriel
//       2026-09-24),
//     writingMode, writingExceptions,
//     students: { [studentId]: StudentCorrection }
//   }
//   StudentCorrection: {
//     copyPath, appreciation, log, needsReview,
//     status: "idle" | "running" | "done" | "error",
//     error, reviewed,
//     grades: { severe, neutre, bienveillante }, selectedGrade,
//     addendum, excluded,
//     logItemStates: { "<itemIndex>": { status, comment } },
//     lisibilite: "" | "lisible" | "difficile" | "illisible"
//   }
//
// One evaluation per class at a time (creating a new one for a class
// replaces the previous one) — Panel.qml is responsible for confirming
// that destructive replacement with the user before calling setEvaluation.

.pragma library

var MAX_CLASSES_WITH_EVALUATIONS = 50
var MAX_STUDENTS_PER_EVALUATION = 200
var MAX_TITLE_LEN = 160
var MAX_PATH_LEN = 2000
var MAX_APPRECIATION_LEN = 20000
var MAX_LOG_LEN = 20000
var MAX_ERROR_LEN = 500
var MAX_GRADE_LEN = 40
var MAX_ADDENDUM_LEN = 4000
var MAX_LOG_ITEM_COMMENT_LEN = 500
var MAX_LOG_ITEMS = 60
var MAX_COMPLEMENTS_LEN = 4000
var STATUSES = ["idle", "running", "done", "error"]
// Evaluation-level wizard fields — see ConsignesBuilder.js/ExerciseTypes.js
// for the option labels/prose these values render as in consigne.md.
// "" is the default/unset state for exerciseType (no évaluation may be
// created without picking one, but sanitizeEvaluation() must still degrade
// gracefully on an évaluation saved before this field existed).
var EXERCISE_TYPES = ["", "commentaire", "dissertation", "lecture_analytique", "essai", "contraction", "ecriture_invention", "questionnaire_lecture", "resume"]
var NATURE_EVALUATIONS = ["tp_individuel", "tp_groupe", "dst", "bac_blanc"]
var TYPE_EVALUATIONS = ["diagnostique", "formative", "sommative"]
var NIVEAUX_CLASSE = ["2nde", "1ere", "terminale"]
var SURINTERPRETATIONS = ["strict", "neutre", "permissif"]
var NIVEAUX_DETAIL = ["faible", "moyen", "eleve"]
var GRADE_KEYS = ["severe", "neutre", "bienveillante"]
var SELECTABLE_GRADES = ["", "severe", "neutre", "bienveillante"]
var LOG_ITEM_STATUSES = ["pending", "validated", "ignored", "commented"]
// "" means no signal (ex. a correction done before this field existed, or a
// notes.txt the agent left unparseable) — never treated as "lisible" by
// display code, see Panel.qml's readability dot.
var LISIBILITE_LEVELS = ["", "lisible", "difficile", "illisible"]

function makeId() {
  return "corr-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
}

function clampStr(v, max) {
  return String(v === undefined || v === null ? "" : v).slice(0, max)
}

function oneOf(list, value, fallback) {
  return list.indexOf(value) !== -1 ? value : fallback
}

function clampInt(v, min, max, fallback) {
  var n = Math.round(Number(v))
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function clampReal(v, min, max, step, fallback) {
  var n = Number(v)
  if (isNaN(n)) return fallback
  n = Math.round(n / step) * step
  return Math.max(min, Math.min(max, n))
}

// Shared by sanitizeEvaluation() (reload from disk) and createEvaluation()
// (fresh évaluation) — see ConsignesBuilder.js for how these render into
// consigne.md, and Panel.qml's correctionDraft* properties for the
// évaluation-creation form fields these mirror.
function sanitizeEvaluationParams(e) {
  var src = (e && typeof e === "object") ? e : {}
  return {
    exerciseType: oneOf(EXERCISE_TYPES, src.exerciseType, ""),
    natureEvaluation: oneOf(NATURE_EVALUATIONS, src.natureEvaluation, "tp_individuel"),
    typeEvaluation: oneOf(TYPE_EVALUATIONS, src.typeEvaluation, "formative"),
    dureeEpreuve: clampInt(src.dureeEpreuve, 5, 600, 60),
    niveauClasse: oneOf(NIVEAUX_CLASSE, src.niveauClasse, "1ere"),
    bienveillance: clampInt(src.bienveillance, 0, 10, 5),
    priseDeNotes: !!src.priseDeNotes,
    completudeExigee: src.completudeExigee === undefined ? true : !!src.completudeExigee,
    ecartSevereBienveillante: clampReal(src.ecartSevereBienveillante, 0.5, 3, 0.5, 2),
    surinterpretation: oneOf(SURINTERPRETATIONS, src.surinterpretation, "neutre"),
    niveauDetail: oneOf(NIVEAUX_DETAIL, src.niveauDetail, "moyen"),
    complements: clampStr(src.complements, MAX_COMPLEMENTS_LEN)
  }
}

function emptyGrades() {
  return { severe: "", neutre: "", bienveillante: "" }
}

function sanitizeGrades(g) {
  var src = (g && typeof g === "object") ? g : {}
  var out = {}
  for (var i = 0; i < GRADE_KEYS.length; i++) out[GRADE_KEYS[i]] = clampStr(src[GRADE_KEYS[i]], MAX_GRADE_LEN)
  return out
}

function emptyStudentEntry() {
  return {
    copyPath: "", appreciation: "", log: "", needsReview: false, status: "idle", error: "", reviewed: false,
    grades: emptyGrades(), selectedGrade: "", addendum: "", excluded: false, logItemStates: {}, lisibilite: ""
  }
}

// logItemStates: { "<itemIndex>": { status, comment } } — Gabriel's own
// per-log-line triage (validé/ignoré/commenté), keyed by the item's
// position in parseLogItems(log) below. Naturally goes stale/irrelevant
// across a recorrection (a fresh log has different items at those
// indices) — Panel.qml resets it to {} whenever a correction completes.
function sanitizeLogItemStates(v) {
  var src = (v && typeof v === "object") ? v : {}
  var out = {}
  var count = 0
  for (var k in src) {
    if (count >= MAX_LOG_ITEMS) break
    var entry = (src[k] && typeof src[k] === "object") ? src[k] : {}
    var status = LOG_ITEM_STATUSES.indexOf(entry.status) !== -1 ? entry.status : "pending"
    out[k] = { status: status, comment: clampStr(entry.comment, MAX_LOG_ITEM_COMMENT_LEN) }
    count++
  }
  return out
}

// Splits log.md's raw text into discrete items — one per line starting
// with "-" or "*", the concise format CorrectionPromptBuilder.js now asks
// the agent for. A RAS log, or an older free-text log written before this
// format existed, just comes back as zero items — callers fall back to
// showing the raw text in that case.
function parseLogItems(logText) {
  var lines = String(logText || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (/^[-*]\s+/.test(line)) out.push(line.replace(/^[-*]\s+/, "").trim())
  }
  return out
}

function sanitizeStudentEntry(e) {
  if (!e || typeof e !== "object") return emptyStudentEntry()
  var status = STATUSES.indexOf(e.status) !== -1 ? e.status : "idle"
  return {
    copyPath: clampStr(e.copyPath, MAX_PATH_LEN),
    appreciation: clampStr(e.appreciation, MAX_APPRECIATION_LEN),
    log: clampStr(e.log, MAX_LOG_LEN),
    needsReview: !!e.needsReview,
    status: status,
    error: clampStr(e.error, MAX_ERROR_LEN),
    // Gabriel's own "I've looked at this one" mark — separate from
    // needsReview (which the agent sets): a review session can span
    // several days, so this is what lets him pick up where he left off
    // instead of re-reading every flagged copy from scratch each time.
    reviewed: !!e.reviewed,
    // Three proposed grades (sévère/neutre/bienveillante) the agent hands
    // back per copy, plus which one Gabriel actually clicked to validate
    // — see Gabriel, 2026-09-13. Kept as free-form strings (ex. "14/20",
    // "14,5/20") rather than numbers: no arithmetic is ever done on them,
    // only displayed and copied, so parsing them would only add a way to
    // reject a value the agent wrote in a slightly different format.
    grades: sanitizeGrades(e.grades),
    selectedGrade: SELECTABLE_GRADES.indexOf(e.selectedGrade) !== -1 ? e.selectedGrade : "",
    // One-shot context Gabriel can attach to a single copy before hitting
    // "Recorriger" (ex. "le mot que tu lis comme X est en fait Y") —
    // consumed after a successful re-run, not reapplied automatically on
    // later ones. See Gabriel, 2026-09-14: a recurring issue instead goes
    // into consignes.md/agent.md directly, not here.
    addendum: clampStr(e.addendum, MAX_ADDENDUM_LEN),
    // Gabriel pulling a student out of this évaluation by hand (ex. un
    // absent) — not permanent: refreshCorrectionCopies() clears it as soon
    // as a matching copy shows up for that student, see Panel.qml. Only
    // meaningful while copyPath is empty; see Gabriel, 2026-09-17.
    excluded: !!e.excluded,
    logItemStates: sanitizeLogItemStates(e.logItemStates),
    // Agent's self-reported reading-difficulty level for this copy, from
    // CorrectionPromptBuilder.parseLisibilite() — drives the readability
    // dot next to "Copier le code" in Panel.qml. See Gabriel, 2026-09-18.
    lisibilite: LISIBILITE_LEVELS.indexOf(e.lisibilite) !== -1 ? e.lisibilite : ""
  }
}

function sanitizeEvaluation(e) {
  if (!e || typeof e !== "object") return null
  var title = clampStr(e.title, MAX_TITLE_LEN).trim()
  if (!title) return null
  var params = sanitizeEvaluationParams(e)
  var studentsRaw = (e.students && typeof e.students === "object") ? e.students : {}
  var students = {}
  var count = 0
  for (var sid in studentsRaw) {
    if (count >= MAX_STUDENTS_PER_EVALUATION) break
    var cleanId = clampStr(sid, 80)
    if (!cleanId) continue
    students[cleanId] = sanitizeStudentEntry(studentsRaw[sid])
    count++
  }
  return {
    id: clampStr(e.id, 80) || makeId(),
    title: title,
    folderPath: clampStr(e.folderPath, MAX_PATH_LEN),
    sujetPath: clampStr(e.sujetPath, MAX_PATH_LEN),
    corrigePath: clampStr(e.corrigePath, MAX_PATH_LEN),
    consignesPath: clampStr(e.consignesPath, MAX_PATH_LEN),
    agentPath: clampStr(e.agentPath, MAX_PATH_LEN),
    createdAt: clampStr(e.createdAt, 40) || new Date().toISOString(),
    students: students,
    // Overall writing medium for this évaluation, plus the students whose
    // own copy is the OPPOSITE medium (ex. un aménagement dys) — see
    // Gabriel, 2026-09-13. Read by CorrectionPromptBuilder.js to tell the
    // agent how cautious to be about misreading a given copy.
    writingMode: e.writingMode === "tapuscrit" ? "tapuscrit" : "manuscrit",
    writingExceptions: sanitizeIdList(e.writingExceptions),
    exerciseType: params.exerciseType,
    natureEvaluation: params.natureEvaluation,
    typeEvaluation: params.typeEvaluation,
    dureeEpreuve: params.dureeEpreuve,
    niveauClasse: params.niveauClasse,
    bienveillance: params.bienveillance,
    priseDeNotes: params.priseDeNotes,
    completudeExigee: params.completudeExigee,
    ecartSevereBienveillante: params.ecartSevereBienveillante,
    surinterpretation: params.surinterpretation,
    niveauDetail: params.niveauDetail,
    complements: params.complements
  }
}

function sanitizeIdList(list) {
  var out = []
  var seen = {}
  var arr = Array.isArray(list) ? list : []
  for (var i = 0; i < arr.length && out.length < MAX_STUDENTS_PER_EVALUATION; i++) {
    var id = clampStr(arr[i], 80)
    if (id && !seen[id]) { seen[id] = true; out.push(id) }
  }
  return out
}

function parseCorrections(text) {
  try {
    var obj = JSON.parse(text || "{}")
    if (!obj || typeof obj !== "object") return {}
    var out = {}
    var count = 0
    for (var classId in obj) {
      if (count >= MAX_CLASSES_WITH_EVALUATIONS) break
      var cleanClassId = clampStr(classId, 80)
      if (!cleanClassId) continue
      var ev = sanitizeEvaluation(obj[classId])
      if (ev) { out[cleanClassId] = ev; count++ }
    }
    return out
  } catch (err) {
    return {}
  }
}

function serializeCorrections(map) {
  return JSON.stringify(map || {}, null, 2)
}

function getEvaluation(map, classId) {
  return (map && classId && map[classId]) ? map[classId] : null
}

function setEvaluation(map, classId, evaluation) {
  var out = {}
  for (var k in map) out[k] = map[k]
  out[classId] = evaluation
  return out
}

function deleteEvaluation(map, classId) {
  var out = {}
  for (var k in map) if (k !== classId) out[k] = map[k]
  return out
}

function createEvaluation(params) {
  var students = {}
  var ids = (params && params.studentIds) || []
  for (var i = 0; i < ids.length && i < MAX_STUDENTS_PER_EVALUATION; i++) students[ids[i]] = emptyStudentEntry()
  var ep = sanitizeEvaluationParams(params)
  return {
    id: makeId(),
    title: clampStr(params && params.title, MAX_TITLE_LEN).trim(),
    folderPath: clampStr(params && params.folderPath, MAX_PATH_LEN),
    sujetPath: clampStr(params && params.sujetPath, MAX_PATH_LEN),
    corrigePath: clampStr(params && params.corrigePath, MAX_PATH_LEN),
    consignesPath: clampStr(params && params.consignesPath, MAX_PATH_LEN),
    agentPath: clampStr(params && params.agentPath, MAX_PATH_LEN),
    createdAt: new Date().toISOString(),
    students: students,
    writingMode: (params && params.writingMode === "tapuscrit") ? "tapuscrit" : "manuscrit",
    writingExceptions: sanitizeIdList(params && params.writingExceptions),
    exerciseType: ep.exerciseType,
    natureEvaluation: ep.natureEvaluation,
    typeEvaluation: ep.typeEvaluation,
    dureeEpreuve: ep.dureeEpreuve,
    niveauClasse: ep.niveauClasse,
    bienveillance: ep.bienveillance,
    priseDeNotes: ep.priseDeNotes,
    completudeExigee: ep.completudeExigee,
    ecartSevereBienveillante: ep.ecartSevereBienveillante,
    surinterpretation: ep.surinterpretation,
    niveauDetail: ep.niveauDetail,
    complements: ep.complements
  }
}

// Returns a NEW evaluation with its writing-mode settings replaced (the
// evaluation-level fields, not any per-student entry).
function withWritingSettings(evaluation, mode, exceptionIds) {
  var out = {}
  for (var k in evaluation) out[k] = evaluation[k]
  out.writingMode = mode === "tapuscrit" ? "tapuscrit" : "manuscrit"
  out.writingExceptions = sanitizeIdList(exceptionIds)
  return out
}

// Returns a NEW evaluation object with one student's entry merged (only
// fields present in `patch` are changed) and re-sanitized. `evaluation`
// itself is never mutated.
function withStudentPatch(evaluation, studentId, patch) {
  var existing = evaluation.students[studentId] || emptyStudentEntry()
  var p = patch || {}
  var merged = {
    copyPath: p.copyPath !== undefined ? p.copyPath : existing.copyPath,
    appreciation: p.appreciation !== undefined ? p.appreciation : existing.appreciation,
    log: p.log !== undefined ? p.log : existing.log,
    needsReview: p.needsReview !== undefined ? p.needsReview : existing.needsReview,
    status: p.status !== undefined ? p.status : existing.status,
    error: p.error !== undefined ? p.error : existing.error,
    reviewed: p.reviewed !== undefined ? p.reviewed : existing.reviewed,
    grades: p.grades !== undefined ? p.grades : existing.grades,
    selectedGrade: p.selectedGrade !== undefined ? p.selectedGrade : existing.selectedGrade,
    addendum: p.addendum !== undefined ? p.addendum : existing.addendum,
    excluded: p.excluded !== undefined ? p.excluded : existing.excluded,
    logItemStates: p.logItemStates !== undefined ? p.logItemStates : existing.logItemStates,
    lisibilite: p.lisibilite !== undefined ? p.lisibilite : existing.lisibilite
  }
  var students = {}
  for (var sid in evaluation.students) students[sid] = evaluation.students[sid]
  students[studentId] = sanitizeStudentEntry(merged)
  var out = {}
  for (var k in evaluation) out[k] = evaluation[k]
  out.students = students
  return out
}

function studentEntry(evaluation, studentId) {
  if (!evaluation || !evaluation.students) return emptyStudentEntry()
  return evaluation.students[studentId] || emptyStudentEntry()
}

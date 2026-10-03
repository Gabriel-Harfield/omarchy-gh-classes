// Saved évaluation-creation presets ("modèles") — Gabriel, 2026-10-03: he
// teaches several classes at the same level (2 x 2nde, 3 x 1ère) and often
// runs the same small, ungraded exercise across all of them. A template
// captures only the wizard's own fields (exercise type, grid, nature/
// durée/niveau/bienveillance/surinterprétation/détail, the three criteria
// lists + their points, notée, barème) — never folderPath/sujetPath/
// corrigePath/agentPath, which are always specific to one class's run and
// must be re-entered (or re-derived) each time regardless of the template.
//
// Kept in its OWN file (NOT corrections.json, NOT classes.json) because,
// unlike an Evaluation, a template has no local filesystem anchor at all —
// exactly why it CAN sync, unlike corrections.json (see that file's own
// header comment). Sync posture mirrors GH Grilles' criteria bank, not
// Store.js's class merge: a template is immutable once saved (Gabriel
// resaves under a new name rather than editing one in place), so merging
// two machines' lists is a plain union by id, no field-by-field
// reconciliation needed.

.pragma library

var MAX_TEMPLATES = 200
var MAX_NAME_LEN = 160
var MAX_PATH_LEN = 2000
var MAX_CRITERE_TEXT_LEN = 500
var MAX_CRITERES_PER_LIST = 30
var MAX_BAREME_LEN = 4000
var MAX_CRITERION_POINTS = 20

function makeId() {
  return "tpl-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
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

// Same id-keyed shape as a draft's own criteria lists (Panel.qml) — each
// criterion keeps its id across save/load so criteriaPoints (keyed by that
// same id) survives the round-trip.
function sanitizeCriteres(list) {
  var out = []
  var arr = Array.isArray(list) ? list : []
  for (var i = 0; i < arr.length && out.length < MAX_CRITERES_PER_LIST; i++) {
    var c = arr[i]
    var text = clampStr(c && c.text, MAX_CRITERE_TEXT_LEN).trim()
    if (!text) continue
    out.push({ id: clampStr(c && c.id, 80) || makeId(), text: text })
  }
  return out
}

function sanitizeCriteriaPoints(v) {
  var src = (v && typeof v === "object") ? v : {}
  var out = {}
  var count = 0
  for (var k in src) {
    if (count >= MAX_CRITERES_PER_LIST * 3) break
    var n = Number(src[k])
    if (isNaN(n) || n <= 0) continue
    // Whole points only — see CorrectionsStore.sanitizeCriteriaPoints()'s
    // own comment (NumberField, the points field's widget, is int-typed).
    out[clampStr(k, 80)] = Math.round(Math.max(0, Math.min(MAX_CRITERION_POINTS, n)))
    count++
  }
  return out
}

// params mirrors Panel.qml's correctionDraft* fields one-to-one — see that
// file's requestSaveEvalTemplate().
function sanitizeTemplate(t) {
  var src = (t && typeof t === "object") ? t : {}
  var name = clampStr(src.name, MAX_NAME_LEN).trim()
  if (!name) return null
  return {
    id: clampStr(src.id, 80) || makeId(),
    name: name,
    createdAt: clampStr(src.createdAt, 40) || new Date().toISOString(),
    exerciseType: clampStr(src.exerciseType, 80),
    gridId: clampStr(src.gridId, 80),
    natureEvaluation: clampStr(src.natureEvaluation, 80),
    typeEvaluation: clampStr(src.typeEvaluation, 80),
    dureeEpreuve: clampInt(src.dureeEpreuve, 5, 600, 60),
    niveauClasse: clampStr(src.niveauClasse, 80),
    bienveillance: clampInt(src.bienveillance, 0, 10, 5),
    priseDeNotes: !!src.priseDeNotes,
    completudeExigee: src.completudeExigee === undefined ? true : !!src.completudeExigee,
    surinterpretation: clampStr(src.surinterpretation, 80),
    niveauDetail: clampStr(src.niveauDetail, 80),
    structMethode: !!src.structMethode,
    structContenu: src.structContenu === undefined ? true : !!src.structContenu,
    structLangue: src.structLangue === undefined ? true : !!src.structLangue,
    methodeCriteres: sanitizeCriteres(src.methodeCriteres),
    contenuCriteres: sanitizeCriteres(src.contenuCriteres),
    langueCriteres: sanitizeCriteres(src.langueCriteres),
    criteriaPoints: sanitizeCriteriaPoints(src.criteriaPoints),
    notee: src.notee === undefined ? true : !!src.notee,
    bareme: clampStr(src.bareme, MAX_BAREME_LEN)
  }
}

function parseTemplates(text) {
  try {
    var arr = JSON.parse(text || "[]")
    if (!Array.isArray(arr)) return []
    var out = []
    for (var i = 0; i < arr.length && out.length < MAX_TEMPLATES; i++) {
      var t = sanitizeTemplate(arr[i])
      if (t) out.push(t)
    }
    return out
  } catch (err) {
    return []
  }
}

function serializeTemplates(list) {
  return JSON.stringify(Array.isArray(list) ? list : [], null, 2)
}

// Plain union by id (unlike Store.mergeClasses()): a template never
// changes after creation, so there's no mutable field to reconcile — see
// header comment. On the rare id collision (shouldn't happen, ids are
// random), local wins, same convention as GH Grilles' bank.
function mergeTemplates(localList, remoteList) {
  var local = Array.isArray(localList) ? localList : []
  var remote = Array.isArray(remoteList) ? remoteList : []
  var out = []
  var seen = {}
  for (var i = 0; i < local.length && out.length < MAX_TEMPLATES; i++) {
    if (seen[local[i].id]) continue
    seen[local[i].id] = true
    out.push(local[i])
  }
  for (var j = 0; j < remote.length && out.length < MAX_TEMPLATES; j++) {
    if (seen[remote[j].id]) continue
    seen[remote[j].id] = true
    out.push(remote[j])
  }
  return out
}

function findTemplate(list, id) {
  var arr = Array.isArray(list) ? list : []
  for (var i = 0; i < arr.length; i++) if (arr[i].id === id) return arr[i]
  return null
}

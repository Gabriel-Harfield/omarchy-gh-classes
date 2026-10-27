// Persistence shapes + sanitizers for GH Classes.
//
// classes.json: array of Class objects.
//   Class: { id, name, createdAt, students: [Student], incompatibilities: [[studentId,...], ...],
//            lastResetAt, competencyIntitules: { [gridId]: intitulé },
//            competencyWeights: { [gridId]: { [rowIndex]: points out of baremeTotal } },
//            competencyBaremeTotal: { [gridId]: 10 | 20 } }
//   competencyBaremeTotal (Gabriel, 2026-10-01): grading scale, same idea
//   as the Corrections tab's own per-évaluation baremeTotal, scoped per
//   (classe, grille) like competencyWeights above. Defaults to 20 when
//   absent for a gridId.
//   competencyWeights (Gabriel, 2026-10-01): same "⚖️ Répartir les points"
//   idea as the Corrections tab's own per-évaluation criteriaWeights, but
//   scoped per (classe, grille) like competencyIntitules above rather than
//   perévaluation — "Eval. Compétences" has no évaluation object to hang
//   it off. Persistent, never auto-recomputed — only changes when Gabriel
//   edits it by hand. The Note field is then always the live SUM of
//   checked paliers × these weights (CompetencyGrids.computeWeightedNote),
//   never a separate stored/typed value — see Panel.qml's
//   evaluationComputedNote(), same "never cache a free computation" lesson
//   as the Corrections tab's own note (see
//   [[gh-corrections-plugin]]'s "Stale note incident").
//   Student: { id, nom, prenom, drawCount, drawHistory: [{date, rank}],
//              competencyGrids: { [gridId]: { checks: { [rowIndex]: colIndex }, appreciation, note,
//                                              annotationsPositif, annotationsNegatif,
//                                              binome, binomeAt, comments } },
//              competencyClearedAt: { [gridId]: isoDate } }
//   annotationsPositif/annotationsNegatif: dead fields, kept only so old
//   synced data isn't silently dropped. Used to feed the "Eval. Compétences"
//   tab's own appreciation generator (PromptBuilder.buildEvalCompetencesAppreciationPrompt,
//   with their own two-column UI), both removed 2026-10-08 — the generator
//   could never be made to stop writing as though it had read the copy,
//   no amount of prompt rework fixed it. No UI writes these anymore.
//   comments (Gabriel, 2026-10-08): [{ id, text, tag }], the "Commentaires"
//   section's own bullet-point list — added ALONGSIDE appreciation, not
//   replacing it (a deliberate transition-period choice, see
//   [[gh-corrections-plugin]]), so an in-progress correction using only the
//   old free-text Appréciation keeps working unchanged. Each entry may have
//   started life as a pick from the global reusable bank
//   (CommentsBankStore.js, its own file/sync, unrelated to per-student
//   data) or been typed fresh — either way this is the student's own COPY
//   of that text, independent of the bank entry it may have come from.
//   Exported merged into the single "Appréciation" section of the PDF/
//   Typst/markdown output, with no visible distinction from prose — see
//   CompetencyGrids.buildTypstBody().
//   binome/binomeAt (Gabriel, 2026-10-06): the partner's student id when
//   this copy was written in pair work, scoped to this one grid (so "🗑
//   Réinitialiser la classe" dropping the grid entry also drops the pair).
//   Both partners carry the same entry, mirrored on every write (see
//   Panel.qml's _evalWriteEntry). A pair only counts when BOTH sides point
//   at each other. binomeAt stamps the last pair/unpair so a sync merge can
//   tell an intentional unpair ("") from a stale remote — see
//   mergeCompetencyGrids().
//
// settings.json: { activeClassId, syncDir, uiZoom }
//
// Bounds mirror the rest of this author's plugin family (ghgrilles,
// ghtypst): generous but not unbounded, so a malformed/huge file can't
// blow up memory or storage.

.pragma library

var MAX_CLASSES = 50
var MAX_STUDENTS = 80
var MAX_NAME_LEN = 120
var MAX_CLASS_NAME_LEN = 120
var MAX_INCOMPATIBILITY_SETS = 200
var MAX_DRAW_HISTORY = 500
var MAX_SYNC_DIR_LEN = 1024
var MAX_COMPETENCY_GRIDS = 50
var MAX_COMPETENCY_ROWS = 200
var MAX_APPRECIATION_LEN = 4000
var MAX_ANNOTATIONS_LEN = 4000
var MAX_NOTE_LEN = 10
var MAX_INTITULE_LEN = 200
var MAX_CRITERION_WEIGHT = 20
var MAX_COMMENTS_PER_ENTRY = 100
var MAX_DELETED_COMMENTS_PER_ENTRY = 200
var MAX_COMMENT_TEXT_LEN = 2000
var MAX_COMMENT_TAG_LEN = 100

function makeId() {
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
}

function clampStr(v, max) {
  return String(v === undefined || v === null ? "" : v).slice(0, max)
}

function sanitizeStudent(s) {
  if (!s || typeof s !== "object") return null
  var nom = clampStr(s.nom, MAX_NAME_LEN).trim()
  if (!nom) return null
  var history = Array.isArray(s.drawHistory) ? s.drawHistory : []
  var cleanHistory = []
  for (var i = 0; i < history.length && cleanHistory.length < MAX_DRAW_HISTORY; i++) {
    var h = history[i]
    if (!h || typeof h !== "object") continue
    var date = clampStr(h.date, 40)
    var rank = Number(h.rank)
    if (!date) continue
    cleanHistory.push({ date: date, rank: (rank === 1 || rank === 2 || rank === 3) ? rank : 1 })
  }
  return {
    id: clampStr(s.id, 80) || makeId(),
    nom: nom,
    prenom: clampStr(s.prenom, MAX_NAME_LEN).trim(),
    drawCount: Math.max(0, Math.floor(Number(s.drawCount) || 0)),
    drawHistory: cleanHistory,
    competencyGrids: sanitizeCompetencyGrids(s.competencyGrids),
    competencyClearedAt: sanitizeCompetencyClearedAt(s.competencyClearedAt)
  }
}

// { [gridId]: { checks: { [rowIndex]: colIndex }, appreciation, note } } —
// one student's "Eval. Compétences" answers. gridId/rowIndex are free-form
// keys (grids are defined in CompetencyGrids.js, not here), so this only
// bounds shape/size and the column value (0..3, matching the 4 fixed
// mastery-level columns), never validates against a specific grid's row
// count.
function sanitizeCompetencyGrids(raw) {
  if (!raw || typeof raw !== "object") return {}
  var out = {}
  var gridKeys = Object.keys(raw)
  var gridCount = 0
  for (var i = 0; i < gridKeys.length && gridCount < MAX_COMPETENCY_GRIDS; i++) {
    var gridId = clampStr(gridKeys[i], 80)
    var entry = raw[gridKeys[i]]
    if (!gridId || !entry || typeof entry !== "object") continue
    var rowsRaw = entry.checks
    var cleanRows = {}
    if (rowsRaw && typeof rowsRaw === "object") {
      var rowKeys = Object.keys(rowsRaw)
      var rowCount = 0
      for (var j = 0; j < rowKeys.length && rowCount < MAX_COMPETENCY_ROWS; j++) {
        var rowIndex = parseInt(rowKeys[j], 10)
        if (!(rowIndex >= 0 && rowIndex < MAX_COMPETENCY_ROWS)) continue
        var colIndex = parseInt(rowsRaw[rowKeys[j]], 10)
        if (!(colIndex >= 0 && colIndex <= 3)) continue
        cleanRows[rowIndex] = colIndex
        rowCount++
      }
    }
    var appreciation = clampStr(entry.appreciation, MAX_APPRECIATION_LEN)
    var note = clampStr(entry.note, MAX_NOTE_LEN)
    // Split into positif/négatif (Gabriel, 2026-10-02 — was a single free
    // field for one day only, see MEMORY/ghclasses-plugin). A pre-existing
    // single `annotations` string (same-day data, before the split) is
    // migrated into annotationsPositif so nothing is silently dropped.
    var annotationsPositif = clampStr(entry.annotationsPositif, MAX_ANNOTATIONS_LEN) || clampStr(entry.annotations, MAX_ANNOTATIONS_LEN)
    var annotationsNegatif = clampStr(entry.annotationsNegatif, MAX_ANNOTATIONS_LEN)
    var binome = clampStr(entry.binome, 80)
    var binomeAt = clampStr(entry.binomeAt, 40)
    // tiersTemps (2026-10-23): "1/3 temps" adjustment applied to this
    // student's note on this grid; tiersTempsAt = when it was last toggled,
    // so a sync keeps the latest choice (an un-tick is a real choice).
    var tiersTemps = !!entry.tiersTemps
    var tiersTempsAt = clampStr(entry.tiersTempsAt, 40)
    // absent (2026-10-27): student marked absent (ABS) on this grid; same
    // timestamped last-choice-wins sync as tiersTemps.
    var absent = !!entry.absent
    var absentAt = clampStr(entry.absentAt, 40)
    // comments (Gabriel, 2026-10-08): "Commentaires" section's own bullet
    // list, added alongside appreciation rather than replacing it — see
    // [[gh-corrections-plugin]]/[[ghclasses-plugin]] for why. Same { id,
    // text, tag } shape as the reusable bank (CommentsBankStore.js) a given
    // one may have come from, but this is the STUDENT's own copy of that
    // text — editing/deleting the bank entry later never touches this.
    var commentsRaw = Array.isArray(entry.comments) ? entry.comments : []
    var comments = []
    for (var k = 0; k < commentsRaw.length && comments.length < MAX_COMMENTS_PER_ENTRY; k++) {
      var c = commentsRaw[k]
      if (!c || typeof c !== "object") continue
      var cText = clampStr(c.text, MAX_COMMENT_TEXT_LEN)
      if (!cText) continue
      var cId = (typeof c.id === "string" && c.id.trim()) ? clampStr(c.id, 64) : (Date.now().toString(36) + Math.random().toString(36).slice(2, 8))
      comments.push({ id: cId, text: cText, tag: clampStr(c.tag, MAX_COMMENT_TAG_LEN) })
    }
    // deletedComments: ids of comments the user removed — a tombstone list,
    // so the union-by-id merge in mergeCompetencyGrid() can't resurrect a
    // deleted bullet from the other machine's copy (2026-10-22).
    var deletedRaw = Array.isArray(entry.deletedComments) ? entry.deletedComments : []
    var deletedComments = []
    for (var d = 0; d < deletedRaw.length && deletedComments.length < MAX_DELETED_COMMENTS_PER_ENTRY; d++) {
      var dId = clampStr(deletedRaw[d], 64)
      if (dId && deletedComments.indexOf(dId) === -1) deletedComments.push(dId)
    }
    if (Object.keys(cleanRows).length > 0 || appreciation || note || annotationsPositif || annotationsNegatif || binome || binomeAt || tiersTemps || absent || comments.length > 0 || deletedComments.length > 0) {
      out[gridId] = { checks: cleanRows, appreciation: appreciation, note: note, annotationsPositif: annotationsPositif, annotationsNegatif: annotationsNegatif, binome: binome, binomeAt: binomeAt, comments: comments, deletedComments: deletedComments, tiersTemps: tiersTemps, tiersTempsAt: tiersTempsAt, absent: absent, absentAt: absentAt }
      gridCount++
    }
  }
  return out
}

// { [gridId]: isoDate } — when Gabriel last clicked "Réinitialiser cet
// élève"/"Réinitialiser la classe" for that grid type, see
// mergeCompetencyGrids() below for why this exists (tombstones a cleared
// grid so a sync merge can't silently resurrect it from a stale copy).
function sanitizeCompetencyClearedAt(raw) {
  if (!raw || typeof raw !== "object") return {}
  var out = {}
  var keys = Object.keys(raw)
  var count = 0
  for (var i = 0; i < keys.length && count < MAX_COMPETENCY_GRIDS; i++) {
    var gridId = clampStr(keys[i], 80)
    var date = clampStr(raw[keys[i]], 40)
    if (!gridId || !date) continue
    out[gridId] = date
    count++
  }
  return out
}

function sanitizeIncompatibilities(list, validIds) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length && out.length < MAX_INCOMPATIBILITY_SETS; i++) {
    var set = list[i]
    if (!Array.isArray(set)) continue
    var cleaned = []
    for (var j = 0; j < set.length; j++) {
      var id = clampStr(set[j], 80)
      if (id && validIds[id] && cleaned.indexOf(id) === -1) cleaned.push(id)
    }
    if (cleaned.length >= 2) out.push(cleaned)
  }
  return out
}

// { [gridId]: intitulé } — the assignment title for this class/grid combo
// (e.g. "Devoir sur table n°2"), shared by every student evaluated on that
// grid rather than duplicated per student.
function sanitizeCompetencyIntitules(raw) {
  if (!raw || typeof raw !== "object") return {}
  var out = {}
  var gridKeys = Object.keys(raw)
  var count = 0
  for (var i = 0; i < gridKeys.length && count < MAX_COMPETENCY_GRIDS; i++) {
    var gridId = clampStr(gridKeys[i], 80)
    var intitule = clampStr(raw[gridKeys[i]], MAX_INTITULE_LEN)
    if (!gridId || !intitule) continue
    out[gridId] = intitule
    count++
  }
  return out
}

// Half-point steps, 0 to MAX_CRITERION_WEIGHT — same shape/posture as
// CorrectionsStore.js's own clampReal/sanitizeCriteriaWeights (separate
// file, this codebase's lib/*.js are standalone .pragma libraries, no
// cross-importing — see that file's own header comment).
function clampWeight(v) {
  var n = Number(v)
  if (isNaN(n)) return undefined
  n = Math.round(n / 0.5) * 0.5
  return Math.max(0, Math.min(MAX_CRITERION_WEIGHT, n))
}

// { [gridId]: { [rowIndex]: points } } — see the Class schema comment above.
function sanitizeCompetencyWeights(raw) {
  if (!raw || typeof raw !== "object") return {}
  var out = {}
  var gridKeys = Object.keys(raw)
  var gridCount = 0
  for (var i = 0; i < gridKeys.length && gridCount < MAX_COMPETENCY_GRIDS; i++) {
    var gridId = clampStr(gridKeys[i], 80)
    var rowsRaw = raw[gridKeys[i]]
    if (!gridId || !rowsRaw || typeof rowsRaw !== "object") continue
    var rowKeys = Object.keys(rowsRaw)
    var rows = {}
    var rowCount = 0
    for (var j = 0; j < rowKeys.length && rowCount < MAX_COMPETENCY_ROWS; j++) {
      var rowIndex = parseInt(rowKeys[j], 10)
      if (!(rowIndex >= 0 && rowIndex < MAX_COMPETENCY_ROWS)) continue
      var points = clampWeight(rowsRaw[rowKeys[j]])
      if (points === undefined || points <= 0) continue
      rows[rowIndex] = points
      rowCount++
    }
    if (Object.keys(rows).length > 0) { out[gridId] = rows; gridCount++ }
  }
  return out
}

var BAREME_TOTALS = [5, 10, 15, 20]

// { [gridId]: 10 | 20 } — see the Class schema comment above.
function sanitizeCompetencyBaremeTotal(raw) {
  if (!raw || typeof raw !== "object") return {}
  var out = {}
  var keys = Object.keys(raw)
  var count = 0
  for (var i = 0; i < keys.length && count < MAX_COMPETENCY_GRIDS; i++) {
    var gridId = clampStr(keys[i], 80)
    var total = Number(raw[keys[i]])
    if (!gridId || BAREME_TOTALS.indexOf(total) === -1) continue
    out[gridId] = total
    count++
  }
  return out
}

function sanitizeClass(c) {
  if (!c || typeof c !== "object") return null
  var name = clampStr(c.name, MAX_CLASS_NAME_LEN).trim()
  if (!name) return null
  var studentsRaw = Array.isArray(c.students) ? c.students : []
  var students = []
  for (var i = 0; i < studentsRaw.length && students.length < MAX_STUDENTS; i++) {
    var s = sanitizeStudent(studentsRaw[i])
    if (s) students.push(s)
  }
  var validIds = {}
  for (var k = 0; k < students.length; k++) validIds[students[k].id] = true
  return {
    id: clampStr(c.id, 80) || makeId(),
    name: name,
    createdAt: clampStr(c.createdAt, 40) || new Date().toISOString(),
    students: students,
    incompatibilities: sanitizeIncompatibilities(c.incompatibilities, validIds),
    lastResetAt: clampStr(c.lastResetAt, 40),
    competencyIntitules: sanitizeCompetencyIntitules(c.competencyIntitules),
    competencyWeights: sanitizeCompetencyWeights(c.competencyWeights),
    competencyBaremeTotal: sanitizeCompetencyBaremeTotal(c.competencyBaremeTotal)
  }
}

function parseClasses(text) {
  try {
    var arr = JSON.parse(text || "[]")
    if (!Array.isArray(arr)) return []
    var out = []
    for (var i = 0; i < arr.length && out.length < MAX_CLASSES; i++) {
      var c = sanitizeClass(arr[i])
      if (c) out.push(c)
    }
    return out
  } catch (e) {
    return []
  }
}

function serializeClasses(classes) {
  return JSON.stringify(classes || [], null, 2)
}

function clampSyncDir(v) {
  return String(v === undefined || v === null ? "" : v).trim().slice(0, MAX_SYNC_DIR_LEN)
}

// uiZoom (Gabriel, 2026-10-02, same idea as GH Typst's editor zoom — a
// panel-wide scale this time, not just one editor pane): 0.6-2.5, defaults
// to 1.0 on anything missing/invalid.
function clampUiZoom(v) {
  var n = Number(v)
  if (isNaN(n)) return 1.0
  return Math.max(0.6, Math.min(2.5, Math.round(n * 10) / 10))
}

function parseSettings(text) {
  try {
    var s = JSON.parse(text || "{}")
    return {
      activeClassId: clampStr(s.activeClassId, 80),
      syncDir: clampSyncDir(s.syncDir),
      uiZoom: clampUiZoom(s.uiZoom),
      popoverZoom: clampUiZoom(s.popoverZoom),
      // agent.md's path, global now rather than per-évaluation (Gabriel,
      // 2026-10-03) — a local filesystem path like syncDir, so NOT synced
      // (see Panel.qml's runSync(), which only ever touches classes.json/
      // eval_templates.json, both machine-agnostic).
      agentPath: clampSyncDir(s.agentPath)
    }
  } catch (e) {
    return { activeClassId: "", syncDir: "", uiZoom: 1.0, popoverZoom: 1.0, agentPath: "" }
  }
}

function serializeSettings(settings) {
  return JSON.stringify({
    activeClassId: settings.activeClassId || "",
    syncDir: settings.syncDir || "",
    uiZoom: clampUiZoom(settings.uiZoom),
    popoverZoom: clampUiZoom(settings.popoverZoom),
    agentPath: settings.agentPath || ""
  }, null, 2)
}

function findClass(classes, id) {
  for (var i = 0; i < classes.length; i++) if (classes[i].id === id) return classes[i]
  return null
}

function replaceClass(classes, updated) {
  return classes.map(function(c) { return c.id === updated.id ? updated : c })
}

function studentLabel(s) {
  return s.nom + (s.prenom ? " " + s.prenom : "")
}

// Capitalizes the first letter of each word (split on space/hyphen/
// apostrophe, ex. "Jean-Baptiste", "Anne-Sophie"), lowercasing the rest —
// hand-rolled rather than a Unicode-property regex, same style as
// CopyMatcher.js's own accent handling.
function titleCase(s) {
  var str = String(s || "")
  var out = ""
  var capitalizeNext = true
  for (var i = 0; i < str.length; i++) {
    var c = str.charAt(i)
    if (c === " " || c === "-" || c === "'") {
      out += c
      capitalizeNext = true
    } else {
      out += capitalizeNext ? c.toUpperCase() : c.toLowerCase()
      capitalizeNext = false
    }
  }
  return out
}

// "NOM Prénom" for external sharing (ex. liste de groupes copiée en
// markdown pour École Directe) — nom in full caps, prénom title-cased,
// regardless of how the roster itself stored the casing.
function studentLabelFormatted(s) {
  return String(s.nom || "").toUpperCase() + (s.prenom ? " " + titleCase(s.prenom) : "")
}

// --- sync (additive-merge classes.json via a user-chosen folder) ----------
//
// Unlike GH Grilles' criteria bank (immutable, independent entries), a
// Class carries mutable per-student counters (drawCount/drawHistory) that
// keep changing on the machine you're actively using — so merging two
// classes.json files can't just union arrays like Grilles does. The rule
// here: classes and students are matched by id (never re-derived from
// name — see the caveat below), drawHistory entries are unioned and
// deduped by (date, rank), drawCount is always RECOMPUTED as the merged
// history's length rather than trusted from either side (it's a derived
// value, not an independent counter, so this can't drift), and
// incompatibility sets are unioned deduped by their sorted member ids.
//
// A "Réinitialiser les tirages" reset is honored across the merge: the
// merged lastResetAt is the later of the two sides' timestamps, and any
// drawHistory entry dated at or before that timestamp is dropped — so a
// reset done on one machine can't be silently undone by a stale sync from
// a machine that hasn't caught up yet.
//
// Same trade-off as Grilles for deletion: deleting a class locally does
// NOT remove it from the sync folder, and if the other machine still has
// it, the next sync brings it back. Worth stating in the sync popover, not
// just here.
//
// Important limitation this can't paper over: syncing only makes sense for
// a class CREATED ONCE (imported on one machine, then synced to the
// other) — importing the same roster.md independently on two machines
// produces two classes with different ids (and different per-student
// ids), so they'll never merge into one; they'll just sit side by side as
// two distinct classes.

function mergeIncompatibilities(localList, remoteList) {
  var all = (Array.isArray(localList) ? localList : []).concat(Array.isArray(remoteList) ? remoteList : [])
  var out = []
  var seen = {}
  for (var i = 0; i < all.length && out.length < MAX_INCOMPATIBILITY_SETS; i++) {
    var set = all[i]
    if (!Array.isArray(set)) continue
    var key = set.slice().sort().join(",")
    if (seen[key]) continue
    seen[key] = true
    out.push(set)
  }
  return out
}

// Shallow per-cell merge, local wins on conflict: there's no timestamp per
// checkbox/appreciation/note to arbitrate by, so a value changed on both
// machines picks whichever machine is doing the merging — same trade-off as
// elsewhere in this sync, just undocumented until now since this is the
// first field without its own resolution rule (drawHistory unions by date,
// incompatibilities dedupe by member set). appreciation/note fall back to
// whichever side is non-empty when the other side has nothing yet.
//
// clearedAt (Gabriel, 2026-10-01): { [gridId]: isoDate }, already merged
// (see mergeCompetencyClearedAt below) — a real bug, found the same day:
// "Réinitialiser cet élève"/"Réinitialiser la classe" correctly deletes
// grids[gridId] locally, but the very next sync used to bring it right
// back from the sync folder's (now stale) copy, since an ABSENT local
// entry looked identical to "nothing to contribute" rather than "this was
// intentionally cleared" — same class of problem drawHistory already
// solves via lastResetAt, competencyGrids just never had the equivalent.
// Same trade-off as lastResetAt: once a grid is cleared on one machine, a
// stale sync from a machine that hasn't caught up yet can't silently
// resurrect it — but if local genuinely has fresh data again (re-ticked
// since the clear), that local entry exists and wins normally below,
// clearedAt is only consulted when local has NOTHING for this grid.
function mergeCompetencyGrids(localGrids, remoteGrids, clearedAt) {
  var local = localGrids || {}
  var remote = remoteGrids || {}
  var cleared = clearedAt || {}
  var gridIds = {}
  Object.keys(local).forEach(function(id) { gridIds[id] = true })
  Object.keys(remote).forEach(function(id) { gridIds[id] = true })
  var out = {}
  Object.keys(gridIds).forEach(function(gridId) {
    var l = local[gridId]
    // Cleared locally (no re-entry since) — never fall back to remote's
    // possibly-stale copy, whether or not remote itself is actually newer:
    // we have no per-entry timestamp to tell the difference, see above.
    if (!l && cleared[gridId]) return
    l = l || {}
    var r = remote[gridId] || {}
    var mergedChecks = {}
    var rc = r.checks || {}
    var lc = l.checks || {}
    Object.keys(rc).forEach(function(rowIdx) { mergedChecks[rowIdx] = rc[rowIdx] })
    Object.keys(lc).forEach(function(rowIdx) { mergedChecks[rowIdx] = lc[rowIdx] })
    // Later pair/unpair wins — unlike the text fields below, an empty
    // binome is a real choice ("Dissocier"), so it can't just fall back to
    // remote's value when local is "".
    var pairSide = (r.binomeAt || "") > (l.binomeAt || "") ? r : l
    // comments: union by id, never dropped by a sync — each bullet is
    // added independently (never edited in place), so unlike appreciation/
    // binome there's no "which side is newer" question to resolve, just
    // "did either side add one the other doesn't have yet."
    // A deletion on either side wins (deletedComments tombstones).
    var mergedDeleted = []
    var deletedSet = {}
    ;(l.deletedComments || []).concat(r.deletedComments || []).forEach(function(id) {
      if (!id || deletedSet[id]) return
      deletedSet[id] = true
      mergedDeleted.push(id)
    })
    mergedDeleted = mergedDeleted.slice(-MAX_DELETED_COMMENTS_PER_ENTRY)
    var tiersSide = (r.tiersTempsAt || "") > (l.tiersTempsAt || "") ? r : l
    var absentSide = (r.absentAt || "") > (l.absentAt || "") ? r : l
    var mergedComments = []
    var seenCommentIds = {}
    ;(l.comments || []).concat(r.comments || []).forEach(function(c) {
      if (!c || seenCommentIds[c.id] || deletedSet[c.id]) return
      seenCommentIds[c.id] = true
      mergedComments.push(c)
    })
    out[gridId] = {
      checks: mergedChecks,
      appreciation: l.appreciation ? l.appreciation : (r.appreciation || ""),
      note: l.note ? l.note : (r.note || ""),
      annotationsPositif: l.annotationsPositif ? l.annotationsPositif : (r.annotationsPositif || ""),
      annotationsNegatif: l.annotationsNegatif ? l.annotationsNegatif : (r.annotationsNegatif || ""),
      binome: pairSide.binome || "",
      binomeAt: pairSide.binomeAt || "",
      comments: mergedComments,
      deletedComments: mergedDeleted,
      tiersTemps: !!tiersSide.tiersTemps,
      tiersTempsAt: tiersSide.tiersTempsAt || "",
      absent: !!absentSide.absent,
      absentAt: absentSide.absentAt || ""
    }
  })
  return out
}

// Later timestamp wins per grid id — same "max of the two sides" idiom as
// lastResetAt (see mergeClass below), just keyed per grid instead of a
// single class-wide value.
function mergeCompetencyClearedAt(local, remote) {
  var l = local || {}
  var r = remote || {}
  var out = {}
  Object.keys(l).forEach(function(gridId) { out[gridId] = l[gridId] })
  Object.keys(r).forEach(function(gridId) {
    if (!out[gridId] || r[gridId] > out[gridId]) out[gridId] = r[gridId]
  })
  return out
}

function mergeStudent(localS, remoteS, mergedLastResetAt) {
  var base = localS || remoteS
  var pool = (localS ? (localS.drawHistory || []) : []).concat(remoteS ? (remoteS.drawHistory || []) : [])
  var seen = {}
  var merged = []
  for (var i = 0; i < pool.length; i++) {
    var h = pool[i]
    if (!h || !h.date) continue
    if (mergedLastResetAt && h.date <= mergedLastResetAt) continue
    var key = h.date + "#" + h.rank
    if (seen[key]) continue
    seen[key] = true
    merged.push(h)
  }
  merged.sort(function(a, b) { return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0) })
  if (merged.length > MAX_DRAW_HISTORY) merged = merged.slice(merged.length - MAX_DRAW_HISTORY)
  var clearedAt = mergeCompetencyClearedAt(localS && localS.competencyClearedAt, remoteS && remoteS.competencyClearedAt)
  return {
    id: base.id,
    nom: base.nom,
    prenom: base.prenom,
    drawCount: merged.length,
    drawHistory: merged,
    competencyGrids: mergeCompetencyGrids(localS && localS.competencyGrids, remoteS && remoteS.competencyGrids, clearedAt),
    competencyClearedAt: clearedAt
  }
}

function mergeClass(localC, remoteC) {
  if (!localC) return remoteC
  if (!remoteC) return localC
  var lastResetAt = (localC.lastResetAt || "") > (remoteC.lastResetAt || "") ? localC.lastResetAt : remoteC.lastResetAt
  var byId = {}
  var order = []
  var localStudents = localC.students || []
  var remoteStudents = remoteC.students || []
  for (var i = 0; i < localStudents.length; i++) {
    var ls = localStudents[i]
    if (!byId[ls.id]) { byId[ls.id] = {}; order.push(ls.id) }
    byId[ls.id].local = ls
  }
  for (var j = 0; j < remoteStudents.length; j++) {
    var rs = remoteStudents[j]
    if (!byId[rs.id]) { byId[rs.id] = {}; order.push(rs.id) }
    byId[rs.id].remote = rs
  }
  var students = order.slice(0, MAX_STUDENTS).map(function(id) {
    return mergeStudent(byId[id].local, byId[id].remote, lastResetAt)
  })
  var localIntitules = localC.competencyIntitules || {}
  var remoteIntitules = remoteC.competencyIntitules || {}
  var intituleGridIds = {}
  Object.keys(localIntitules).forEach(function(id) { intituleGridIds[id] = true })
  Object.keys(remoteIntitules).forEach(function(id) { intituleGridIds[id] = true })
  var competencyIntitules = {}
  Object.keys(intituleGridIds).forEach(function(gridId) {
    competencyIntitules[gridId] = localIntitules[gridId] ? localIntitules[gridId] : (remoteIntitules[gridId] || "")
  })
  var localWeights = localC.competencyWeights || {}
  var remoteWeights = remoteC.competencyWeights || {}
  var weightGridIds = {}
  Object.keys(localWeights).forEach(function(id) { weightGridIds[id] = true })
  Object.keys(remoteWeights).forEach(function(id) { weightGridIds[id] = true })
  var competencyWeights = {}
  Object.keys(weightGridIds).forEach(function(gridId) {
    var l = localWeights[gridId]
    competencyWeights[gridId] = (l && Object.keys(l).length > 0) ? l : (remoteWeights[gridId] || {})
  })
  var localBareme = localC.competencyBaremeTotal || {}
  var remoteBareme = remoteC.competencyBaremeTotal || {}
  var baremeGridIds = {}
  Object.keys(localBareme).forEach(function(id) { baremeGridIds[id] = true })
  Object.keys(remoteBareme).forEach(function(id) { baremeGridIds[id] = true })
  var competencyBaremeTotal = {}
  Object.keys(baremeGridIds).forEach(function(gridId) {
    competencyBaremeTotal[gridId] = localBareme[gridId] ? localBareme[gridId] : (remoteBareme[gridId] || 20)
  })
  return {
    id: localC.id,
    name: localC.name,
    createdAt: localC.createdAt,
    students: students,
    incompatibilities: mergeIncompatibilities(localC.incompatibilities, remoteC.incompatibilities),
    lastResetAt: lastResetAt,
    competencyIntitules: competencyIntitules,
    competencyWeights: competencyWeights,
    competencyBaremeTotal: competencyBaremeTotal
  }
}

// Union-merges two classes.json arrays (already-parsed Class[] shapes) and
// returns the result, sanitized through sanitizeClass so caps still apply
// after merging. Never drops a class present on only one side.
function mergeClasses(localClasses, remoteClasses) {
  var byId = {}
  var order = []
  var local = Array.isArray(localClasses) ? localClasses : []
  var remote = Array.isArray(remoteClasses) ? remoteClasses : []
  for (var i = 0; i < local.length; i++) {
    var lc = local[i]
    if (!byId[lc.id]) { byId[lc.id] = {}; order.push(lc.id) }
    byId[lc.id].local = lc
  }
  for (var j = 0; j < remote.length; j++) {
    var rc = remote[j]
    if (!byId[rc.id]) { byId[rc.id] = {}; order.push(rc.id) }
    byId[rc.id].remote = rc
  }
  var out = []
  for (var k = 0; k < order.length && out.length < MAX_CLASSES; k++) {
    var entry = byId[order[k]]
    var merged = mergeClass(entry.local, entry.remote)
    var clean = sanitizeClass(merged)
    if (clean) out.push(clean)
  }
  return out
}

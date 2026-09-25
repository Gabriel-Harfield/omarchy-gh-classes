// Persistence shapes + sanitizers for GH Classes.
//
// classes.json: array of Class objects.
//   Class: { id, name, createdAt, students: [Student], incompatibilities: [[studentId,...], ...] }
//   Student: { id, nom, prenom, drawCount, drawHistory: [{date, rank}] }
//
// settings.json: { activeClassId }
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
    drawHistory: cleanHistory
  }
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
    lastResetAt: clampStr(c.lastResetAt, 40)
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

function parseSettings(text) {
  try {
    var s = JSON.parse(text || "{}")
    return { activeClassId: clampStr(s.activeClassId, 80), syncDir: clampSyncDir(s.syncDir) }
  } catch (e) {
    return { activeClassId: "", syncDir: "" }
  }
}

function serializeSettings(settings) {
  return JSON.stringify({ activeClassId: settings.activeClassId || "", syncDir: settings.syncDir || "" }, null, 2)
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
  return {
    id: base.id,
    nom: base.nom,
    prenom: base.prenom,
    drawCount: merged.length,
    drawHistory: merged
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
  return {
    id: localC.id,
    name: localC.name,
    createdAt: localC.createdAt,
    students: students,
    incompatibilities: mergeIncompatibilities(localC.incompatibilities, remoteC.incompatibilities),
    lastResetAt: lastResetAt
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

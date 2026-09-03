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
    incompatibilities: sanitizeIncompatibilities(c.incompatibilities, validIds)
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

function parseSettings(text) {
  try {
    var s = JSON.parse(text || "{}")
    return { activeClassId: clampStr(s.activeClassId, 80) }
  } catch (e) {
    return { activeClassId: "" }
  }
}

function serializeSettings(settings) {
  return JSON.stringify({ activeClassId: settings.activeClassId || "" }, null, 2)
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

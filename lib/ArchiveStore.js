// Archives of Corrections évaluations (Gabriel, 2026-10-15). The Corrections
// tab keeps ONE évaluation per class, and "Nouvelle évaluation" used to
// delete the old one outright — fine until two devoirs overlap and the first
// one hasn't been handed back yet (a contestation would find nothing left).
// An archive is one JSON file per évaluation, written to a folder Gabriel
// chose (Dropbox/…/Correction automatique/archives). It holds everything
// the plugin knows about the évaluation (grids, bullets, notes, settings,
// file PATHS) but NOT the copies' PDFs — they stay where they are, so
// restoring finds them again as long as that folder isn't moved. Students
// are referenced by id only (names live in the class roster), so an archive
// only makes sense restored into the SAME class.
//
// The file NAME carries what the listing needs, so listing never has to open
// and parse every archive: <classId>__<yyyyMMdd-HHmmss>__<title-slug>__<done>sur<total>.json

.pragma library

var FORMAT = "ghclasses-evaluation-archive"
var VERSION = 1

function pad(n) { return (n < 10 ? "0" : "") + n }

function stamp(d) {
  return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + "-" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
}

function slug(s) {
  var t = String(s || "").toLowerCase()
  // Strip accents so the filename stays plain ASCII.
  if (t.normalize) t = t.normalize("NFD").replace(/[̀-ͯ]/g, "")
  t = t.replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "")
  return (t || "evaluation").slice(0, 60)
}

function counts(evaluation) {
  var st = (evaluation && evaluation.students) || {}
  var done = 0
  var total = 0
  for (var id in st) {
    total++
    if (st[id] && st[id].status === "done") done++
  }
  return { done: done, total: total }
}

function buildFilename(classId, evaluation, date) {
  var c = counts(evaluation)
  return String(classId) + "__" + stamp(date || new Date()) + "__" + slug(evaluation && evaluation.title) + "__" + c.done + "sur" + c.total + ".json"
}

// → { classId, when: "2026-10-15 11:24", title (slug), done, total, file } or null
function parseFilename(name) {
  var m = String(name || "").match(/^(.+?)__(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})__(.+)__(\d+)sur(\d+)\.json$/)
  if (!m) return null
  return {
    file: name, classId: m[1],
    when: m[2] + "-" + m[3] + "-" + m[4] + " " + m[5] + ":" + m[6],
    title: m[8], done: parseInt(m[9], 10), total: parseInt(m[10], 10)
  }
}

// Newest first, only those belonging to `classId`.
function listFor(fileNames, classId) {
  var out = []
  ;(fileNames || []).forEach(function(n) {
    var e = parseFilename(n)
    if (e && e.classId === classId) out.push(e)
  })
  out.sort(function(a, b) { return a.file < b.file ? 1 : (a.file > b.file ? -1 : 0) })
  return out
}

function makePayload(classId, className, evaluation, date) {
  return JSON.stringify({
    format: FORMAT, version: VERSION,
    archivedAt: (date || new Date()).toISOString(),
    classId: classId, className: className || "",
    evaluation: evaluation
  })
}

// → { evaluation } or { error }. `evaluation` is the RAW stored object; the
// caller re-sanitizes it (CorrectionsStore.sanitizeEvaluation) before use.
function parsePayload(text, classId) {
  var p
  try { p = JSON.parse(String(text || "")) } catch (e) { return { error: "Fichier d'archive illisible." } }
  if (!p || p.format !== FORMAT || !p.evaluation || typeof p.evaluation !== "object") return { error: "Ce fichier n'est pas une archive d'évaluation." }
  if (p.version > VERSION) return { error: "Archive créée par une version plus récente du plugin." }
  if (p.classId !== classId) return { error: "Cette archive appartient à une autre classe." }
  return { evaluation: p.evaluation }
}

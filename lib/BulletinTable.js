// "Appréciations > Bulletin" table (Gabriel, 2026-11-18): one row per student
// of the class, three hand-typed indications (travail / comportement / axe
// de progression) and the generated appreciation. Local to the machine —
// deliberately NOT part of classes.json, so it is never synced/merged until
// Gabriel decides it should be.
//
// File shape (bulletin-table.json):
//   { model: "sonnet"|"opus", maxChars: "300",
//     classes: { [classId]: { rows: { [studentId]: { travail, comportement, axe, text, gen } } } } }
//   text = what is shown in the Appréciation column (editable);
//   gen  = the last text the agent produced for that row. A row whose text
//   differs from gen (or has text but no gen) was edited by
//   hand: "locked", never overwritten by the whole-class generation (only by
//   that row's own ↻ button).

.pragma library

var MAX_FIELD_LEN = 2000
var MODELS = ["sonnet", "opus"]
var KEYS = ["travail", "comportement", "axe"]

function clampStr(v, max) {
  var s = String(v === undefined || v === null ? "" : v)
  return s.length > max ? s.slice(0, max) : s
}

// at = ISO timestamp of the row's last edit (sync arbitration).
function emptyRow() {
  return { travail: "", comportement: "", axe: "", text: "", gen: "", at: "" }
}

function sanitizeRow(r) {
  var o = r || {}
  return {
    travail: clampStr(o.travail, MAX_FIELD_LEN),
    comportement: clampStr(o.comportement, MAX_FIELD_LEN),
    axe: clampStr(o.axe, MAX_FIELD_LEN),
    text: clampStr(o.text, MAX_FIELD_LEN),
    gen: clampStr(o.gen, MAX_FIELD_LEN),
    at: clampStr(o.at, 40)
  }
}

function parse(text) {
  var out = { model: "sonnet", maxChars: "300", classes: {} }
  var raw
  try { raw = JSON.parse(String(text || "")) } catch (e) { return out }
  if (!raw || typeof raw !== "object") return out
  if (MODELS.indexOf(raw.model) >= 0) out.model = raw.model
  var mc = parseInt(raw.maxChars, 10)
  if (mc > 0 && mc <= 5000) out.maxChars = String(mc)
  var cls = raw.classes
  if (cls && typeof cls === "object") {
    var ids = Object.keys(cls).slice(0, 100)
    ids.forEach(function(cid) {
      var rows = (cls[cid] && cls[cid].rows) || {}
      var clean = {}
      Object.keys(rows).slice(0, 200).forEach(function(sid) { clean[sid] = sanitizeRow(rows[sid]) })
      out.classes[cid] = { rows: clean, clearedAt: clampStr(cls[cid] && cls[cid].clearedAt, 40) }
    })
  }
  return out
}

function serialize(state) {
  return JSON.stringify(state, null, 1)
}

// Sync merge (Gabriel, 2026-11-18). Per student row, the later `at` wins
// (local on a tie); "🆕 Nouvelle série" stamps the class's clearedAt, and a
// row not edited since then is dropped on both sides. model/maxChars are
// per-machine preferences: the local ones are kept.
function merge(local, remote) {
  var out = { model: local.model, maxChars: local.maxChars, classes: {} }
  var ids = {}
  Object.keys(local.classes || {}).forEach(function(id) { ids[id] = true })
  Object.keys(remote.classes || {}).forEach(function(id) { ids[id] = true })
  Object.keys(ids).forEach(function(cid) {
    var l = (local.classes || {})[cid] || { rows: {}, clearedAt: "" }
    var r = (remote.classes || {})[cid] || { rows: {}, clearedAt: "" }
    var cleared = (l.clearedAt || "") > (r.clearedAt || "") ? (l.clearedAt || "") : (r.clearedAt || "")
    var rows = {}
    var sids = {}
    Object.keys(l.rows || {}).forEach(function(id) { sids[id] = true })
    Object.keys(r.rows || {}).forEach(function(id) { sids[id] = true })
    Object.keys(sids).forEach(function(sid) {
      var a = l.rows[sid], b = r.rows[sid]
      var pick = !b ? a : (!a ? b : ((b.at || "") > (a.at || "") ? b : a))
      if (cleared && (pick.at || "") <= cleared) return
      rows[sid] = pick
    })
    out.classes[cid] = { rows: rows, clearedAt: cleared }
  })
  return out
}

function isLocked(row) {
  if (!row || !row.text) return false
  return row.text !== row.gen
}

function hasIndications(row) {
  if (!row) return false
  return KEYS.some(function(k) { return String(row[k] || "").trim() !== "" })
}

// Extracts {id → text} from the model's answer: tolerates a ```json fence
// or a sentence around the object, keeps only the ids that were asked for.
function parseClassOutput(output, validIds) {
  var s = String(output || "")
  var a = s.indexOf("{"), b = s.lastIndexOf("}")
  var result = { texts: {}, missing: [], error: "" }
  if (a < 0 || b <= a) { result.error = "Réponse inattendue (pas de JSON)."; result.missing = validIds.slice(); return result }
  var obj
  try { obj = JSON.parse(s.slice(a, b + 1)) } catch (e) { result.error = "JSON invalide dans la réponse."; result.missing = validIds.slice(); return result }
  validIds.forEach(function(id) {
    var t = obj[id]
    if (typeof t === "string" && t.trim() !== "") result.texts[id] = t.trim()
    else result.missing.push(id)
  })
  return result
}

// ---- prompts -------------------------------------------------------------

var FIELD_LABELS = { travail: "Travail", comportement: "Comportement", axe: "Axe de progression" }

function fieldLines(row) {
  return KEYS.map(function(k) {
    var v = String((row && row[k]) || "").trim()
    return "  - " + FIELD_LABELS[k] + " : " + (v || "(rien de particulier à signaler)")
  })
}

// entries: [{ id, row }] — ids are plain positions ("1", "2"…), the model
// never sees names.
function buildClassPrompt(entries, maxChars) {
  var lines = []
  lines.push("Tu es un professeur de lettres qui rédige les appréciations de bulletin scolaire de toute une classe.")
  lines.push("Rédige, pour chaque élève ci-dessous, UNE appréciation en français, dans un registre professionnel et bienveillant, en te basant strictement sur les indications fournies pour cet élève.")
  lines.push("Varie les tournures d'un élève à l'autre : deux appréciations ne doivent pas commencer ni se terminer de la même façon.")
  lines.push("")
  entries.forEach(function(e) {
    lines.push("Élève " + e.id + " :")
    fieldLines(e.row).forEach(function(l) { lines.push(l) })
  })
  lines.push("")
  lines.push("Contrainte stricte : chaque appréciation ne doit pas dépasser " + maxChars + " caractères (espaces compris).")
  lines.push("Réponds UNIQUEMENT avec un objet JSON valide, sans balises markdown ni commentaire, dont les clés sont les numéros d'élève (chaînes) et les valeurs les appréciations, par exemple : {\"1\": \"...\", \"2\": \"...\"}.")
  return lines.join("\n")
}

// others: up to a few texts already produced for classmates, given only as
// a style reference.
function buildStudentPrompt(row, maxChars, others) {
  var lines = []
  lines.push("Tu es un professeur de lettres qui rédige une appréciation de bulletin scolaire.")
  lines.push("Rédige UNE SEULE appréciation, en français, dans un registre professionnel et bienveillant, en te basant strictement sur les indications ci-dessous.")
  lines.push("")
  fieldLines(row).forEach(function(l) { lines.push(l.replace(/^  /, "")) })
  var ex = (others || []).filter(function(t) { return String(t || "").trim() !== "" }).slice(0, 4)
  if (ex.length) {
    lines.push("")
    lines.push("Appréciations déjà rédigées pour d'autres élèves de la classe (uniquement pour le ton et le style ; ne les recopie pas et n'en reprends pas les tournures) :")
    ex.forEach(function(t) { lines.push("- " + String(t).trim()) })
  }
  lines.push("")
  lines.push("Contrainte stricte : l'appréciation ne doit pas dépasser " + maxChars + " caractères (espaces compris).")
  lines.push("Réponds UNIQUEMENT avec le texte de l'appréciation, sans guillemets, sans titre, sans commentaire additionnel, sans markdown.")
  return lines.join("\n")
}

// Logique pure de l'onglet « Questionnaire » (correction de QCM scannés).
// Aucune E/S ici : tout est testable sous node. Le QML ne fait que brancher
// les processus (pdftoppm, claude) et afficher.
//
// Format d'entrée : le `versions.json` produit par le générateur de QCM
// (~/Work/qcm-generator/qcm.py). Chaque version : { num, classe, items:
// [{ id, level, q, options, correct }] } où `correct` est la LETTRE (A, B…)
// de la bonne réponse, les cases étant numérotées de haut en bas sur la
// feuille (A = première case).
//
// Règle de fond (comme le pipeline Questionnaire existant) : l'agent ne fait
// que LIRE (quelle case est cochée, quelle version, quel nom). La note est
// calculée ici, jamais par l'agent.

.pragma library

var LETTERS = "ABCDEFGH"

function letterOf(pos) {
  var n = Math.floor(Number(pos))
  return n >= 1 && n <= LETTERS.length ? LETTERS.charAt(n - 1) : ""
}

// ---- clé (versions.json) --------------------------------------------------

function parseVersions(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return { ok: false, error: "versions.json illisible : " + e } }
  if (!data || !Array.isArray(data.versions) || data.versions.length === 0)
    return { ok: false, error: "versions.json ne contient aucune version." }
  var map = {}
  var perQuestion = 0
  for (var i = 0; i < data.versions.length; i++) {
    var v = data.versions[i]
    if (!v || !Array.isArray(v.items) || typeof v.num !== "number") continue
    var items = []
    for (var k = 0; k < v.items.length; k++) {
      var it = v.items[k]
      var correct = String(it.correct || "").toUpperCase()
      if (LETTERS.indexOf(correct) === -1 || correct === "") continue
      items.push({ id: String(it.id || ""), level: String(it.level || ""), correct: correct,
                   nOptions: Array.isArray(it.options) ? it.options.length : 0 })
    }
    if (items.length === 0) continue
    map[v.num] = { num: v.num, classe: String(v.classe || ""), items: items }
    perQuestion = Math.max(perQuestion, items.length)
  }
  if (perQuestion === 0) return { ok: false, error: "Aucune version exploitable dans versions.json." }
  return { ok: true, titre: String(data.titre || ""), seed: data.seed, nQuestions: perQuestion,
           pts: Number(data.pts) > 0 ? Number(data.pts) : 2, versions: map }
}

function versionsOfClass(parsed, className) {
  var out = []
  for (var key in parsed.versions) {
    var v = parsed.versions[key]
    if (!className || !v.classe || normalize(v.classe) === normalize(className)) out.push(v.num)
  }
  return out.sort(function(a, b) { return a - b })
}

// ---- notation -------------------------------------------------------------

// answers : tableau de lettres ("A".."H") ou "" quand rien / ambigu.
// Une case vide ou ambiguë vaut 0, sans malus.
function scoreCopy(version, answers, pts) {
  var per = Number(pts) > 0 ? Number(pts) : 2
  if (!version) return { ok: false, points: 0, correct: 0, total: 0, detail: [] }
  var detail = []
  var good = 0
  for (var i = 0; i < version.items.length; i++) {
    var given = String((answers && answers[i]) || "").toUpperCase()
    var ok = given !== "" && given === version.items[i].correct
    if (ok) good++
    detail.push({ n: i + 1, id: version.items[i].id, given: given, expected: version.items[i].correct, ok: ok })
  }
  return { ok: true, points: good * per, correct: good, total: version.items.length, detail: detail }
}

function formatPoints(points) {
  var p = Math.round(Number(points) * 100) / 100
  return String(p).replace(".", ",")
}

// ---- noms -----------------------------------------------------------------

var ACCENTS = {
  "à":"a","â":"a","ä":"a","á":"a","ã":"a","å":"a","é":"e","è":"e","ê":"e","ë":"e",
  "î":"i","ï":"i","í":"i","ô":"o","ö":"o","ó":"o","õ":"o","ù":"u","û":"u","ü":"u","ú":"u",
  "ç":"c","ñ":"n","œ":"oe","æ":"ae"
}

function normalize(s) {
  var low = String(s || "").toLowerCase()
  var out = ""
  for (var i = 0; i < low.length; i++) {
    var c = low.charAt(i)
    out += ACCENTS[c] !== undefined ? ACCENTS[c] : c
  }
  return out.replace(/[^a-z0-9]/g, "")
}

function distance(a, b) {
  if (a === b) return 0
  if (!a.length) return b.length
  if (!b.length) return a.length
  var prev = []
  for (var j = 0; j <= b.length; j++) prev.push(j)
  for (var i = 1; i <= a.length; i++) {
    var cur = [i]
    for (var k = 1; k <= b.length; k++)
      cur.push(Math.min(prev[k] + 1, cur[k - 1] + 1, prev[k - 1] + (a.charAt(i - 1) === b.charAt(k - 1) ? 0 : 1)))
    prev = cur
  }
  return prev[b.length]
}

// students : [{id, nom, prenom}] ; renvoie { id, level: "sure"|"maybe"|"none" }
function matchStudent(students, nomLu, prenomLu) {
  var nom = normalize(nomLu), prenom = normalize(prenomLu)
  var whole = nom + prenom
  if (!whole) return { id: "", level: "none" }
  var best = { id: "", level: "none", score: 99 }
  var tied = false
  for (var i = 0; i < (students || []).length; i++) {
    var s = students[i]
    var sn = normalize(s.nom), sp = normalize(s.prenom)
    var d = Math.min(distance(whole, sn + sp), distance(whole, sp + sn))
    // nom exact + prénom qui commence pareil : très probable même si le prénom est abrégé
    if (nom && sn === nom && prenom && (sp.indexOf(prenom) === 0 || prenom.indexOf(sp) === 0)) d = Math.min(d, 0)
    if (d < best.score) { best = { id: s.id, level: "none", score: d }; tied = false }
    else if (d === best.score) tied = true
  }
  if (best.id === "") return { id: "", level: "none" }
  if (tied) return { id: "", level: "none" }
  if (best.score === 0) return { id: best.id, level: "sure" }
  if (best.score <= 2) return { id: best.id, level: "maybe" }
  return { id: "", level: "none" }
}

// ---- lecture de la sortie de l'agent -----------------------------------------

// Attendu : { "version": 12, "nom": "…", "prenom": "…",
//   "reponses": [ { "q": 1, "case": 3, "remarque": "" }, … ] }
// `case` = position de la case cochée dans la question (1 = la première, en haut),
// null si aucune case ou ambiguïté non résolue.
function parseAgentOutput(text, nQuestions) {
  var s = String(text || "")
  var a = s.indexOf("{"), b = s.lastIndexOf("}")
  if (a === -1 || b <= a) return { ok: false, error: "Pas de JSON dans la réponse de l'agent." }
  var data
  try { data = JSON.parse(s.slice(a, b + 1)) } catch (e) { return { ok: false, error: "JSON invalide : " + e } }
  var answers = [], remarks = []
  for (var i = 0; i < nQuestions; i++) { answers.push(""); remarks.push("") }
  var list = Array.isArray(data.reponses) ? data.reponses : []
  for (var k = 0; k < list.length; k++) {
    var r = list[k]
    var q = Math.floor(Number(r && r.q))
    if (!(q >= 1 && q <= nQuestions)) continue
    answers[q - 1] = letterOf(r.case)
    remarks[q - 1] = String(r.remarque || "").slice(0, 200)
  }
  var v = Math.floor(Number(data.version))
  return { ok: true, version: v > 0 ? v : 0, nom: String(data.nom || "").trim(),
           prenom: String(data.prenom || "").trim(), answers: answers, remarks: remarks }
}

// ---- état persisté ----------------------------------------------------------
// { "<classId>": { versionsPath, source, copies: [copy] } }
// copy : { id, file, status: pending|reading|done|error, error, version, studentId,
//          nomLu, prenomLu, match, answers[], remarks[], edited }

function parseState(text) {
  try {
    var d = JSON.parse(String(text || ""))
    return d && typeof d === "object" && !Array.isArray(d) ? d : {}
  } catch (e) { return {} }
}

function serializeState(state) { return JSON.stringify(state || {}, null, 1) }

function emptyClassState() { return { versionsPath: "", source: "", copies: [] } }

// ---- export -------------------------------------------------------------------

function csvCell(v) {
  var t = String(v === undefined || v === null ? "" : v)
  return /[;"\n]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t
}

// rows : [{ eleve, classe, version, note, bonnes }]
function buildCsv(devoir, rows) {
  var lines = ["Devoir;Classe;Élève;Version;Bonnes réponses;Note"]
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    lines.push([csvCell(devoir), csvCell(r.classe), csvCell(r.eleve), csvCell(r.version),
                csvCell(r.bonnes), csvCell(r.note)].join(";"))
  }
  return lines.join("\n") + "\n"
}

// Matches student copy PDFs dropped into the "dossier du devoir" against
// the class roster, by filename convention: "NOM-Prénom-Classe.pdf".
//
// Matching is deliberately NOT a strict 3-part split on "-": a compound
// prénom (ex. "Jean-Baptiste") also contains a hyphen, so
// "MARTIN-Jean-Baptiste-2nde4.pdf" would split into 4 parts, not 3.
// Instead, the whole basename is normalized (accents stripped, separators
// removed, uppercased) and a student matches if that string STARTS WITH
// nom immediately followed by prénom — order fixed by the naming
// convention, position anchored to the start so an unrelated file
// mentioning the name later can't false-positive.

.pragma library

var MAX_FILES = 500

var ACCENT_MAP = {
  "À": "A", "Â": "A", "Ä": "A", "Á": "A", "Ã": "A", "Å": "A",
  "à": "a", "â": "a", "ä": "a", "á": "a", "ã": "a", "å": "a",
  "É": "E", "È": "E", "Ê": "E", "Ë": "E", "é": "e", "è": "e", "ê": "e", "ë": "e",
  "Î": "I", "Ï": "I", "Í": "I", "î": "i", "ï": "i", "í": "i",
  "Ô": "O", "Ö": "O", "Ó": "O", "Õ": "O", "ô": "o", "ö": "o", "ó": "o", "õ": "o",
  "Ù": "U", "Û": "U", "Ü": "U", "Ú": "U", "ù": "u", "û": "u", "ü": "u", "ú": "u",
  "Ç": "C", "ç": "c", "Ñ": "N", "ñ": "n", "Œ": "OE", "œ": "oe", "Æ": "AE", "æ": "ae"
}

function stripAccents(s) {
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i)
    out += ACCENT_MAP[c] !== undefined ? ACCENT_MAP[c] : c
  }
  return out
}

function normalizeToken(s) {
  return stripAccents(String(s || "")).toUpperCase().replace(/[^A-Z0-9]/g, "")
}

function baseName(path) {
  var s = String(path || "")
  var idx = s.lastIndexOf("/")
  return idx === -1 ? s : s.slice(idx + 1)
}

function stripExtension(name) {
  var s = String(name || "")
  var idx = s.lastIndexOf(".")
  return idx <= 0 ? s : s.slice(0, idx)
}

function isDirectoryPath(directory) {
  var text = String(directory || "")
  return text.length > 1 && text.charAt(0) === "/"
    && text.indexOf("\n") === -1 && text.indexOf("\r") === -1
}

// argv for listing every .pdf directly inside `directory` (non-recursive).
// Bounded by a timeout the same way lib/Files.js bounds its own reads —
// a folder synced through a cloud-drive client can stall a stat() call.
function listPdfCommand(directory) {
  if (!isDirectoryPath(directory)) return null
  return [
    "timeout", "-k", "1", "10",
    "find", String(directory), "-mindepth", "1", "-maxdepth", "1",
    "-type", "f", "-iname", "*.pdf"
  ]
}

// Parses `find`'s newline-separated stdout into [{path, name}, ...].
function parseFileList(stdoutText) {
  var lines = String(stdoutText || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length && out.length < MAX_FILES; i++) {
    var path = lines[i].trim()
    if (!path) continue
    out.push({ path: path, name: baseName(path) })
  }
  return out
}

// files: [{path, name}, ...]  students: [{id, nom, prenom}, ...]
// Returns { studentId: copyPath, ... } — only for students a file was
// found for. Each file is claimed by at most one student (first match,
// files considered in name order for determinism).
function matchCopies(files, students) {
  var sorted = (files || []).slice().sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  var used = {}
  var result = {}
  var list = students || []
  for (var s = 0; s < list.length; s++) {
    var student = list[s]
    var nom = normalizeToken(student.nom)
    var prenom = normalizeToken(student.prenom)
    if (!nom) continue
    for (var i = 0; i < sorted.length; i++) {
      var f = sorted[i]
      if (used[f.path]) continue
      var norm = normalizeToken(stripExtension(f.name))
      var matches = prenom ? (norm.indexOf(nom + prenom) === 0) : (norm.indexOf(nom) === 0)
      if (matches) {
        result[student.id] = f.path
        used[f.path] = true
        break
      }
    }
  }
  return result
}

// Parses a class roster from a markdown/plain-text file: one student per
// line, always "NOM Prénom" — the surname written first, in capitals
// (Gabriel's own stated convention), the given name(s) after. Tolerant of
// markdown list markers ("- ", "* ", "1. ") and blank lines.

.pragma library

function isUpperWord(w) {
  if (!w) return false
  return w === w.toUpperCase() && w !== w.toLowerCase()
}

function stripListMarker(line) {
  return line.replace(/^\s*(?:[-*+]|\d+[.)])\s+/, "")
}

function parseLine(rawLine) {
  var line = stripListMarker(rawLine.trim())
  if (!line) return null
  var words = line.split(/\s+/).filter(function(w) { return w.length > 0 })
  if (words.length === 0) return null

  var nomWords = []
  var i = 0
  while (i < words.length && isUpperWord(words[i])) {
    nomWords.push(words[i])
    i++
  }
  if (nomWords.length === 0) {
    nomWords.push(words[0])
    i = 1
  }
  var prenomWords = words.slice(i)
  return { nom: nomWords.join(" "), prenom: prenomWords.join(" ") }
}

// Returns { students: [{nom, prenom}], skipped: int } — students are NOT
// assigned ids here, the caller (Store-facing code) does that on save so
// re-imports/edits stay consistent with the rest of the sanitizer.
function parseRoster(text, maxStudents) {
  var lines = String(text || "").split(/\r?\n/)
  var students = []
  var skipped = 0
  for (var i = 0; i < lines.length; i++) {
    if (students.length >= maxStudents) { skipped += 1; continue }
    var parsed = parseLine(lines[i])
    if (!parsed || !parsed.nom) continue
    students.push(parsed)
  }
  return { students: students, skipped: skipped }
}

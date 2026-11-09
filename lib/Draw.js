// Weighted random draw: a student's draw weight falls as their own
// drawCount rises (1 / (1 + drawCount)), so someone picked often becomes
// progressively less likely to be picked again — never impossible, just
// less probable, and it resets naturally as everyone else's own count
// rises too.

.pragma library

function weightFor(student) {
  return 1 / (1 + Math.max(0, student.drawCount || 0))
}

// Students who can be drawn: everyone not marked drawExcluded ("🚫 Exclure
// du tirage", e.g. a PAP-type aménagement).
function eligible(students) {
  return students.filter(function(s) { return !s.drawExcluded })
}

// Returns an array of up to 3 students, ranked [1st, 2nd, 3rd], drawn
// without replacement, never an excluded student.
function pickThree(students) {
  var pool = eligible(students)
  var picks = []
  for (var k = 0; k < 3 && pool.length > 0; k++) {
    var weights = pool.map(weightFor)
    var total = weights.reduce(function(a, b) { return a + b }, 0)
    var r = Math.random() * total
    var acc = 0
    var idx = pool.length - 1
    for (var i = 0; i < weights.length; i++) {
      acc += weights[i]
      if (r <= acc) { idx = i; break }
    }
    picks.push(pool[idx])
    pool.splice(idx, 1)
  }
  return picks
}

// Returns a NEW students array with drawCount/drawHistory updated for the
// three picked ids (rank 1/2/3), everyone else untouched.
function recordDraw(students, pickedIds, dateIso) {
  var rankById = {}
  for (var i = 0; i < pickedIds.length; i++) rankById[pickedIds[i]] = i + 1
  return students.map(function(s) {
    var rank = rankById[s.id]
    if (!rank) return s
    // Copies every field, then overrides the draw counters. Bug found
    // 2026-11-02: this used to rebuild the student from id/nom/prenom/draw*
    // only, silently dropping the picked students' competencyGrids (their
    // "Eval. Compétences" answers) on every draw — same class of bug as the
    // tirage reset one fixed 2026-10-01.
    var out = {}
    Object.keys(s).forEach(function(k) { out[k] = s[k] })
    out.drawCount = (s.drawCount || 0) + 1
    out.drawHistory = (s.drawHistory || []).concat([{ date: dateIso, rank: rank }])
    return out
  })
}

function csvField(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return '"' + s.replace(/"/g, '""') + '"'
}

// Semicolon-delimited (French-locale Excel/LibreOffice default), one row
// per student, quoted fields throughout.
function statsCsv(students) {
  var lines = ["Nom;Prénom;Nombre de tirages;Dates de tirage"]
  var sorted = students.slice().sort(function(a, b) { return a.nom.localeCompare(b.nom) })
  for (var i = 0; i < sorted.length; i++) {
    var s = sorted[i]
    var dates = (s.drawHistory || []).map(function(h) { return h.date + " (#" + h.rank + ")" }).join(", ")
    lines.push([csvField(s.nom), csvField(s.prenom), csvField(s.drawCount || 0), csvField(dates)].join(";"))
  }
  return lines.join("\n") + "\n"
}

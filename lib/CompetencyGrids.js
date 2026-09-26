// Grille templates for the "Eval. Compétences" tab: hardcoded, versioned in
// code rather than user-editable in the app — Gabriel pastes a new grid's
// content into a conversation with Claude and it gets added here as a new
// entry in GRIDS, same spirit as PromptBuilder.js's hardcoded prompts.
//
// Each grid's `rows` is parsed from a small markdown-like outline: "# " and
// "## " lines (deeper levels also supported). A row is a checkbox row
// ("checkable") unless the very next line is one level deeper — i.e. a
// heading that has sub-items becomes a plain section header spanning the
// full table width, and only its children get checkboxes. This mirrors
// Gabriel's own convention ("les titres # possédant un sous-titre ## ne
// posséderont pas de cases à cocher").
//
// Per-student answers are stored as
// { [grid.id]: { checks: { [rowIndex]: colIndex }, appreciation, note } } on
// the Student object (see Store.js) — rowIndex is the row's position in this
// parsed array, so reordering/inserting rows in an existing grid here would
// silently reshuffle already-recorded answers. Only ever append rows to an
// existing grid, or ship a new grid id for a reworked version.

.pragma library

var COLUMNS = ["Non maîtrisé", "Insuffisamment maîtrisé", "En cours de maîtrise", "Maîtrisé"]

function parseGridMarkdown(text) {
  var lines = String(text || "").split("\n")
  var raw = []
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^(#{1,6})\s+(.*\S)\s*$/)
    if (!m) continue
    raw.push({ level: m[1].length, text: m[2] })
  }
  var rows = []
  for (var j = 0; j < raw.length; j++) {
    var hasChild = (j + 1 < raw.length) && (raw[j + 1].level > raw[j].level)
    rows.push({ level: raw[j].level, text: raw[j].text, checkable: !hasChild })
  }
  return rows
}

// The official (État/Éducation nationale) EAF competency list — kept as-is
// for the real bac correction at year's end. Gabriel finds it too vague for
// formative evaluations day to day (see COMMENTAIRE_FORMATIF_MD below,
// his own reworked version for that use).
var COMMENTAIRE_EAF_MD = [
  "# Aptitude à comprendre, à analyser et à interpréter un texte littéraire",
  "## Aptitude à comprendre un texte littéraire",
  "## Aptitude à analyser et à interpréter un texte littéraire",
  "# Aptitude à mobiliser une culture littéraire fondée sur les travaux conduits en cours de français, sur des connaissances et des lectures personnelles",
  "# Aptitude à construire une réflexion en prenant appui sur un texte et à la rendre intelligible",
  "# Maîtrise de la langue et de l'expression à l'écrit",
  "## Aptitude à respecter les normes orthographiques et syntaxiques",
  "## Aptitude à utiliser une langue correcte et adaptée"
].join("\n")

// Gabriel's own, more precise rewrite for day-to-day formative grading
// (2026-09-26) — a handful of obvious typos in his pasted text corrected
// in transcription (réflexionen→réflexion en, prennant→prenant,
// correctment→correctement, orthographiaques→orthographiques, son→sont,
// un annonce→une annonce), wording otherwise kept exactly as given since
// this prints verbatim on documents handed to students.
var COMMENTAIRE_FORMATIF_MD = [
  "# Aptitude à comprendre un texte littéraire.",
  "# Aptitude à analyser et à interpréter un texte littéraire.",
  "## La problématique proposée permet d'engager une véritable réflexion sur le sens du texte.",
  "## Les analyses proposées sont précises et s'appuient sur un vocabulaire littéraire précis.",
  "## Les interprétations proposées permettent de faire avancer la réflexion proposée par la problématique.",
  "# Aptitude à construire une réflexion en prenant appui sur un texte et à la rendre intelligible.",
  "## Mon travail est correctement mis en page (titres soulignés, saut de ligne entre les parties, alinéas au début de chaque paragraphe, références aux lignes correctement indiquées...).",
  "## Mon travail est correctement construit, comprenant une introduction, un développement en plusieurs parties avec des sous-parties et une conclusion.",
  "## Mon introduction est complète, comprenant une présentation de l'extrait, une problématique et une annonce du plan correctement formulées.",
  "## Mes paragraphes de développement sont correctement construits, avec un argument, des citations dûment analysées étayant ce dernier et une interprétation faisant avancer ma réflexion.",
  "# Maîtrise de la langue et de l'expression à l'écrit.",
  "## Les normes orthographiques et syntaxiques sont bien respectées.",
  "## Le style est fluide et le propos cohérent.",
  "## Le niveau de langue employé est bien adapté à l'exercice."
].join("\n")

var GRIDS = [
  { id: "commentaire", name: "Commentaire EAF", rows: parseGridMarkdown(COMMENTAIRE_EAF_MD) },
  { id: "commentaire-formatif", name: "Commentaire formatif", rows: parseGridMarkdown(COMMENTAIRE_FORMATIF_MD) }
]

function findGrid(id) {
  for (var i = 0; i < GRIDS.length; i++) if (GRIDS[i].id === id) return GRIDS[i]
  return null
}

// Typst's reserved markup characters — escaped so a criterion/name/class
// containing one of these renders as literal text instead of breaking out
// into markup (e.g. a class name with a "#" in it).
function escapeTypst(s) {
  return String(s || "").replace(/[\\#*_$<>@`]/g, "\\$&")
}

// A hard line break the user typed (Enter) must survive into the PDF as a
// visual line break, not get folded into a space the way a lone newline
// normally is in Typst markup — hence #linebreak() between escaped lines
// rather than just joining on "\n".
function toTypstMultiline(text) {
  return escapeTypst(text).split("\n").join(" #linebreak() ")
}

// French school year (rentrée in September) for the footer — "2026-2027"
// from a date anywhere between September 2026 and August 2027 inclusive.
function currentSchoolYear() {
  var now = new Date()
  var y = now.getFullYear()
  return (now.getMonth() + 1 >= 9) ? (y + "-" + (y + 1)) : ((y - 1) + "-" + y)
}

// payload: { checks: { [rowIndex]: colIndex }, appreciation, note } for one
// student on one grid. intitule is the assignment's own title (e.g. "Devoir
// sur table n°2"), shown as a header — omitted entirely if blank. Produces a
// self-contained .typ source (no external imports/template) so it compiles
// standalone via `typst compile`.
function buildTypstSource(studentLabel, className, grid, payload, intitule) {
  payload = payload || {}
  var checks = payload.checks || {}
  var appreciation = String(payload.appreciation || "").trim()
  var note = String(payload.note || "").trim()
  intitule = String(intitule || "").trim()
  var footerText = "M.Harfield - " + escapeTypst(className) + " - " + currentSchoolYear()
  var lines = []
  lines.push("#set page(")
  lines.push("  margin: 2cm,")
  lines.push("  footer: align(center)[_" + footerText + "_]")
  lines.push(")")
  // hyphenate: true matters here — "Insuffisamment" alone is wider than the
  // narrow 2.1cm level columns below, and without it Typst won't break a
  // long word without a space, so it just overflows into the next column.
  lines.push("#set text(size: 11pt, lang: \"fr\", hyphenate: true)")
  lines.push("")
  if (intitule) {
    lines.push("#align(center)[#text(size: 13pt, weight: \"bold\")[" + escapeTypst(intitule) + "]]")
    lines.push("#v(0.8em)")
  }
  lines.push("#text(size: 16pt, weight: \"bold\")[" + escapeTypst(studentLabel) + "]")
  lines.push("#v(0.4em)")
  lines.push("#text(size: 13pt, weight: \"bold\")[" + escapeTypst(grid.name) + "]")
  lines.push("#v(0.6em)")
  lines.push("")
  // Fixed, narrow level columns (Critères takes whatever's left) so the
  // table doesn't balloon out with "auto" — headers wrap onto two lines
  // where needed, same trade-off as the app's own table.
  lines.push("#table(")
  lines.push("  columns: (1fr, 2.1cm, 2.1cm, 2.1cm, 2.1cm),")
  lines.push("  align: (left, center, center, center, center),")
  lines.push("  table.header([*Critères*], " + COLUMNS.map(function(c) { return "[*" + escapeTypst(c) + "*]" }).join(", ") + "),")
  grid.rows.forEach(function(row, idx) {
    if (!row.checkable) {
      lines.push("  table.cell(colspan: 5, fill: luma(235))[*" + escapeTypst(row.text) + "*],")
      return
    }
    var marks = [0, 1, 2, 3].map(function(ci) { return checks[idx] === ci ? "X" : "" })
    if (row.level > 1) {
      // A sub-item under a greyed section header: indented (#h) and
      // lightly shaded across the whole row, so it visually reads as
      // belonging to that header rather than a top-level criterion.
      var label = "table.cell(fill: luma(248))[#h(1em)" + escapeTypst(row.text) + "]"
      var cells = marks.map(function(m) { return "table.cell(fill: luma(248))[" + m + "]" })
      lines.push("  " + label + ", " + cells.join(", ") + ",")
    } else {
      var plainCells = marks.map(function(m) { return "[" + m + "]" })
      lines.push("  [" + escapeTypst(row.text) + "], " + plainCells.join(", ") + ",")
    }
  })
  lines.push(")")
  lines.push("")
  lines.push("#v(1.2em)")
  lines.push("*Appréciation*")
  lines.push("")
  lines.push(appreciation ? toTypstMultiline(appreciation) : "#text(fill: luma(150))[—]")
  lines.push("")
  lines.push("#v(1em)")
  lines.push("*Note : * " + (note ? escapeTypst(note) : "……") + " / 20")
  return lines.join("\n")
}

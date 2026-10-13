// Grille de correction d'un QUESTIONNAIRE, lue depuis le fichier que
// Gabriel a fabriqué lui-même (ONLYOFFICE .docx, ou un simple .md/.txt) —
// Gabriel, 2026-10-11, après le test manuel sur "GR - Analyse des
// constituants" ([[gh-corrections-plugin]]).
//
// Pourquoi le plugin parse la grille lui-même plutôt que de laisser
// l'agent lire le .docx :
//   1. l'agent du pipeline questionnaire tourne en lecture seule
//      (ClaudeRunner.buildCheckCommand, --allowedTools Read), et l'outil
//      Read ne sait pas ouvrir un .docx — il faudrait lui donner Bash,
//      c'est-à-dire exactement ce qu'on refuse à un run non supervisé ;
//   2. une fois les lignes extraites ici, l'agent ne répond plus que par
//      NUMÉRO de ligne : le barème, la note et l'appariement ne dépendent
//      plus du tout de sa capacité à recopier un libellé long sans faute
//      (constat du test manuel : la copie ne suit pas l'ordre de la
//      grille, saute des items, en traite deux fois — un appariement
//      positionnel se serait trompé sur toute la fin).
//
// Conventions de la grille :
//   - un seul tableau (le plus grand du document s'il y en a plusieurs) ;
//   - 1re ligne = en-tête : 1re cellule = intitulé de la colonne des
//     constituants/questions, les suivantes = les cases à cocher
//     ("Non", "Partiel", "Oui") ;
//   - lignes suivantes = un item par ligne, le libellé en 1re cellule
//     (= la réponse attendue), les autres cellules laissées vides.
//
// Barème : les colonnes valent 0 → 1 réparti uniformément, de gauche à
// droite (3 colonnes = 0 / 0,5 / 1 ; 2 colonnes = 0 / 1 ; 4 colonnes =
// 0 / ⅓ / ⅔ / 1). Chaque item pèse pareil. Le total brut est ensuite
// ramené sur le barème de l'évaluation par une règle de trois —
// exactement le calcul que Gabriel fait à la main. Ce calcul est fait
// ICI, jamais par l'agent : même posture que
// CompetencyGrids.computeWeightedNote() ("never the agent's own
// arithmetic for a real grade").

.pragma library

var MAX_ROWS = 200
var MAX_COLUMNS = 8
var MAX_LABEL_LEN = 600
// Noms de fichier cherchés dans le dossier du devoir, dans cet ordre —
// même convention "range le fichier sous ce nom exact" que sujet.pdf /
// corrigé.pdf (Gabriel, 2026-10-03 : "pour une bricole de moins").
var GRID_FILENAMES = ["grille.docx", "grille.md", "grille.txt"]

// ---- lecture du fichier -------------------------------------------------

function isFilePath(path) {
  var text = String(path || "")
  return text.length > 1 && text.charAt(0) === "/"
    && text.indexOf("\n") === -1 && text.indexOf("\r") === -1
}

function isDocx(path) {
  return /\.docx$/i.test(String(path || ""))
}

// argv (jamais de shell) pour sortir le XML du corps d'un .docx sur
// stdout. Borné par timeout comme toutes les lectures de ce plugin (voir
// lib/Files.js) : le dossier du devoir peut être sur un disque réseau ou
// un dossier synchronisé qui cesse de répondre.
function readDocxCommand(path) {
  if (!isFilePath(path) || !isDocx(path)) return null
  return ["timeout", "-k", "1", "15", "unzip", "-p", String(path), "word/document.xml"]
}

// Idem pour une grille écrite en markdown/texte brut.
function readTextCommand(path) {
  if (!isFilePath(path)) return null
  return ["timeout", "-k", "1", "10", "head", "-c", "262144", "--", String(path)]
}

// ---- extraction XML (docx) ----------------------------------------------

// Découpe <tag ...> ... </tag> en comptant la profondeur, pour que les
// tableaux/lignes/cellules imbriqués (un tableau dans une cellule) ne
// coupent pas le bloc parent au premier </tag> venu.
function extractBlocks(xml, tag) {
  var text = String(xml || "")
  var open = new RegExp("<" + tag + "(?:\\s[^>]*)?>", "g")
  var close = new RegExp("</" + tag + ">", "g")
  var marks = []
  var m
  while ((m = open.exec(text)) !== null) marks.push({ at: m.index, end: m.index + m[0].length, kind: 1 })
  while ((m = close.exec(text)) !== null) marks.push({ at: m.index, end: m.index + m[0].length, kind: -1 })
  marks.sort(function(a, b) { return a.at - b.at })
  var out = []
  var depth = 0
  var startAt = -1
  for (var i = 0; i < marks.length; i++) {
    if (marks[i].kind === 1) {
      if (depth === 0) startAt = marks[i].at
      depth++
    } else if (depth > 0) {
      depth--
      if (depth === 0 && startAt !== -1) {
        out.push(text.slice(startAt, marks[i].end))
        startAt = -1
      }
    }
  }
  return out
}

function decodeEntities(s) {
  return String(s || "")
    .replace(/&#(\d+);/g, function(_, d) {
      var code = Number(d)
      // Les espaces typographiques (cadratin &#8195;, insécable &#160;…)
      // n'apportent rien dans un libellé comparé par l'agent.
      return (code === 160 || (code >= 8192 && code <= 8203)) ? " " : String.fromCharCode(code)
    })
    .replace(/&#x([0-9a-fA-F]+);/g, function(_, h) { return String.fromCharCode(parseInt(h, 16)) })
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"").replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
}

// Un <w:r> (run) est en italique si ses propriétés portent <w:i/> sans
// w:val="0"/"false". <w:iCs/> (complex script) est ignoré : Word le pose
// souvent seul sans que le texte latin soit en italique.
function runIsItalic(runXml) {
  var rPr = String(runXml || "").match(/<w:rPr>([\s\S]*?)<\/w:rPr>/)
  if (!rPr) return false
  var i = rPr[1].match(/<w:i(?:\s[^>]*)?\/?>/)
  if (!i) return false
  return !/w:val\s*=\s*"(0|false|off)"/.test(i[0])
}

// Texte d'une cellule, reconstruit run par run, avec l'italique matérialisé
// en syntaxe Typst (_..._) — c'est la convention de Gabriel pour marquer
// un ÉLÉMENT COMPLÉMENTAIRE dans la réponse attendue
// (ex. "épithète _détaché_ de limpidité" : "détaché" ne doit pas peser
// dans la décision de cocher "Oui").
//
// Règle de contraste, volontaire : si TOUTES les parties non vides d'une
// cellule sont en italique, on ne marque rien. La grille réelle de Gabriel
// (GR - Analyse des constituants) a son tableau entier en italique — sans
// cette règle, tous les items passeraient pour facultatifs d'un coup. Le
// marquage n'a de sens que relativement au reste de la même ligne.
function cellText(cellXml) {
  var runs = extractBlocks(cellXml, "w:r")
  var parts = []
  for (var i = 0; i < runs.length; i++) {
    var piece = ""
    var tokens = runs[i].match(/<w:t(?:\s[^>]*)?>[\s\S]*?<\/w:t>|<w:tab\s*\/?>|<w:br\s*\/?>/g) || []
    for (var j = 0; j < tokens.length; j++) {
      if (/^<w:(tab|br)/.test(tokens[j])) { piece += " "; continue }
      piece += decodeEntities(tokens[j].replace(/^<w:t(?:\s[^>]*)?>/, "").replace(/<\/w:t>$/, ""))
    }
    if (piece === "") continue
    parts.push({ text: piece, italic: runIsItalic(runs[i]) })
  }
  var anyPlain = parts.some(function(p) { return !p.italic && p.text.trim() !== "" })
  var anyItalic = parts.some(function(p) { return p.italic && p.text.trim() !== "" })
  var mark = anyPlain && anyItalic
  var out = ""
  for (var k = 0; k < parts.length; k++) {
    // Les italiques consécutifs sont fusionnés en un seul _…_ plutôt
    // qu'un marqueur par run : Word découpe un même mot en plusieurs runs
    // dès qu'une correction orthographique est passée dessus.
    if (mark && parts[k].italic && (k === 0 || !parts[k - 1].italic)) out += "_"
    out += parts[k].text
    if (mark && parts[k].italic && (k === parts.length - 1 || !parts[k + 1].italic)) out += "_"
  }
  return out.replace(/\s+/g, " ").trim()
}

// Rend un libellé lisible à l'œil nu (popover, PDF) en retirant les
// marqueurs _…_ — le libellé marqué reste ce qu'on envoie à l'agent.
function plainLabel(text) {
  return String(text || "").replace(/_/g, "")
}

// Retourne { columns: [string], rows: [{ text }], error: "" }.
function parseDocx(xml) {
  var tables = extractBlocks(xml, "w:tbl")
  if (tables.length === 0) return { columns: [], rows: [], error: "Aucun tableau trouvé dans ce fichier .docx." }
  // Le plus grand tableau : un document peut aussi contenir un petit
  // tableau de mise en page (en-tête, encadré de consigne…).
  var best = null
  var bestRows = -1
  for (var t = 0; t < tables.length; t++) {
    var n = extractBlocks(tables[t], "w:tr").length
    if (n > bestRows) { bestRows = n; best = tables[t] }
  }
  var trs = extractBlocks(best, "w:tr")
  if (trs.length < 2) return { columns: [], rows: [], error: "Le tableau de la grille doit avoir une ligne d'en-tête et au moins un item." }

  var header = extractBlocks(trs[0], "w:tc").map(cellText)
  if (header.length < 3) return { columns: [], rows: [], error: "La grille doit avoir au moins 2 colonnes à cocher en plus de la colonne des items." }
  var columns = header.slice(1, 1 + MAX_COLUMNS).map(function(c) { return plainLabel(c) })

  var rows = []
  for (var r = 1; r < trs.length && rows.length < MAX_ROWS; r++) {
    var cells = extractBlocks(trs[r], "w:tc")
    if (cells.length === 0) continue
    var label = cellText(cells[0]).slice(0, MAX_LABEL_LEN)
    if (label === "") continue
    rows.push({ text: label })
  }
  if (rows.length === 0) return { columns: [], rows: [], error: "Aucun item lisible dans le tableau de la grille." }
  return { columns: columns, rows: rows, error: "" }
}

// Grille en markdown/texte : la 1re ligne commençant par "|" donne
// l'en-tête (format tableau markdown), sinon on prend Non/Partiel/Oui par
// défaut et chaque ligne non vide est un item ("- " ou "1. " en tête
// facultatifs).
function parseText(text) {
  var lines = String(text || "").split("\n")
  var columns = null
  var rows = []
  for (var i = 0; i < lines.length && rows.length < MAX_ROWS; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (line.charAt(0) === "|") {
      var cells = line.replace(/^\|/, "").replace(/\|$/, "").split("|").map(function(c) { return c.trim() })
      if (cells.every(function(c) { return /^:?-{2,}:?$/.test(c) })) continue // ligne de séparation
      if (columns === null) { columns = cells.slice(1, 1 + MAX_COLUMNS); continue }
      if (cells[0]) rows.push({ text: cells[0].slice(0, MAX_LABEL_LEN) })
      continue
    }
    if (/^#/.test(line)) continue
    rows.push({ text: line.replace(/^(?:[-*]\s+|\d+[.)]\s+)/, "").slice(0, MAX_LABEL_LEN) })
  }
  if (!columns || columns.length < 2) columns = ["Non", "Partiel", "Oui"]
  if (rows.length === 0) return { columns: [], rows: [], error: "Aucun item lisible dans la grille." }
  return { columns: columns, rows: rows, error: "" }
}

function parse(path, content) {
  return isDocx(path) ? parseDocx(content) : parseText(content)
}

// ---- barème --------------------------------------------------------------

// Part de point d'une colonne : 0 à gauche, 1 à droite, réparti
// uniformément. 3 colonnes → 0 / 0,5 / 1, le barème de Gabriel.
function columnFraction(colIndex, columnCount) {
  var n = Number(columnCount) || 0
  if (n < 2) return 0
  var i = Number(colIndex)
  if (isNaN(i) || i < 0 || i >= n) return 0
  return i / (n - 1)
}

// Valeur affichable d'une colonne, en points d'item ("0", "0,5", "1").
function columnPointsLabel(colIndex, columnCount) {
  var f = columnFraction(colIndex, columnCount)
  if (Math.abs(f - Math.round(f)) < 0.001) return String(Math.round(f))
  var rounded = Math.round(f * 100) / 100
  return String(rounded).replace(".", ",")
}

// Convention française : demi-points, virgule décimale — même fonction que
// CompetencyGrids.formatNote(), répétée ici plutôt qu'importée (chaque
// lib/*.js de ce plugin est une .pragma library autonome).
function formatNote(n) {
  var rounded = Math.round(n * 2) / 2
  if (Math.abs(rounded - Math.round(rounded)) < 0.01) return String(Math.round(rounded))
  return String(Math.floor(rounded)) + ",5"
}

function formatRaw(n) {
  var rounded = Math.round(n * 2) / 2
  if (Math.abs(rounded - Math.round(rounded)) < 0.01) return String(Math.round(rounded))
  return String(Math.floor(rounded)) + ",5"
}

// checks: { "<rowIndex>": colIndex }. Un item non coché (l'agent l'a
// manqué, ou Gabriel n'a pas encore tranché) compte 0 mais reste dans le
// total maximal : une grille à moitié remplie doit donner une note
// visiblement basse, pas une note flatteuse calculée sur les seuls items
// traités — c'est l'inverse de la posture "partiellement rempli = total
// partiel" de CompetencyGrids, parce qu'ici chaque item est une question
// posée à l'élève, pas un critère que l'enseignant peut choisir d'écarter.
// Retourne { raw, max, note, answered, total } — raw/max en points d'item,
// note ramenée sur baremeTotal.
function computeNote(rows, checks, columnCount, baremeTotal) {
  var list = Array.isArray(rows) ? rows : []
  var c = checks || {}
  var total = Number(baremeTotal) > 0 ? Number(baremeTotal) : 20
  var raw = 0
  var answered = 0
  for (var i = 0; i < list.length; i++) {
    var level = c[String(i)]
    if (level === undefined || level === null) continue
    answered++
    raw += columnFraction(level, columnCount)
  }
  var max = list.length
  if (max === 0) return { raw: 0, max: 0, note: "", answered: 0, total: total, rawLabel: "", noteLabel: "" }
  var note = raw * total / max
  return {
    raw: raw, max: max, answered: answered, total: total,
    note: note,
    rawLabel: formatRaw(raw) + " / " + max,
    noteLabel: formatNote(note) + " / " + total
  }
}

// ---- correction « 1/3 temps » ------------------------------------------

// Gabriel, 2026-10-13 : plutôt qu'un ×1,33 qui avantage les meilleures
// notes, on rend à l'élève une fraction K de ses points perdus —
//   finale = note + K × (barème − note)
// arrondie au demi-point le plus proche. Le bonus décroît à mesure que la
// note monte et ne peut jamais dépasser le barème. Appliquée à la note DÉJÀ
// ramenée sur le barème et arrondie (celle que Gabriel voit à l'écran), pour
// que les chiffres affichés s'enchaînent de façon vérifiable.
var TIERS_TEMPS_K = 0.15

function roundHalf(n) {
  return Math.round(n * 2) / 2
}

function parseNote(s) {
  var t = String(s === undefined || s === null ? "" : s).trim().replace(",", ".")
  if (t === "") return NaN
  var n = Number(t)
  return isFinite(n) ? n : NaN
}

function tiersTempsNote(base, total) {
  var t = Number(total) > 0 ? Number(total) : 20
  return Math.min(t, roundHalf(Number(base) + TIERS_TEMPS_K * (t - Number(base))))
}

// Tout ce qu'il faut pour afficher/exporter la note d'un élève, en un
// seul calcul (jamais mis en cache — voir computeNote). override = la
// note corrigée à la main (noteSevere), "" sinon.
// Retourne { computed, rawLabel, scaled, baseLabel, baseValue, applied,
//   finalLabel, finalValue }. Sans correction 1/3 temps, final == base.
function noteInfo(rows, checks, columnCount, baremeTotal, override, tiersTemps) {
  var c = computeNote(rows, checks, columnCount, baremeTotal)
  var total = c.total
  if (c.max === 0) {
    return { computed: c, rawLabel: "", scaled: false, baseLabel: "", baseValue: "",
      applied: false, finalLabel: "", finalValue: "" }
  }
  var ov = String(override === undefined || override === null ? "" : override).trim()
  var baseValue = ov !== "" ? ov : formatNote(c.note)
  var baseNum = ov !== "" ? parseNote(ov) : roundHalf(c.note)
  var applied = !!tiersTemps && !isNaN(baseNum)
  var finalValue = applied ? formatNote(tiersTempsNote(baseNum, total)) : baseValue
  return {
    computed: c,
    rawLabel: c.rawLabel,
    scaled: c.max !== total,
    baseLabel: baseValue + " / " + total,
    baseValue: baseValue,
    applied: applied,
    finalLabel: finalValue + " / " + total,
    finalValue: finalValue
  }
}

// Répartition des items par colonne, pour la ligne de synthèse du PDF et
// du popover ("Oui : 18 · Partiel : 6 · Non : 6").
function tally(rows, checks, columns) {
  var list = Array.isArray(rows) ? rows : []
  var cols = Array.isArray(columns) ? columns : []
  var c = checks || {}
  var counts = cols.map(function() { return 0 })
  var missing = 0
  for (var i = 0; i < list.length; i++) {
    var level = c[String(i)]
    if (level === undefined || level === null || counts[level] === undefined) { missing++; continue }
    counts[level]++
  }
  return { counts: counts, missing: missing }
}

// ---- export Typst --------------------------------------------------------

function escapeTypst(s) {
  return String(s || "").replace(/[\\#*_$<>@`]/g, "\\$&")
}

function currentSchoolYear() {
  var now = new Date()
  var y = now.getFullYear()
  return (now.getMonth() + 1 >= 9) ? (y + "-" + (y + 1)) : ((y - 1) + "-" + y)
}

// La grille corrigée d'UN élève, telle qu'elle sort du popover : même
// tableau que le .docx d'origine, les cases cochées, le décompte et la
// note en bas. payload: { checks, answers, doubts, includeAnswers, note }.
function buildTypstSource(studentLabel, className, intitule, columns, rows, payload) {
  return typstPreamble(className) + "\n" + buildTypstBody(studentLabel, intitule, columns, rows, payload)
}

function typstPreamble(className) {
  var lines = []
  lines.push("#set page(")
  lines.push("  margin: 2cm,")
  lines.push("  footer: align(center)[_M.Harfield - " + escapeTypst(className) + " - " + currentSchoolYear() + "_]")
  lines.push(")")
  lines.push("#set text(size: 10pt, lang: \"fr\", hyphenate: true)")
  lines.push("")
  return lines.join("\n")
}

// Toutes les fiches d'une classe dans UN document (une par page, pied de
// page commun) — même principe que CompetencyGrids.buildClassEvaluationTypst.
// entries: [{ studentLabel, payload }].
function buildClassTypst(className, intitule, columns, rows, entries) {
  var bodies = (entries || []).map(function(e) {
    return buildTypstBody(e.studentLabel, intitule, columns, rows, e.payload)
  })
  return typstPreamble(className) + "\n" + bodies.join("\n\n#pagebreak()\n\n")
}

function buildTypstBody(studentLabel, intitule, columns, rows, payload) {
  var p = payload || {}
  var checks = p.checks || {}
  var answers = p.answers || {}
  var doubts = p.doubts || {}
  var cols = Array.isArray(columns) ? columns : []
  var list = Array.isArray(rows) ? rows : []
  var lines = []

  if (String(intitule || "").trim()) {
    lines.push("#align(center)[#text(size: 13pt, weight: \"bold\")[" + escapeTypst(intitule) + "]]")
    lines.push("#v(0.6em)")
  }
  lines.push("#text(size: 14pt, weight: \"bold\")[" + escapeTypst(studentLabel) + "]")
  lines.push("#v(0.6em)")
  lines.push("")

  var colSpec = cols.map(function() { return "1.6cm" }).join(", ")
  lines.push("#table(")
  lines.push("  columns: (1fr, " + colSpec + "),")
  lines.push("  align: (left" + cols.map(function() { return ", center" }).join("") + "),")
  lines.push("  table.header([*Constituant à analyser*]" + cols.map(function(c) { return ", [*" + escapeTypst(c) + "*]" }).join("") + "),")
  list.forEach(function(row, idx) {
    var cells = cols.map(function(_, ci) { return "[" + (checks[String(idx)] === ci ? "X" : "") + "]" })
    lines.push("  [" + escapeTypst(plainLabel(row.text)) + "], " + cells.join(", ") + ",")
  })
  lines.push(")")
  lines.push("")

  if (p.includeAnswers) {
    var anyAnswer = list.some(function(_, idx) { return String(answers[String(idx)] || "").trim() !== "" })
    if (anyAnswer) {
      lines.push("#v(0.8em)")
      lines.push("*Ce qui a été lu sur la copie*")
      lines.push("")
      list.forEach(function(row, idx) {
        var a = String(answers[String(idx)] || "").trim()
        if (!a) return
        lines.push("- *" + escapeTypst(plainLabel(row.text)) + "* — " + escapeTypst(a))
      })
      lines.push("")
    }
    var anyDoubt = list.some(function(_, idx) { return String(doubts[String(idx)] || "").trim() !== "" })
    if (anyDoubt) {
      lines.push("#v(0.6em)")
      lines.push("*Arbitrages signalés*")
      lines.push("")
      list.forEach(function(row, idx) {
        var d = String(doubts[String(idx)] || "").trim()
        if (!d) return
        lines.push("- *" + escapeTypst(plainLabel(row.text)) + "* — " + escapeTypst(d))
      })
      lines.push("")
    }
  }

  var t = tally(list, checks, cols)
  var summary = cols.map(function(c, ci) {
    return escapeTypst(c) + " : " + t.counts[ci] + " × " + columnPointsLabel(ci, cols.length) + " pt"
  }).join(" #h(1.2em) ")
  lines.push("#v(1em)")
  lines.push(summary)
  lines.push("")
  lines.push("#v(0.4em)")
  if (p.tiersTemps) {
    // X/30 = X/20 ⇒ X/20 (1/3 temps) ; sans conversion de barème (items
    // déjà sur le barème), seulement deux chiffres.
    var chain = (p.scaled ? escapeTypst(String(p.rawLabel || "")) + " = " : "")
      + escapeTypst(String(p.noteLabel || "")) + " → " + escapeTypst(String(p.finalLabel || ""))
    lines.push("#text(size: 12pt, weight: \"bold\")[" + (p.scaled ? "Total : " : "Note : ") + chain + "]")
    lines.push("")
    lines.push("#text(size: 9pt, style: \"italic\")[Après prise en compte du 1/3 temps.]")
  } else {
    lines.push("#text(size: 12pt, weight: \"bold\")[Total : " + escapeTypst(String(p.rawLabel || "")) + " #h(1.2em) Note : " + escapeTypst(String(p.noteLabel || "")) + "]")
  }
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    GRID_FILENAMES: GRID_FILENAMES,
    readDocxCommand: readDocxCommand, readTextCommand: readTextCommand,
    isDocx: isDocx, extractBlocks: extractBlocks, cellText: cellText,
    plainLabel: plainLabel, parseDocx: parseDocx, parseText: parseText, parse: parse,
    columnFraction: columnFraction, columnPointsLabel: columnPointsLabel,
    formatNote: formatNote, computeNote: computeNote, tally: tally,
    TIERS_TEMPS_K: TIERS_TEMPS_K, roundHalf: roundHalf, tiersTempsNote: tiersTempsNote, noteInfo: noteInfo,
    buildTypstSource: buildTypstSource, buildClassTypst: buildClassTypst
  }
}

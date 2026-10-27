.pragma library

// "Rapport de correction" (Gabriel, 2026-10-21): a class-level PDF for one
// évaluation graded with a competency grid — per criterion, the number of
// students at each palier (plain counting, done here, never by the agent)
// plus a synthesis of the recurring faults written from the per-critère
// justifications of every copy. Anonymous by design: no student name ever
// reaches the agent or the PDF — the report prepares a remediation lesson,
// it is not a ranking. Text-only agent calls, one per criterion.

var COLUMNS = ["Non maîtrisé", "Insuffisamment maîtrisé", "En cours de maîtrise", "Maîtrisé"]

function escapeTypst(s) {
  return String(s || "").replace(/[\\#*_$<>@`]/g, "\\$&")
}

function currentSchoolYear() {
  var now = new Date()
  var y = now.getFullYear()
  return (now.getMonth() + 1 >= 9) ? (y + "-" + (y + 1)) : ((y - 1) + "-" + y)
}

// "13,5" / "13.5" / 13.5 -> number, NaN when blank or unparsable.
function parseNote(v) {
  var n = parseFloat(String(v === undefined || v === null ? "" : v).replace(",", "."))
  return isNaN(n) ? NaN : n
}

function formatNote(n) {
  var r = Math.round(n * 10) / 10
  return String(r).replace(".", ",")
}

// entries: [{ checks: {rowIdx: colIdx}, justifications: {rowIdx: text}, note }]
// -> { copies, noteStats: {mean,min,max,count}|null, rows: [{ idx, counts: [4], total }] }
// Only checkable rows, in grid order. A student who has no tick on a row is
// not counted for it.
function computeStats(grid, entries) {
  var rows = []
  ;(grid.rows || []).forEach(function(row, idx) {
    // Hybrid grid: the teacher's own rows are not summarised (the agent
    // never saw them).
    if (!row.checkable || row.owner === "teacher") return
    var counts = [0, 0, 0, 0]
    ;(entries || []).forEach(function(e) {
      var c = (e.checks || {})[idx]
      if (c !== undefined && c >= 0 && c <= 3) counts[c] += 1
    })
    rows.push({ idx: idx, text: row.text, counts: counts, total: counts[0] + counts[1] + counts[2] + counts[3] })
  })
  var notes = (entries || []).map(function(e) { return parseNote(e.note) }).filter(function(n) { return !isNaN(n) })
  var noteStats = null
  if (notes.length > 0) {
    var sum = notes.reduce(function(a, b) { return a + b }, 0)
    noteStats = { mean: sum / notes.length, min: Math.min.apply(null, notes), max: Math.max.apply(null, notes), count: notes.length }
  }
  return { copies: (entries || []).length, noteStats: noteStats, notes: notes, rows: rows }
}

// The non-"Maîtrisé" justifications of one criterion, anonymous.
function collectItems(rowIdx, entries) {
  var items = []
  ;(entries || []).forEach(function(e) {
    var c = (e.checks || {})[rowIdx]
    var j = String((e.justifications || {})[rowIdx] || "").trim()
    if (c === undefined || c >= 3 || !j) return
    items.push({ palier: COLUMNS[c], justification: j })
  })
  return items
}

// Prompt for ONE criterion. No tools, no copy: the justifications are the
// only source (they are already grounded in each copy).
function buildCriterionPrompt(params) {
  var p = params || {}
  var counts = p.counts || [0, 0, 0, 0]
  var lines = []
  lines.push("Tu rédiges un passage du RAPPORT DE CLASSE d'une correction : pour UN critère, tu synthétises les remarques déjà faites sur chaque copie, afin que l'enseignant prépare une séance de remédiation. Tu n'as pas accès aux copies : tu t'appuies UNIQUEMENT sur les remarques ci-dessous.")
  lines.push("")
  lines.push("## Contexte")
  lines.push("Devoir : " + String(p.evaluationTitle || "") + (p.className ? " (" + String(p.className) + ")" : ""))
  lines.push("Grille : " + String(p.gridName || ""))
  lines.push("Critère : " + String(p.criterionText || ""))
  lines.push("")
  lines.push("## Répartition de la classe sur ce critère (comptage exact, à ne pas contester)")
  COLUMNS.forEach(function(c, i) { lines.push("- " + c + " : " + counts[i] + " élève(s)") })
  lines.push("")
  lines.push("## Remarques faites sur les copies qui ne sont pas au palier « Maîtrisé » (une par copie, anonymes)")
  ;(p.items || []).forEach(function(it, i) {
    lines.push((i + 1) + ". [" + it.palier + "] " + it.justification)
  })
  lines.push("")
  lines.push("## Règles")
  lines.push("- Le palier indiqué entre crochets fait foi : si une remarque semble le contredire (l'enseignant a pu corriger le palier après coup), ne reprends de la remarque que les faits.")
  lines.push("- Regroupe les fautes par TYPE (par ex. « homonymes grammaticaux », « accents manquants », « paraphrase au lieu d'analyse », « contresens sur tel enjeu »), du plus fréquent au moins fréquent, et donne un nombre APPROXIMATIF d'élèves concernés pour chacun (« une dizaine », « 3 à 4 », « presque tous »), sans inventer de chiffre précis que les remarques ne permettent pas d'établir.")
  lines.push("- Sois concret : cite le type de faute ou l'erreur de lecture précise, pas une généralité (« des fautes d'orthographe »). Une citation brève de la copie reprise dans une remarque est autorisée comme exemple ; ne cite jamais un nom d'élève (il n'y en a pas).")
  lines.push("- N'invente rien : si les remarques ne disent rien sur un point, n'en parle pas. Aucun compliment ni conseil à l'élève : c'est une synthèse destinée à l'enseignant.")
  lines.push("- Style : phrases complètes et sobres, sans mise en forme (ni gras, ni titres, ni tirets dans la synthèse).")
  lines.push("")
  lines.push("## Format de réponse strict — rien d'autre avant ou après")
  lines.push("SYNTHÈSE: <un paragraphe de 3 à 5 phrases : état général de la classe sur ce critère et fautes dominantes>")
  lines.push("FAUTES:")
  lines.push("- <type de faute> | <nombre approximatif d'élèves> | <une phrase d'explication, avec un exemple si possible>")
  lines.push("(de 2 à 6 lignes, de la plus à la moins fréquente)")
  return lines.join("\n")
}

// -> { synthese: string, fautes: [{ type, nombre, detail }] }
function parseCriterion(text) {
  var t = String(text || "").replace(/\r/g, "")
  var synth = ""
  var m = t.match(/SYNTH[ÈE]SE\s*:\s*([\s\S]*?)(?=\n\s*FAUTES\s*:|$)/i)
  if (m) synth = m[1].trim().replace(/\s*\n\s*/g, " ")
  var fautes = []
  var fm = t.match(/FAUTES\s*:\s*([\s\S]*)$/i)
  if (fm) {
    fm[1].split("\n").forEach(function(line) {
      var l = line.trim()
      if (!/^[-•*]/.test(l)) return
      l = l.replace(/^[-•*]\s*/, "")
      var parts = l.split("|").map(function(x) { return x.trim() })
      if (!parts[0]) return
      fautes.push({ type: parts[0], nombre: parts[1] || "", detail: parts.slice(2).join(" — ") })
    })
  }
  return { synthese: synth, fautes: fautes.slice(0, 8) }
}

// sections: [{ text (criterion), counts: [4], total, synthese, fautes }]
function buildReportTypst(params) {
  var p = params || {}
  var stats = p.stats || { copies: 0, noteStats: null }
  var footer = "M.Harfield - " + escapeTypst(p.className) + " - " + currentSchoolYear()
  var L = []
  L.push("#set page(margin: 2cm, footer: align(center)[_" + footer + "_])")
  L.push("#set text(size: 11pt, lang: \"fr\", hyphenate: true)")
  L.push("#set par(justify: false)")
  L.push("")
  L.push("#align(center)[#text(size: 16pt, weight: \"bold\")[Rapport de correction]]")
  L.push("#align(center)[#text(size: 13pt, weight: \"bold\")[" + escapeTypst(p.evaluationTitle) + "]]")
  L.push("#align(center)[" + escapeTypst(p.className) + " — " + escapeTypst(p.gridName) + "]")
  L.push("#v(0.8em)")
  var meta = stats.copies + " copie" + (stats.copies > 1 ? "s" : "") + " corrigée" + (stats.copies > 1 ? "s" : "")
  if (stats.noteStats) {
    meta += " · moyenne " + formatNote(stats.noteStats.mean) + "/" + (p.baremeTotal || 20)
      + " · de " + formatNote(stats.noteStats.min) + " à " + formatNote(stats.noteStats.max)
  }
  L.push("#align(center)[" + escapeTypst(meta) + "]")
  L.push("#v(1em)")
  ;(p.sections || []).forEach(function(sec) {
    L.push("#block(breakable: false)[")
    L.push("#text(size: 12pt, weight: \"bold\")[" + escapeTypst(sec.text) + "]")
    L.push("#v(0.3em)")
    var total = sec.total || 0
    var cells = COLUMNS.map(function(c, i) {
      var n = sec.counts[i]
      var pct = total > 0 ? Math.round(100 * n / total) : 0
      return "[" + n + " (" + pct + " %)]"
    })
    L.push("#table(columns: (1fr, 1fr, 1fr, 1fr), align: center,")
    L.push("  table.header(" + COLUMNS.map(function(c) { return "[*" + escapeTypst(c) + "*]" }).join(", ") + "),")
    L.push("  " + cells.join(", "))
    L.push(")")
    if (sec.synthese) {
      L.push("#v(0.4em)")
      L.push(escapeTypst(sec.synthese))
    }
    if ((sec.fautes || []).length > 0) {
      L.push("#v(0.3em)")
      sec.fautes.forEach(function(f) {
        var line = "- *" + escapeTypst(f.type) + "*"
        if (f.nombre) line += " (" + escapeTypst(f.nombre) + ")"
        if (f.detail) line += " : " + escapeTypst(f.detail)
        L.push(line)
      })
    }
    L.push("]")
    L.push("#v(1em)")
  })
  return L.join("\n")
}


// ---- version élèves / familles (Gabriel, 2026-10-21) --------------------
// One page: EVERY criterion in the grid's order, each with its coloured bar,
// its count and one short sentence — no ranking, no advice (the individual
// fiches already carry the advice). The code does all the counting; ONE
// text-only agent call writes the sentences from the full report's
// syntheses, with real quotes only where Gabriel asked for them
// (contresens, syntaxe, style), never names.

// Criteria whose sentence may carry real quotes from the copies.
function quotesAllowed(text) {
  return /comprend|syntaxi|style|orthograph/i.test(String(text || ""))
}

// sections: the full report's sections, in grid order.
function buildStudentSummaryPrompt(params) {
  var p = params || {}
  var L = []
  L.push("Tu rédiges le résumé d'UNE PAGE d'un bilan de classe destiné aux ÉLÈVES et à leurs FAMILLES, à partir du rapport détaillé de l'enseignant ci-dessous. Tu n'as pas accès aux copies.")
  L.push("")
  L.push("## Contexte")
  L.push("Devoir : " + String(p.evaluationTitle || "") + " (" + String(p.className || "") + ")")
  L.push("")
  L.push("## Critères, dans l'ordre de la fiche (extraits du rapport de l'enseignant)")
  ;(p.sections || []).forEach(function(sec, i) {
    L.push("")
    L.push("### " + (i + 1) + ". " + sec.text + (quotesAllowed(sec.text) ? "   [EXEMPLES TIRÉS DES COPIES AUTORISÉS]" : ""))
    L.push("Répartition : " + COLUMNS.map(function(c, k) { return c + " " + sec.counts[k] }).join(" ; "))
    L.push("Synthèse : " + sec.synthese)
    ;(sec.fautes || []).slice(0, 4).forEach(function(f) {
      L.push("- " + f.type + (f.nombre ? " (" + f.nombre + ")" : "") + (f.detail ? " : " + f.detail : ""))
    })
  })
  L.push("")
  L.push("## Règles")
  L.push("- Lecteurs : élèves et parents. Ton factuel, clair et bienveillant sans rien édulcorer : tu décris ce que la CLASSE a réussi ou non, jamais une personne. Formulation impersonnelle ou vouvoiement, jamais de tutoiement. Aucun conseil : les fiches individuelles en donnent déjà.")
  L.push("- Pour CHAQUE critère, dans l'ordre : UNE phrase (deux au plus), brève, qui dit où en est la classe (ce qui est réussi, la faute ou l'erreur dominante). Ne reformule pas les chiffres, déjà affichés à côté.")
  L.push("- Pour les critères marqués [EXEMPLES TIRÉS DES COPIES AUTORISÉS] (compréhension, orthographe et syntaxe, style), tu peux illustrer par 1 ou 2 courts exemples réels, repris MOT POUR MOT des remarques ci-dessus et placés entre guillemets (un contresens, une tournure fautive, une phrase mal construite). Pour les autres critères, aucune citation. N'invente jamais d'exemple, ne cite jamais un nom.")
  L.push("- Reste fidèle à la répartition donnée : ne présente jamais comme réussi ce qui ne l'est pas ; si un critère est maîtrisé par toute la classe, dis-le en quelques mots.")
  L.push("")
  L.push("## Format de réponse strict — rien d'autre avant ou après")
  L.push("CRITERE: <numéro> | <phrase>")
  L.push("(une ligne par critère, avec le numéro donné plus haut, toutes les lignes présentes)")
  return L.join("\n")
}

// -> { byNumber: { n: text } }
function parseStudentSummary(text) {
  var byNumber = {}
  String(text || "").split("\n").forEach(function(line) {
    var m = line.trim().match(/^CRIT[ÈE]RE\s*:\s*(\d+)\s*\|\s*([\s\S]+)$/i)
    if (m) byNumber[Number(m[1])] = m[2].trim()
  })
  return { byNumber: byNumber }
}

// First sentence of a synthesis, used when the agent call fails.
function firstSentence(text) {
  var t = String(text || "").trim()
  var m = t.match(/^[\s\S]*?[.!?](?=\s|$)/)
  return m ? m[0] : t
}

var BAR_COLORS = ["rgb(\"#c0392b\")", "rgb(\"#e67e22\")", "rgb(\"#f1c40f\")", "rgb(\"#27ae60\")"]

function barTypst(counts, total, widthCm) {
  var parts = []
  counts.forEach(function(n, i) {
    if (n <= 0 || total <= 0) return
    parts.push("rect(width: " + (widthCm * n / total).toFixed(3) + "cm, height: 8pt, fill: " + BAR_COLORS[i] + ", stroke: none)")
  })
  return "#stack(dir: ltr, " + parts.join(", ") + ")"
}

// params: { className, evaluationTitle, baremeTotal, stats,
//   sections: [{ text, counts, total, sentence }] }
function buildStudentReportTypst(params) {
  var p = params || {}
  var stats = p.stats || { copies: 0, noteStats: null, notes: [] }
  var total = p.baremeTotal || 20
  var footer = "M.Harfield - " + escapeTypst(p.className) + " - " + currentSchoolYear()
  var L = []
  L.push("#set page(margin: (x: 1.8cm, y: 1.5cm), footer: align(center)[_" + footer + "_])")
  L.push("#set text(size: 9.5pt, lang: \"fr\", hyphenate: true)")
  L.push("#set par(justify: false, spacing: 0.5em)")
  L.push("")
  L.push("#align(center)[#text(size: 14pt, weight: \"bold\")[Bilan du devoir — " + escapeTypst(p.className) + "]]")
  L.push("#align(center)[" + escapeTypst(p.evaluationTitle) + "]")
  L.push("#v(0.3em)")
  var meta = stats.copies + " copies"
  if (stats.noteStats) {
    meta += " · moyenne de la classe " + formatNote(stats.noteStats.mean) + "/" + total
      + " · notes de " + formatNote(stats.noteStats.min) + " à " + formatNote(stats.noteStats.max)
    var hi = stats.notes.filter(function(n) { return n >= 12 * total / 20 }).length
    var lo = stats.notes.filter(function(n) { return n < 8 * total / 20 }).length
    meta += " · " + hi + " note" + (hi > 1 ? "s" : "") + " d'au moins " + formatNote(12 * total / 20) + " · " + lo + " en dessous de " + formatNote(8 * total / 20)
  }
  L.push("#align(center)[#text(size: 9pt)[" + escapeTypst(meta) + "]]")
  L.push("#v(0.2em)")
  L.push("#align(center)[#text(size: 8pt)[" + COLUMNS.map(function(c, i) { return "#box(rect(width: 7pt, height: 7pt, fill: " + BAR_COLORS[i] + ", stroke: none)) " + escapeTypst(c) }).join("  ") + "]]")
  L.push("#v(0.5em)")
  ;(p.sections || []).forEach(function(sec) {
    var okn = sec.counts[2] + sec.counts[3]
    L.push("#block(breakable: false)[")
    L.push("#grid(columns: (1fr, 5cm), column-gutter: 0.5em, align: (left, right), [*" + escapeTypst(sec.text) + "*], [" + barTypst(sec.counts, sec.total, 5) + "])")
    L.push("#v(-0.2em)")
    L.push("#text(size: 8pt, fill: luma(100))[" + okn + "/" + sec.total + " au niveau attendu ou au-dessus.] " + escapeTypst(sec.sentence))
    L.push("]")
    L.push("#v(0.3em)")
  })
  return L.join("\n")
}

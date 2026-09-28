// Prompts for the grid-first correction agent (Gabriel, 2026-09-27):
// unlike the older free-form CorrectionPromptBuilder.js (which asks the
// agent to read a copy and go straight to a 3-paragraph appreciation +
// three continuous grades), this agent's ONLY job is to fill a competency
// grid — choosing exactly one of the 4 CompetencyGrids.COLUMNS levels per
// checkable row, against the grid's own written palier descriptions
// (CompetencyGrids.buildGridRubricText). Writing the appreciation itself
// is then a SEPARATE, already-validated step reusing
// PromptBuilder.buildEvalAppreciationPrompt verbatim, unchanged — see
// [[gh-corrections-plugin]] for why this split (calibration is the hard
// part, not the write-up) tested more reliably than the old single-shot
// prompt on TP 1SCHA Sujet A (2026-09-25/27).

.pragma library

// params: { copyPath, writingMode, sujetPath, corrigePath, niveauClasse,
// bienveillance, complements, gridName, gridRubricText, rows (grid.rows) }
function buildFillGridPrompt(params) {
  var p = params || {}
  var lines = []
  var writingMode = p.writingMode === "tapuscrit" ? "tapuscrit" : "manuscrit"
  var checkableRows = (p.rows || []).filter(function(r) { return r.checkable })

  lines.push("Tu es un agent de correction pédagogique, invoqué automatiquement et sans supervision humaine immédiate.")
  lines.push("")
  lines.push("## Ta tâche, et UNIQUEMENT celle-ci")
  lines.push("Tu ne rédiges PAS d'appréciation dans cette étape. Ta seule tâche est de REMPLIR UNE GRILLE D'ÉVALUATION PAR COMPÉTENCES : pour chacun des " + checkableRows.length + " critères listés plus bas, tu choisis EXACTEMENT UN des 4 paliers, en te basant strictement sur les descriptions officielles de chaque palier données ci-dessous — pas sur ton impression générale de la copie.")
  lines.push("")
  lines.push("## Élève concerné")
  lines.push("Cette correction est anonymisée à dessein : ni le nom de l'élève, ni le nom du fichier ne te sont communiqués, et le fichier de la copie a été renommé pour ne porter aucune trace de son identité. Ne cherche jamais à deviner qui est l'élève.")
  lines.push("Copie à corriger (PDF) : " + String(p.copyPath || ""))
  lines.push("Type d'écriture : " + (writingMode === "manuscrit" ? "manuscrite" : "tapuscrite"))
  if (writingMode === "manuscrit") {
    lines.push("Sois prudent dans le déchiffrage : si un mot est illisible ou ambigu, ne devine pas silencieusement — signale-le dans les points de vigilance (voir plus bas), et mentionne-le aussi dans la justification du critère concerné s'il en affecte le jugement.")
  }
  lines.push("")
  if (p.niveauClasse || p.bienveillance !== undefined || p.complements) {
    lines.push("## Contexte de la classe — à prendre en compte pour calibrer tes attentes")
    if (p.niveauClasse) lines.push("Niveau de classe : " + String(p.niveauClasse) + ".")
    if (p.bienveillance !== undefined && p.bienveillance !== "") {
      lines.push("Niveau de bienveillance demandé : " + String(p.bienveillance) + "/10 (0 = très sévère, 10 = très bienveillant) — en cas de doute réel entre deux paliers adjacents pour un même critère, penche vers le palier le plus favorable à l'élève.")
    }
    if (p.complements) {
      lines.push("Complément propre à cette évaluation : " + String(p.complements))
    }
    lines.push("")
  }
  lines.push("## Fichiers de référence")
  lines.push("- Sujet (PDF) : " + String(p.sujetPath || ""))
  if (p.corrigePath) {
    lines.push("- Corrigé (PDF) : " + String(p.corrigePath))
  } else {
    lines.push("- Corrigé : aucun fourni pour cette évaluation — base-toi uniquement sur le sujet pour évaluer la copie.")
  }
  lines.push("")
  lines.push("## Grille à remplir — " + checkableRows.length + " critères, avec la description officielle de chaque palier")
  lines.push(String(p.gridRubricText || ""))
  lines.push("")
  lines.push("## Format de réponse strict — réponds UNIQUEMENT avec ce format, rien d'autre avant ou après")
  lines.push("D'abord, une section de points de vigilance (doutes de lecture, passages illisibles ou ambigus — PAS un résumé de ton jugement, seulement ce qui mériterait une vérification directe de la copie par l'enseignant) :")
  lines.push("")
  lines.push("## Points de vigilance")
  lines.push("- <un point par ligne, commençant par \"- \", synthétique>")
  lines.push("(ou, si aucune remarque : écris exactement RAS)")
  lines.push("")
  lines.push("Puis, un bloc de 3 lignes par critère, DANS L'ORDRE où les critères sont listés ci-dessus, séparés par une ligne vide :")
  lines.push("")
  lines.push("CRITERE: <texte exact du critère>")
  lines.push("PALIER: <" + "Non maîtrisé|Insuffisamment maîtrisé|En cours de maîtrise|Maîtrisé" + ">")
  lines.push("JUSTIFICATION: <2 à 4 phrases maximum, avec citation exacte de la copie si pertinent>")
  lines.push("")
  lines.push("## Consignes techniques")
  lines.push("- Ne lis aucun fichier en dehors de ceux listés ci-dessus (sujet, corrigé, copie de l'élève).")
  lines.push("- N'écris aucun fichier. Réponds uniquement sur la sortie standard, dans le format ci-dessus.")
  lines.push("- Ne pose aucune question : personne ne peut te répondre dans l'immédiat.")
  return lines.join("\n")
}

// Parses buildFillGridPrompt's output back into { log, checks, justifications }
// — checks/justifications keyed by the row's index in the FULL rows array
// (including non-checkable header rows), matching CompetencyGrids' own
// row numbering (see StudentCorrection.competencyChecks). Tolerant: a
// missing or unparseable block just leaves that row unset rather than
// failing the whole parse, same posture as the rest of this codebase's
// parsing (CorrectionPromptBuilder.parseGrades, Files.js...).
function parseFilledGrid(text, rows) {
  var t = String(text || "")
  var logMatch = t.match(/##\s*Points de vigilance\s*\n([\s\S]*?)(?=\n##|\nCRITERE:|$)/i)
  var log = logMatch ? logMatch[1].trim() : ""

  var checkableRows = (rows || []).map(function(r, idx) { return { row: r, idx: idx } }).filter(function(x) { return x.row.checkable })
  var blocks = t.split(/\n(?=CRITERE:)/)
  var byCriterionText = {}
  blocks.forEach(function(b) {
    var critM = b.match(/CRITERE:\s*(.+)/)
    var palM = b.match(/PALIER:\s*(.+)/)
    var justM = b.match(/JUSTIFICATION:\s*([\s\S]*?)(?=\nCRITERE:|$)/)
    if (!critM || !palM) return
    byCriterionText[critM[1].trim()] = {
      palier: palM[1].trim(),
      justification: justM ? justM[1].trim() : ""
    }
  })

  var columnNames = ["non maîtrisé", "insuffisamment maîtrisé", "en cours de maîtrise", "maîtrisé"]
  var checks = {}
  var justifications = {}
  checkableRows.forEach(function(x) {
    var entry = byCriterionText[x.row.text]
    if (!entry) return
    var colIdx = columnNames.indexOf(String(entry.palier).toLowerCase())
    if (colIdx !== -1) checks[x.idx] = colIdx
    if (entry.justification) justifications[x.idx] = entry.justification
  })

  return { log: log, checks: checks, justifications: justifications }
}

// The note range used to be a third agent call here (buildNoteRangePrompt/
// parseNoteRange) — removed 2026-09-27 in favor of
// CompetencyGrids.computeWeightedNote(), a deterministic calculation from
// the filled grid + Gabriel's own per-criterion weights. See
// [[gh-corrections-plugin]].

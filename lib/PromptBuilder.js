// Builds the headless-Claude prompt for the appreciation generator.
// v1 is deliberately minimal (Gabriel's own scoping): three free-text
// instruction fields, a max-character constraint, one shot, no student
// database wiring yet — he plans to layer in référentiel/compétences
// data over time.

.pragma library

var MODES = {
  copies: { label: "Copie", fields: [
    { key: "methode", label: "Méthode" },
    { key: "contenu", label: "Contenu" },
    { key: "expression", label: "Expression" }
  ]},
  bulletin: { label: "Bulletin", fields: [
    { key: "travail", label: "Travail" },
    { key: "comportement", label: "Comportement" },
    { key: "axe", label: "Axe de progression" }
  ]}
}

// Fixed conversion scale from a competency grid's mastery levels to a /20
// grade — same for every grid/assignment, per Gabriel's own barème.
var NOTE_ESTIMATE_SCALE = [
  "Maîtrisé : 18 à 20",
  "En cours de maîtrise : 12 à 17",
  "Insuffisamment maîtrisé : 7 à 11",
  "Non maîtrisé : 1 à 6"
]

// rows: grid.rows (only .checkable ones matter); checks: { [rowIndex]: colIndex };
// columns: the 4 level labels in colIndex order (0..3); appreciation: free text.
function buildNoteEstimatePrompt(gridName, rows, columns, checks, appreciation) {
  var lines = []
  lines.push("Tu es un professeur de lettres qui doit proposer une estimation chiffrée d'une note sur 20, à partir d'une grille de compétences déjà remplie et d'une appréciation déjà rédigée par le professeur.")
  lines.push("")
  lines.push("Barème de conversion (fixe, à respecter strictement) :")
  NOTE_ESTIMATE_SCALE.forEach(function(line) { lines.push("- " + line) })
  lines.push("")
  lines.push("Grille \"" + gridName + "\", niveau coché par critère :")
  rows.forEach(function(row, idx) {
    if (!row.checkable) return
    var level = checks[idx]
    var label = (level === undefined || level === null) ? "non évalué" : (columns[level] || "non évalué")
    lines.push("- " + row.text + " : " + label)
  })
  lines.push("")
  lines.push("Appréciation écrite du professeur : " + (String(appreciation || "").trim() || "(aucune appréciation renseignée)"))
  lines.push("")
  lines.push("En te basant sur la répartition des niveaux cochés et sur le ton de l'appréciation, propose UNE SEULE note cohérente avec le barème ci-dessus.")
  lines.push("Réponds UNIQUEMENT par un nombre entre 1 et 20 (une décimale autorisée), sans unité, sans phrase, sans aucun autre texte.")
  return lines.join("\n")
}

// Gabriel, 2026-09-28: he can find the agent's default length ("moyenne")
// too long and had no quick way to shorten it — a dropdown next to
// "Régénérer l'appréciation" picks one of these three per regeneration.
// "moyenne" reproduces the original fixed wording verbatim so existing
// appreciations aren't affected by this feature's addition.
function appreciationLengthInstruction(length) {
  if (length === "courte") return "Un texte très resserré qui enchaîne ces trois temps dans l'ordre ci-dessus en une seule phrase par partie (trois phrases au total), dense mais claire, pas une liste à puces, pas de titres de section visibles."
  if (length === "longue") return "Un texte développé qui enchaîne ces trois temps dans l'ordre ci-dessus, deux à trois phrases par partie, pouvant détailler davantage les observations disponibles tout en restant fluide, pas une liste à puces, pas de titres de section visibles."
  return "Un texte fluide de quelques phrases qui enchaîne ces trois temps dans l'ordre ci-dessus, pas une liste à puces, pas de titres de section visibles."
}

// rows/columns/checks: same shape as buildNoteEstimatePrompt above. note is
// optional (the grade already entered, if any) — purely context, the model
// is never asked to justify or restate it. Gabriel's fixed rules, 2026-09-26:
// realistic without discouraging, always "vous", always method/contenu/
// expression in that order. addendum (Gabriel, 2026-09-27) is an optional
// one-shot instruction from the teacher for THIS rédaction only (ex. "l'axe
// II, bien que complet, est bâclé") — same spirit as the older single-shot
// pipeline's own addendum, consumed by the caller after use, not by this
// function. justifications (Gabriel, 2026-09-28) is optional, same shape as
// checks — { [rowIndex]: text } — the grid-fill agent's own per-criterion
// observation, kept around after Gabriel hand-edits a check so the wording
// can go stale relative to the (now-corrected) level; the prompt is told
// explicitly that the checked level, not the observation, is the final
// word whenever the two disagree. The Eval. Compétences tab (hand-checked
// boxes only, no agent observations) never has this, so omitting it
// reproduces the exact prior prompt, unchanged. length (Gabriel,
// 2026-09-28) is one of "courte"/"moyenne"/"longue" — "moyenne" (or
// anything unrecognized) keeps the original wording verbatim.
function buildEvalAppreciationPrompt(gridName, rows, columns, checks, note, addendum, justifications, length) {
  var lines = []
  lines.push("Tu es un professeur de lettres qui rédige une appréciation de copie d'élève, à partir d'une grille de compétences déjà remplie.")
  lines.push("")
  lines.push("Consignes strictes :")
  lines.push("- Réaliste et honnête sur le niveau réel, mais jamais décourageante : même un point faible se formule de façon constructive.")
  lines.push("- Vouvoiement obligatoire (\"vous\"), jamais de tutoiement.")
  lines.push("- Construite en exactement trois parties, dans cet ordre précis et sans exception : 1) méthode (organisation, démarche, structure du devoir) ; 2) contenu (compréhension, analyse, interprétation du texte) ; 3) expression écrite (langue, orthographe, style, niveau de langue). Ne commence jamais par le contenu ou l'expression.")
  lines.push("- " + appreciationLengthInstruction(length))
  if (justifications) {
    lines.push("- Sous certains critères ci-dessous figure une observation détaillée de la correction : utilise-la pour rendre l'appréciation concrète et personnelle plutôt que générique, mais reformule-la toujours avec tes propres mots — ne cite JAMAIS littéralement un mot, une expression ou une graphie tirée de la copie, pour éviter de propager une éventuelle erreur de lecture.")
    lines.push("- Si une observation semble en tension avec le niveau retenu pour ce critère, c'est ce niveau qui fait foi : il a pu être corrigé à la main par l'enseignant après la rédaction de l'observation.")
  }
  lines.push("")
  lines.push("Grille \"" + gridName + "\", niveau coché par critère :")
  rows.forEach(function(row, idx) {
    if (!row.checkable) return
    var level = checks[idx]
    var label = (level === undefined || level === null) ? "non évalué" : (columns[level] || "non évalué")
    lines.push("- " + row.text + " : " + label)
    var justification = justifications && String(justifications[idx] || "").trim()
    if (justification) lines.push("  Observation de la correction : " + justification)
  })
  var cleanNote = String(note || "").trim()
  if (cleanNote) {
    lines.push("")
    lines.push("Note déjà attribuée (contexte uniquement, ne pas la citer ni la justifier) : " + cleanNote + "/20")
  }
  var cleanAddendum = String(addendum || "").trim()
  if (cleanAddendum) {
    lines.push("")
    lines.push("Complément de l'enseignant à prendre en compte EN PRIORITÉ pour cette rédaction : " + cleanAddendum)
  }
  lines.push("")
  lines.push("Réponds UNIQUEMENT avec le texte de l'appréciation, sans guillemets, sans titre, sans commentaire additionnel, sans markdown.")
  return lines.join("\n")
}

function buildAppreciationPrompt(mode, values, maxChars) {
  var spec = MODES[mode] || MODES.copies
  var lines = []
  lines.push("Tu es un professeur de lettres qui rédige une appréciation " +
    (mode === "bulletin" ? "de bulletin scolaire" : "sur une copie d'élève") + ".")
  lines.push("Rédige UNE SEULE appréciation, en français, dans un registre professionnel et bienveillant, en te basant strictement sur les consignes ci-dessous.")
  lines.push("")
  for (var i = 0; i < spec.fields.length; i++) {
    var f = spec.fields[i]
    var v = String((values && values[f.key]) || "").trim()
    lines.push("- " + f.label + " : " + (v || "(rien de particulier à signaler)"))
  }
  lines.push("")
  lines.push("Contrainte stricte : l'appréciation ne doit pas dépasser " + maxChars + " caractères (espaces compris).")
  lines.push("Réponds UNIQUEMENT avec le texte de l'appréciation, sans guillemets, sans titre, sans commentaire additionnel, sans markdown.")
  return lines.join("\n")
}

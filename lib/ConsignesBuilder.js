// Generates consigne.md for a new évaluation, from the évaluation-creation
// wizard's own fields — replaces the old, separate "Assistant — Consignes"
// wizard (ui/ConsignesWizardPopover.qml, now unwired, see Panel.qml/Gabriel
// 2026-09-24): these parameters are no longer entered through a second popover
// invoked by hand, they're part of the évaluation-creation form itself, and
// consigne.md is written automatically at creation time — the teacher never
// points at or hand-edits a consignes.md path anymore.
//
// Option lists/labels/prose below are carried over as-is from the old wizard
// (ui/ConsignesWizardPopover.qml's PARAM_* fields, left on disk unwired) so
// the generated text stays close to what évaluations already had under the
// old flow; only "nature" gained a renamed 4th option (bac_blanc, was
// "blanc"/Épreuve blanche) and a new niveauClasse field was added (Gabriel,
// 2026-09-24).
//
// Structure of the generated file:
//   # Paramètres de cette évaluation (always present, built from the wizard fields)
//   # Barème de cette évaluation (only if "notée" is checked and a barème was typed)
//   # Compléments propres à cette évaluation (always present, free text)
//
// Gabriel, 2026-10-03: used to optionally prepend a fixed consignes corpus
// per exerciseType (ConsignesTemplateCommentaire.fixedBlock(), for
// "commentaire" only) — removed along with that file: commentaire/
// dissertation/essai now always go through the grid-first pipeline instead,
// which never generates consigne.md at all, so no exerciseType has (or needs)
// a fixed corpus here any more.
//
// Deliberately does not import ExerciseTypes.js itself (no other .js file in
// lib/ cross-imports another — Panel.qml is the one place that already
// imports every library module and glues them together, ex.
// CorrectionPromptBuilder.build() call sites — so this follows that same
// established pattern rather than introduce a new one).

.pragma library

var NATURE_OPTIONS = [
  { value: "tp_individuel", label: "TP individuel" },
  { value: "tp_groupe", label: "TP en groupe" },
  { value: "dst", label: "Devoir sur table" },
  { value: "bac_blanc", label: "Bac Blanc" }
]
var TYPE_OPTIONS = [
  { value: "diagnostique", label: "Diagnostique" },
  { value: "formative", label: "Formative" },
  { value: "sommative", label: "Sommative" }
]
var NIVEAU_CLASSE_OPTIONS = [
  { value: "2nde", label: "2nde" },
  { value: "1ere", label: "1ère" },
  { value: "terminale", label: "Terminale" }
]
var SURINTERPRETATION_OPTIONS = [
  { value: "strict", label: "Strict" },
  { value: "neutre", label: "Neutre" },
  { value: "permissif", label: "Permissif" }
]
var DETAIL_OPTIONS = [
  { value: "faible", label: "Faible" },
  { value: "moyen", label: "Moyen" },
  { value: "eleve", label: "Élevé" }
]

var SURINTERPRETATION_TEXT = {
  strict: "Strict : aucune surinterprétation n'est permise ; si l'agent ne comprend pas ce qu'il lit, il le signale dans le log et passe à la suite sans deviner.",
  neutre: "Neutre : l'agent peut combler une lacune laissée par l'élève afin d'en comprendre le sens, mais le signale et l'évite autant que possible, pour ne pas biaiser son appréciation finale.",
  permissif: "Permissif : l'agent surinterprète les propos de l'élève si besoin — utile par exemple pour évaluer une prise de notes d'analyse directement sur un extrait."
}
var DETAIL_TEXT = {
  faible: "Faible : appréciation elliptique, sans trop de détails, évasive.",
  moyen: "Moyen : appréciation de taille variable selon la quantité de choses à dire sur la copie, peut citer ou faire allusion à des passages de la copie évaluée.",
  eleve: "Élevé : appréciation détaillée, commentant certains passages (citation ou allusion) afin d'illustrer l'appréciation."
}

function labelFor(options, value) {
  for (var i = 0; i < options.length; i++) if (options[i].value === value) return options[i].label
  return value
}

function buildParamsBlock(p) {
  var lines = []
  lines.push("# Paramètres de cette évaluation")
  lines.push("")
  lines.push("- Nature de l'évaluation : " + labelFor(NATURE_OPTIONS, p.natureEvaluation))
  lines.push("- Type d'évaluation : " + labelFor(TYPE_OPTIONS, p.typeEvaluation))
  lines.push("- Durée de l'épreuve : " + p.dureeEpreuve + " minutes")
  lines.push("- Niveau de classe : " + labelFor(NIVEAU_CLASSE_OPTIONS, p.niveauClasse))
  lines.push("- Niveau de bienveillance : " + p.bienveillance + "/10 (0 = très sévère, 10 = très bienveillant)")
  lines.push("- Prise de notes acceptée : " + (p.priseDeNotes ? "Oui" : "Non (rédaction complète exigée)"))
  lines.push("- Le sujet doit être traité intégralement : " + (p.completudeExigee ? "Oui" : "Non"))
  lines.push("- Niveau de surinterprétation autorisé — " + SURINTERPRETATION_TEXT[p.surinterpretation])
  lines.push("- Niveau de détail de l'appréciation — " + DETAIL_TEXT[p.niveauDetail])
  lines.push("- Évaluation notée : " + (p.notee ? "Oui" : "Non (ne propose aucune note)"))
  return lines.join("\n")
}

// Gabriel, 2026-10-03: no exerciseType has a written barème template any
// more (see ExerciseTypes.js) — CorrectionPromptBuilder's note step had
// nothing to calibrate against. A dedicated "notée ?" toggle + scrollable
// barème field in the wizard gives it one.
function buildBaremeBlock(bareme) {
  var lines = []
  lines.push("# Barème de cette évaluation")
  lines.push("")
  lines.push(String(bareme || "").trim())
  return lines.join("\n")
}

function buildComplementsBlock(complements) {
  var lines = []
  lines.push("# Compléments propres à cette évaluation")
  lines.push("")
  lines.push("Aucun gabarit de consignes n'est écrit pour ce type d'exercice : les compléments")
  lines.push("ci-dessous doivent donc porter à eux seuls l'intégralité des attentes et de la")
  lines.push("méthode de correction (le barème, lui, a sa propre section ci-dessus si renseignée).")
  lines.push("")
  lines.push(String(complements || "").trim())
  return lines.join("\n")
}

// params: { exerciseType, natureEvaluation, typeEvaluation, dureeEpreuve,
//           niveauClasse, bienveillance, priseDeNotes, completudeExigee,
//           surinterpretation, niveauDetail, complements, notee, bareme }
function build(params) {
  var p = params || {}
  var blocks = []
  blocks.push(buildParamsBlock(p))
  if (p.notee && String(p.bareme || "").trim()) blocks.push(buildBaremeBlock(p.bareme))
  blocks.push(buildComplementsBlock(p.complements))
  return blocks.join("\n\n") + "\n"
}

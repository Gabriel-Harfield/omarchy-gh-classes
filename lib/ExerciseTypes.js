// Registry of exercise types selectable when creating an évaluation — Gabriel,
// 2026-09-24. Only "commentaire" has a written consignes template today (see
// ConsignesTemplateCommentaire.js) — the seven others exist as selectable
// options (so the évaluation records the right type for later) but fall back
// to a generic "no template yet" notice in the generated consignes.md until
// their own template is written.
//
// TYPES_WITH_PLAN_EXTRACTION: exercise types that are a single continuous
// piece of rédaction organized in axes/sous-parties (as opposed to a
// question-by-question exercise like a questionnaire de lecture, or a
// transformation exercise like une contraction/un résumé) — for these,
// CorrectionPromptBuilder.build() adds the plan-restitution step to the log
// (see the "Méthode — comment lire un commentaire rédigé" section of the
// commentaire template, generalized to dissertation/essai).

.pragma library

var TYPES = [
  { value: "commentaire", label: "Commentaire de texte" },
  { value: "dissertation", label: "Dissertation sur œuvre" },
  { value: "lecture_analytique", label: "Lecture analytique" },
  { value: "essai", label: "Essai" },
  { value: "contraction", label: "Contraction" },
  { value: "ecriture_invention", label: "Écrit d'invention" },
  { value: "questionnaire_lecture", label: "Questionnaire de lecture" },
  { value: "resume", label: "Résumé" }
]

var TYPES_WITH_TEMPLATE = ["commentaire"]
var TYPES_WITH_PLAN_EXTRACTION = ["commentaire", "dissertation", "essai"]

function labelFor(value) {
  for (var i = 0; i < TYPES.length; i++) if (TYPES[i].value === value) return TYPES[i].label
  return value
}

function hasTemplate(value) {
  return TYPES_WITH_TEMPLATE.indexOf(value) !== -1
}

function usesPlanExtraction(value) {
  return TYPES_WITH_PLAN_EXTRACTION.indexOf(value) !== -1
}

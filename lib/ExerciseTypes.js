// Registry of exercise types selectable when creating an évaluation — Gabriel,
// 2026-09-24. No type has a written fixed consignes template any more (the
// one that existed for "commentaire" was removed 2026-10-03: commentaire/
// dissertation/essai now always go through the grid-first pipeline instead —
// see Panel.qml's "Grille de compétences" selector — so consigne.md for any
// type selected here falls back to the generic "no template yet" notice.
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

var TYPES_WITH_PLAN_EXTRACTION = ["commentaire", "dissertation", "essai"]

function labelFor(value) {
  for (var i = 0; i < TYPES.length; i++) if (TYPES[i].value === value) return TYPES[i].label
  return value
}

function usesPlanExtraction(value) {
  return TYPES_WITH_PLAN_EXTRACTION.indexOf(value) !== -1
}

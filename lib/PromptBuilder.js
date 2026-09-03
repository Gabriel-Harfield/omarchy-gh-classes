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

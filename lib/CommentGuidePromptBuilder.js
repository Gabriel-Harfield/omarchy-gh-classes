// Second step of the "Commentaire guidé" pipeline (Gabriel, 2026-10-15):
// instead of the 3-paragraph appreciation (méthode/contenu/langue) that
// PromptBuilder.buildEvalAppreciationPrompt writes for the other grids, the
// agent turns the ALREADY-FILLED grid into a short list of factual bullet
// comments that it WRITES ITSELF. The Eval. Compétences comments bank was
// tried first (agent picks an entry by id, or writes a new one) and removed
// the same day after a real-copy test: the agent matched entries by theme
// rather than meaning (e.g. picked "on ne va à la ligne qu'à la fin du
// paragraphe" for a copy that had fused its sous-parties) and can't judge an
// entry's relevance — a structural limit, not a prompt bug. To be revisited
// once the bank is larger. Gabriel can still save any good bullet to the
// bank by hand ("＋ Banque"). The "commentaire personnel" (the former
// appreciation block) is deliberately DISCONNECTED for now (Gabriel,
// 2026-10-15): its role comes later, once the bank is rich enough for the
// agent to pick from it. The appreciation field is simply left empty.
//
// No file access here: like the appreciation step, the agent works only
// from the grid result + justifications (which already quote the copy), so
// this call uses ClaudeRunner.buildCommand.

.pragma library

// Per-CATEGORY target (Gabriel, 2026-10-15). A ceiling of 1 was tried and
// dropped the same day: it hid how serious a fault is (a copy ruined by
// spelling got the same single spelling bullet as a nearly-clean one). Now 0 =
// free: the number of bullets follows the gravity of the faults, as the
// comment's purpose is a list of correction tasks for a correction session
// (Gabriel). 1-3 stay available in the popover as a tendency (see parseBullets).
var DEFAULT_MAX_BULLETS = 0 // 0 = no target: as many bullets as the faults deserve

// Tone/generality models shown to the agent (Gabriel, 2026-10-15) — a short,
// hand-picked set of the teacher's own phrases (two he singled out as the
// right register, plus generic bank entries), NOT the whole comments bank:
// shown the full bank, the agent copied entries whose meaning didn't match
// the copy (e.g. "ne passez pas à la ligne au milieu d'un paragraphe" for a
// copy that had forgotten the line breaks). Rewire the bank once it's richer.
var DEFAULT_STYLE_EXAMPLES = [
  "Veillez à bien souligner les titres.",
  "Des efforts sur les analyses, mais leur précision reste irrégulière.",
  "Attention à la ponctuation.",
  "Attention aux homonymes (se/ce, cette/cet, à/a etc.).",
  "Précisez davantage vos analyses.",
  "Attention au contresens : relisez le texte pour vérifier ce qu'il affirme réellement."
]

var COLUMNS = ["Non maîtrisé", "Insuffisamment maîtrisé", "En cours de maîtrise", "Maîtrisé"]

// params: { gridName, rows, checks, justifications, maxBullets (per category), categories [labels],
// conclusionLine, addendum, styleExamples [texts: tone models only, never picked] }
function buildBulletsPrompt(params) {
  var p = params || {}
  var maxBullets = Math.max(0, Math.min(10, parseInt(p.maxBullets, 10) || DEFAULT_MAX_BULLETS))
  var categories = Array.isArray(p.categories) ? p.categories : []
  var rows = p.rows || []
  var checks = p.checks || {}
  var justifications = p.justifications || {}
  var lines = []

  lines.push("Tu es un assistant de correction pédagogique. Une grille de compétences a déjà été remplie pour une copie d'élève. Ta tâche : en tirer une liste de COMMENTAIRES factuels, sous forme de puces, indiquant à l'élève ce qu'il doit corriger pour progresser.")
  lines.push("")
  lines.push("## Grille remplie — « " + String(p.gridName || "") + " »")
  var currentSection = ""
  rows.forEach(function(row, idx) {
    if (!row.checkable) { currentSection = row.text; return }
    var level = checks[idx]
    var levelLabel = (level !== undefined && COLUMNS[level]) ? COLUMNS[level] : "(non rempli)"
    lines.push("- Critère : " + row.text)
    lines.push("  Palier : " + levelLabel)
    if (justifications[idx]) lines.push("  Justification : " + justifications[idx])
  })
  lines.push("")
  if (p.conclusionLine) {
    lines.push("## Conclusion (facultative dans cet exercice)")
    lines.push("L'élève a rédigé une conclusion. Observation de la correction : " + String(p.conclusionLine))
    lines.push("Tu peux en tirer UNE puce (point à corriger dans la conclusion, ou rien si elle est satisfaisante). Son absence ne donne jamais lieu à une puce.")
    lines.push("")
  }
  var examples = (Array.isArray(p.styleExamples) ? p.styleExamples : DEFAULT_STYLE_EXAMPLES).filter(function(t) { return String(t || "").trim() }).slice(0, 30)
  if (examples.length > 0) {
    lines.push("## Exemples de ton et de forme — commentaires habituels de l'enseignant")
    examples.forEach(function(t) { lines.push("- " + String(t).trim()) })
    lines.push("Ce sont des MODÈLES de forme et de généralité, pas une liste où piocher : ne recopie jamais l'un d'eux tel quel, rédige tes propres puces adaptées à cette copie (en corrigeant au passage les éventuelles fautes de frappe de ces exemples).")
    lines.push("")
  }
  lines.push("## Règles")
  lines.push("- Ces commentaires servent à préparer une séance de correction : chaque puce est une CONSIGNE DE CORRECTION claire, qui envoie l'élève chercher sur sa propre fiche ce qui ne va pas et lui dit quoi faire. Il n'y a pas de nombre maximal de puces : écris-en autant que les défauts de la copie en demandent, et aucune pour ce qui est réussi.")
  lines.push("- Proportionne les puces à la GRAVITÉ, d'après le palier de chaque critère et ses justifications : un critère « Non maîtrisé » ou « Insuffisamment maîtrisé » mérite autant de puces qu'il a de types de défauts distincts (une consigne par type, jamais de liste de défauts reliés par des virgules) ; un critère « En cours de maîtrise » une puce au plus, sur le défaut qui reste ; un critère « Maîtrisé » aucune. Une copie gravement fautive sur un critère doit le montrer par le nombre et la fermeté de ses puces. Dans une catégorie, place d'abord le défaut le plus grave.")
  if (maxBullets > 0) lines.push("- L'enseignant souhaite en général " + maxBullets + " puce(s) au plus par catégorie : c'est une TENDANCE, pas une règle stricte. Regroupe les remarques voisines en une consigne générale, mais ne laisse jamais de côté un point important pour respecter ce chiffre ; si deux remarques ne se rejoignent vraiment pas, fusionne-les ou ajoute une puce.")
  lines.push("- Catégories autorisées (utilise EXACTEMENT ces intitulés, dans cet ordre) : " + categories.join(" ; "))
  lines.push("- VOUVOIEMENT OBLIGATOIRE : adresse-toi à l'élève en le vouvoyant (« vous », « votre », « vos », impératif en -ez : « Veillez à… », « N'oubliez pas… », « Attention à… »). Jamais de tutoiement, jamais de troisième personne (« ses propres mots »).")
  lines.push("- Chaque puce est GÉNÉRALE, comme les exemples de l'enseignant : elle nomme un TYPE de faiblesse ou une consigne de méthode que l'élève peut appliquer sans qu'on lui désigne un passage. N'indique JAMAIS un endroit précis de la copie (page, ligne, sous-partie I-a ou II-b, axe, « dans l'introduction », retour à la ligne à tel endroit…), ne cite aucun mot ni extrait de la copie, et ne mentionne aucun détail propre au texte étudié (personnages, événements). Même une erreur de contenu se formule en général (ex. « Attention au contresens : relisez le texte pour distinguer ce qu'il affirme de ce qu'il envisage »).")
  lines.push("- Les cases cochées disent déjà le niveau de chaque critère : ne répète pas en d'autres mots ce qu'elles disent. N'écris une puce que pour indiquer ce qu'il faut TRAVAILLER, et pas systématiquement pour chaque critère non maîtrisé. Aucune puce pour un critère au palier « Maîtrisé ».")
  lines.push("- Chaque puce est brève (une vingtaine de mots au plus) et ne porte que sur UNE idée. Elle peut être une consigne, un constat bref, ou la nuance d'un effort réel et de sa limite (ex. « Des efforts sur les analyses, mais leur précision reste irrégulière »). Aucun compliment ni encouragement (« bravo », « beau travail »…), aucun jugement subjectif.")
  lines.push("- Pour les fautes de langue, nomme chaque type de faute par son nom (accentuation, y compris sur les noms propres ; accords ; homonymes ; ponctuation ; construction de la phrase) plutôt que par une formule vague. Si la grille mentionne des accents manquants ou erronés, une puce doit les nommer.")
  lines.push("- Pas de doublons : deux puces ne doivent jamais corriger le même défaut, même dans deux catégories différentes. Chaque défaut est rattaché à la SEULE catégorie qui le possède d'après les points de vigilance de la grille ci-dessus (si la grille dit qu'un défaut « relève » d'un autre critère, range-le là).")
  lines.push("- Appuie-toi uniquement sur la grille ci-dessus et ses justifications ; n'invente aucun fait sur la copie.")
  if (p.addendum) {
    lines.push("")
    lines.push("## Consigne supplémentaire de l'enseignant pour cette copie")
    lines.push(String(p.addendum))
  }
  lines.push("")
  lines.push("## Format de réponse strict — rien d'autre avant ou après")
  lines.push("")
  lines.push("## Commentaires")
  lines.push("PUCE: <catégorie> | <texte du commentaire>")
  lines.push("(une ligne par puce, regroupées par catégorie dans l'ordre de la liste ; si aucune puce : écris exactement RAS)")
  lines.push("")
  lines.push("## Consignes techniques")
  lines.push("- N'utilise aucun outil, ne lis ni n'écris aucun fichier. Ne pose aucune question : personne ne peut te répondre dans l'immédiat.")
  return lines.join("\n")
}

// Parses buildBulletsPrompt's output → { bullets: [{ id, text, tag, bankId,
// isNew }], personal } (personal is always "" while that block is disconnected). Tolerant like the rest of this codebase's parsers: a
// malformed line is dropped rather than failing the parse; duplicates
// collapse; the per-category target is only a tendency for the agent (Gabriel, 2026-10-15), so
// the parser tolerates one bullet beyond it and drops anything further.
// Every bullet is flagged isNew (nothing comes from the bank any more), so
// Gabriel can still save a good one to the bank with "＋ Banque".
function parseBullets(text, maxBullets, categories) {
  var t = String(text || "")
  var cap = Math.max(0, Math.min(10, parseInt(maxBullets, 10) || DEFAULT_MAX_BULLETS))
  var cats = Array.isArray(categories) ? categories : []
  var perCat = {}

  var secMatch = t.match(/##\s*Commentaires\s*\n([\s\S]*?)(?=\n##\s*Commentaire personnel|$)/i)
  var persMatch = t.match(/##\s*Commentaire personnel\s*\n([\s\S]*)$/i)

  var bullets = []
  var seen = {}
  var section = secMatch ? secMatch[1] : ""
  section.split("\n").forEach(function(line) {
    var l = line.trim().replace(/^[-*•]\s*/, "")
    var m = l.match(/^PUCE\s*:\s*([^|]+)\|\s*(.+\S)\s*$/i)
    if (!m) return
    var entry = { id: "", text: m[2].trim(), tag: m[1].trim(), bankId: "", isNew: true }
    for (var ci = 0; ci < cats.length; ci++) if (cats[ci].toLowerCase() === entry.tag.toLowerCase()) entry.tag = cats[ci]
    var key = entry.text.toLowerCase()
    if (seen[key]) return
    if (cap > 0 && (perCat[entry.tag] || 0) >= cap + 1) return
    perCat[entry.tag] = (perCat[entry.tag] || 0) + 1
    seen[key] = true
    entry.id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
    bullets.push(entry)
  })

  var personal = persMatch ? persMatch[1].trim() : ""
  if (personal.toUpperCase() === "RAS") personal = ""
  return { bullets: bullets, personal: personal }
}

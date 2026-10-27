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

// "Exercice de correction" (Gabriel, 2026-10-19): the bullet comments become a
// short list of correction TASKS the student carries out on their own copy
// (printed with a checkbox each). At most 5 in total — not per category —
// ordered from the least successful criteria to the more successful ones.
// This replaces the 2026-10-15 "free count by gravity" design (21 bullets on a
// weak copy was a list of remarks, far too long to be an exercise).
var DEFAULT_MAX_BULLETS = 5 // total ceiling, whatever the number of categories

// Tone/form models shown to the agent: a correction TASK is an action the
// student can carry out and tick off — not a warning ("Attention à…") and not a
// verdict. Models of form only, never a list to pick from.
var DEFAULT_STYLE_EXAMPLES = [
  "Relisez votre copie en soulignant les titres d'œuvres, puis soulignez ceux qui ne le sont pas.",
  "Relisez chaque analyse : précisez le procédé et expliquez son effet au lieu de seulement le nommer.",
  "Relisez votre copie pour repérer et corriger les homonymes (se/ce, cette/cet, à/a…).",
  "Reprenez la ponctuation de votre copie : vérifiez les virgules et les deux-points avant les citations.",
  "Réécrivez la fin de chaque paragraphe pour qu'elle interprète vos analyses, au lieu de les répéter.",
  "Vérifiez le sens du texte à la relecture : repérez ce qu'il affirme réellement et corrigez le contresens."
]

var COLUMNS = ["Non maîtrisé", "Insuffisamment maîtrisé", "En cours de maîtrise", "Maîtrisé"]

// params: { gridName, rows, checks, justifications, maxBullets (total ceiling, default 5), categories [labels],
// conclusionLine, addendum, styleExamples [texts: tone models only, never picked] }
function buildBulletsPrompt(params) {
  var p = params || {}
  var maxBullets = Math.max(0, Math.min(10, parseInt(p.maxBullets, 10) || DEFAULT_MAX_BULLETS))
  var categories = Array.isArray(p.categories) ? p.categories : []
  var rows = p.rows || []
  var checks = p.checks || {}
  var justifications = p.justifications || {}
  var lines = []

  lines.push("Tu es un assistant de correction pédagogique. Une grille de compétences a déjà été remplie pour une copie d'élève. Ta tâche : en tirer un EXERCICE DE CORRECTION, c'est-à-dire une courte liste de TÂCHES que l'élève devra accomplir lui-même sur sa copie pour progresser, et qu'il cochera une fois faites.")
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
    lines.push("Tu peux en tirer UNE tâche (point à corriger dans la conclusion, ou rien si elle est satisfaisante). Son absence ne donne jamais lieu à une tâche.")
    lines.push("")
  }
  var examples = (Array.isArray(p.styleExamples) ? p.styleExamples : DEFAULT_STYLE_EXAMPLES).filter(function(t) { return String(t || "").trim() }).slice(0, 30)
  if (examples.length > 0) {
    lines.push("## Exemples de forme — tâches de correction")
    examples.forEach(function(t) { lines.push("- " + String(t).trim()) })
    lines.push("Ce sont des MODÈLES de forme et de généralité, pas une liste où piocher : ne recopie jamais l'un d'eux tel quel, rédige tes propres tâches adaptées à cette copie.")
    lines.push("")
  }
  lines.push("## Règles")
  lines.push("- Écris AU PLUS " + maxBullets + " tâches EN TOUT (pas par catégorie) : moins si la copie n'en demande pas autant, jamais davantage. Chaque tâche est une action CONCRÈTE et VÉRIFIABLE que l'élève peut accomplir seul en reprenant sa copie, et dont il peut dire ensuite « c'est fait » : elle commence par un verbe à l'impératif (« Relisez… », « Reprenez… », « Réécrivez… », « Vérifiez… », « Soulignez… »). Jamais un simple avertissement (« Attention à… »), jamais un constat ou un jugement.")
  lines.push("- PRIORITÉ : ordonne les tâches des critères les MOINS réussis aux plus réussis, d'après le palier de chaque critère : d'abord ceux au palier « Non maîtrisé », puis « Insuffisamment maîtrisé », puis « En cours de maîtrise ». Un critère « Maîtrisé » ne donne JAMAIS de tâche. À palier égal, les critères d'EXPRESSION ÉCRITE (orthographe, accents, accords, syntaxe, ponctuation, style, niveau de langue, correction de la langue) passent TOUJOURS avant les autres, car les fautes de langue sont la priorité de l'enseignant ; pour le reste, suis l'ordre de la grille. S'il y a plus de défauts que de tâches possibles, abandonne les moins graves et regroupe en une seule tâche générale les défauts de même nature d'un même critère ; les critères les moins réussis passent toujours avant les autres.")
  lines.push("- Catégories autorisées (utilise EXACTEMENT l'un de ces intitulés comme étiquette de chaque tâche ; l'ordre des tâches suit la PRIORITÉ ci-dessus, pas celui de cette liste) : " + categories.join(" ; "))
  lines.push("- VOUVOIEMENT OBLIGATOIRE : adresse-toi à l'élève en le vouvoyant (« vous », « votre », « vos », impératif en -ez : « Veillez à… », « N'oubliez pas… », « Attention à… »). Jamais de tutoiement, jamais de troisième personne (« ses propres mots »).")
  lines.push("- Chaque tâche est GÉNÉRALE, comme les exemples : elle nomme un TYPE de faiblesse à traquer et à corriger dans toute la copie, sans qu'on lui désigne un passage — retrouver les endroits à corriger fait partie de l'exercice. N'indique JAMAIS un endroit précis de la copie (page, ligne, sous-partie I-a ou II-b, axe, « dans l'introduction », retour à la ligne à tel endroit…), ne cite aucun mot ni extrait de la copie, et ne mentionne aucun détail propre au texte étudié (personnages, événements). Même une erreur de contenu se formule en général (ex. « Relisez le texte pour distinguer ce qu'il affirme de ce qu'il envisage, et corrigez le contresens »).")
  lines.push("- Les cases cochées disent déjà le niveau de chaque critère : ne répète pas en d'autres mots ce qu'elles disent. N'écris une tâche que pour ce qu'il faut TRAVAILLER.")
  lines.push("- Chaque tâche est brève (une trentaine de mots au plus) et ne porte que sur UNE action. Aucun compliment ni encouragement (« bravo », « beau travail »…), aucun jugement subjectif.")
  lines.push("- Pour les fautes de langue, nomme chaque type de faute par son nom (accentuation, y compris sur les noms propres ; accords ; homonymes ; ponctuation ; construction de la phrase) plutôt que par une formule vague. Si la grille mentionne des accents manquants ou erronés, une tâche doit les nommer.")
  lines.push("- Pas de doublons : deux tâches ne doivent jamais corriger le même défaut, même dans deux catégories différentes. Chaque défaut est rattaché à la SEULE catégorie qui le possède d'après les points de vigilance de la grille ci-dessus (si la grille dit qu'un défaut « relève » d'un autre critère, range-le là).")
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
  lines.push("PUCE: <catégorie> | <texte de la tâche>")
  lines.push("(une ligne par tâche, dans l'ordre de priorité ; si aucune tâche : écris exactement RAS)")
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
    if (cap > 0 && bullets.length >= cap) return
    seen[key] = true
    entry.id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
    bullets.push(entry)
  })

  var personal = persMatch ? persMatch[1].trim() : ""
  if (personal.toUpperCase() === "RAS") personal = ""
  return { bullets: bullets, personal: personal }
}

// "Appréciation" of a Commentaire guidé copy (Gabriel, 2026-10-19): a short
// prose SUMMARY of the per-critère comments (the grid's justifications),
// shown above the bullet "Commentaires" and regenerated on demand once the
// teacher has settled the ⚠ doubts. Pure condensation of text that already
// quotes the copy — the agent never sees the copy itself, which is exactly
// why this works where the old "critère : palier" appreciation generator
// (which had nothing concrete to rely on and invented) did not.
// params: { gridName, rows, checks, justifications }
function buildSummaryPrompt(params) {
  var p = params || {}
  var rows = p.rows || []
  var checks = p.checks || {}
  var justifications = p.justifications || {}
  var lines = []
  lines.push("Tu es un assistant de correction pédagogique. Les commentaires par critère ci-dessous ont été rédigés par un correcteur qui a lu la copie d'un élève. Ta tâche : en faire un RÉSUMÉ en un seul paragraphe, qui servira d'appréciation générale.")
  lines.push("")
  lines.push("## Commentaires par critère — « " + String(p.gridName || "") + " »")
  rows.forEach(function(row, idx) {
    if (!row.checkable) return
    var level = checks[idx]
    var levelLabel = (level !== undefined && COLUMNS[level]) ? COLUMNS[level] : "(non rempli)"
    lines.push("- Critère : " + row.text)
    lines.push("  Palier : " + levelLabel)
    if (justifications[idx]) lines.push("  Commentaire : " + justifications[idx])
  })
  lines.push("")
  lines.push("## Règles")
  lines.push("- Résume UNIQUEMENT ce que disent ces commentaires : n'ajoute aucun fait, aucun jugement, aucune explication qui n'y figure pas, et ne suppose rien sur le reste de la copie.")
  lines.push("- Si un commentaire contredit le palier coché, le PALIER fait foi : l'enseignant a pu le corriger à la main après coup. Ne retiens alors du commentaire que ce qui reste compatible avec le palier.")
  lines.push("- Reste fidèle au poids de chaque critère : ce qui est maîtrisé se résume en quelques mots (ou se passe sous silence s'il n'y a rien d'utile à en dire), ce qui est faible occupe la plus grande place. Ne présente jamais comme réussi un critère « Non maîtrisé » ou « Insuffisamment maîtrisé », et n'adoucis pas les défauts.")
  lines.push("- Suis l'ordre de la grille : compréhension, analyse et interprétation, construction (mise en page, plan, introduction, développement), puis expression écrite.")
  lines.push("- Un seul paragraphe, de prose continue (pas de puces, pas de titres), d'environ 120 à 180 mots. Style sobre et factuel, à l'impersonnel ou à la troisième personne (« Le sens général est saisi… », « L'introduction… »). Ni tutoiement ni vouvoiement, aucune formule d'encouragement ou de compliment, aucune note chiffrée.")
  lines.push("- Reformule : ne recopie pas les citations de la copie entre guillemets, sauf une notion ou un mot essentiel au propos.")
  lines.push("")
  lines.push("## Consignes techniques")
  lines.push("- N'utilise aucun outil, ne lis ni n'écris aucun fichier. Ne pose aucune question : personne ne peut te répondre dans l'immédiat.")
  lines.push("- Réponds uniquement par le paragraphe, sans titre ni préambule.")
  return lines.join("\n")
}

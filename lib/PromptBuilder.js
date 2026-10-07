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

// rows: grid.rows (only .checkable ones matter); checks: { [rowIndex]: colIndex };
// columns: the 4 level labels in colIndex order (0..3). note is
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

// "Eval. Compétences" tab's OWN appreciation generator (Gabriel, 2026-10-02,
// simplified 2026-10-03) — completely independent from
// buildEvalAppreciationPrompt above, which stays wired to the Corrections
// tab only ("vraiment à part, débranché", Gabriel's own words). Deliberately
// minimal (Gabriel, 2026-10-02, second correction): ONLY the criterion's
// name + the plain checked level (Maîtrisé/En cours de maîtrise/...), never
// the grid's own written palier DEFINITION of what that level means for
// that criterion, and never its vigilance note either. That richer text is
// correctly read by the Corrections agent, which has the copy in hand and
// is comparing it against those definitions — reusing it here, where the
// agent never reads the copy, gave it a definition of e.g. "cohérente avec
// le plan" to apply, which it then applied by GUESSING whether the copy
// matched it — exactly the surinterprétation this function exists to avoid.
// The only real sources of substance here are the plain checked level and
// Gabriel's own two-column annotations.
//
// binome (Gabriel, 2026-10-06): true when the copy was written by two
// students together — the appréciation then addresses both of them.
//
// 2026-10-03 simplification (same "circuit B" principle applied to the
// Corrections tab's single-shot pipeline, see CorrectionPromptBuilder.js):
// the forced méthode/contenu/expression three-part structure is dropped —
// Gabriel found it produced heavy redundancy in a text this short, since
// the agent, having nothing but a handful of checked levels and two short
// annotations to work with, kept re-stating the same scant material under
// three separate headings. The length choice is dropped too, replaced by a
// length-by-content-not-by-setting instruction (Gabriel, 2026-10-03, second
// pass: an unconditional "deux à trois phrases maximum" risked cutting off
// a genuinely well-fed annotation): the agent still can't invent to fill
// space when the two annotation fields are thin, but isn't capped either
// when they actually hold enough to justify more — the amount of real
// material, not a target length, is what should drive this.
//
// 2026-10-03, third pass (Gabriel reviewed a real generated appreciation
// against his own on the same copy): the result was readable but padded
// with generic pedagogical coaching phrasing ("témoigne d'un vrai souci de
// rigueur formelle", "elle doit maintenant se remplir de matière") instead
// of concrete information, AND mechanically paired two unrelated critères
// into one sentence ("tout comme") purely because they happened to share
// the same checked palier — an artefact of narrating the grid row by row
// rather than starting from what the teacher actually wants said. Fix:
// annotationsPositif/Negatif (the only genuinely concrete material here,
// since Gabriel read the copy to write them) now come FIRST and are framed
// as the real content to build the appreciation from; the grid is reframed
// as a compact backdrop — used only to briefly cover a critère the
// annotations never touch, never developed into its own sentence. Plus two
// new explicit bans: no generic/abstract coaching language, and no
// sentence linking two critères on the sole basis of a shared palier.
//
// 2026-10-03, fourth pass (the third pass's fixes didn't survive contact
// with a second real test): the agent still produced (a) a closing
// catch-all sentence dumping every un-annotated critère's level verbatim
// ("vous êtes en cours de maîtrise... le niveau de langue est bien adapté")
// — pure redundancy, since the grid TABLE itself already sits right above
// this text in the copied markdown/PDF, the student doesn't need it said
// twice — and (b) new instances of the same coaching-filler pattern under
// different wording ("c'est un point d'appui réel") that the first ban's
// example list didn't happen to cover. Two corresponding fixes: un-
// annotated critères are now explicitly EXCLUDED from the written text
// entirely (not "mentioned briefly" — removed as a category of content),
// and the coaching-filler ban is now framed as a general pattern (any
// clause whose only job is to comment on the pedagogical value of a fact
// just stated, rather than add a new one) instead of a fixed phrase list,
// since Gabriel keeps finding fresh wordings of the same move.
function buildEvalCompetencesAppreciationPrompt(gridName, rows, columns, checks, annotationsPositif, annotationsNegatif, binome) {
  var cleanPositif = String(annotationsPositif || "").trim()
  var cleanNegatif = String(annotationsNegatif || "").trim()
  var hasAnnotations = !!(cleanPositif || cleanNegatif)
  var lines = []
  lines.push("Tu es un professeur de lettres qui rédige une appréciation de copie d'élève.")
  lines.push("")
  lines.push("Consignes strictes :")
  lines.push("- Réaliste et honnête sur le niveau réel, mais jamais décourageante : même un point faible se formule de façon constructive.")
  lines.push("- Vouvoiement obligatoire (\"vous\"), jamais de tutoiement.")
  if (binome) lines.push("- Cette copie a été rédigée en binôme par deux élèves : adresse-toi aux deux ensemble (\"vous\" pluriel, accords au pluriel, ex. \"vous avez su\", \"votre travail commun\"), jamais à un seul élève. Privilégie les tournures qui évitent d'accorder en genre.")
  lines.push("- Un texte resserré, dense, sans remplissage : il faut que l'élève le lise. Pas de liste à puces, pas de titres de section visibles, pas de structure ou de plan imposé — dis ce qu'il y a à dire, dans l'ordre le plus naturel. La longueur doit suivre la quantité réelle de matière ci-dessous, pas un format fixe : s'il y a peu à dire, deux ou trois phrases suffisent et il ne faut rien inventer pour meubler ; si les annotations de l'enseignant sont riches et détaillées, tu peux développer davantage pour leur faire justice, sans jamais devenir bavard ou redondant.")
  lines.push("- Interdiction du COMMENTAIRE MÉTA : n'ajoute jamais une clause ou une phrase dont le seul rôle est de souligner la valeur pédagogique d'un fait que tu viens d'énoncer, sans apporter d'information nouvelle (encouragement, bilan, validation) — par exemple \"c'est un point d'appui réel\", \"c'est encourageant\", \"c'est un bon début\", \"cela montre que vous progressez\", \"témoigne d'un vrai souci de rigueur\", \"une base solide pour progresser\". Un fait énoncé se suffit à lui-même, il n'a pas besoin qu'on en souligne l'importance après coup. Pareil pour les métaphores abstraites sur la progression (\"il faut remplir l'architecture de matière\") : si tu n'as rien de concret à ajouter sur un point, dis-le en une formule brève plutôt que de l'habiller.")
  lines.push("- Ne relie jamais deux critères dans une même phrase au seul motif qu'ils partagent le même niveau coché (ex. \"tout comme\", \"de même que\") : chaque critère se traite pour ce qu'il est, sauf si le contenu réel (une annotation) les relie naturellement.")
  lines.push("- Tu n'as PAS lu la copie et tu ne sais RIEN d'autre sur elle que ce qui suit : pour chaque critère, un simple niveau coché (Maîtrisé, En cours de maîtrise, Insuffisamment maîtrisé ou Non maîtrisé), sans aucune autre précision — et les annotations de l'enseignant ci-dessous le cas échéant. N'invente RIEN au-delà de ça : ni exemple, ni détail, ni circonstance, ni raison pour laquelle tel niveau aurait été retenu.")
  if (hasAnnotations) {
    lines.push("- Les annotations de l'enseignant sont la SEULE matière de cette appréciation : construis-la exclusivement à partir d'elles. La grille de critères qui suit n'est qu'un garde-fou pour TOI (ne jamais contredire un niveau coché) — elle ne doit PAS apparaître dans le texte que tu écris : un critère qu'aucune annotation ne couvre ne doit être ni mentionné, ni résumé, ni listé dans l'appréciation, même brièvement. Le tableau de la grille est de toute façon déjà visible par l'élève juste au-dessus de ton texte : le répéter en phrases serait une pure redondance.")
  } else {
    lines.push("- Aucune annotation n'a été fournie : base-toi dans ce cas uniquement sur la grille ci-dessous, un critère coché = une formule générale très brève correspondant à ce seul niveau, sans justification inventée.")
  }
  lines.push("")
  if (cleanPositif) {
    lines.push("Points positifs relevés par l'enseignant en lisant la copie — utilise-les pour valoriser concrètement, toujours sans citer la copie : " + cleanPositif)
    lines.push("")
  }
  if (cleanNegatif) {
    lines.push("Points à améliorer relevés par l'enseignant en lisant la copie — utilise-les pour cibler précisément les conseils, toujours sans citer la copie : " + cleanNegatif)
    lines.push("")
  }
  lines.push("Grille \"" + gridName + "\", niveau coché par critère" + (hasAnnotations ? " — garde-fou pour TOI uniquement, à ne JAMAIS faire apparaître dans le texte de l'appréciation (voir consigne ci-dessus)" : "") + " :")
  var anyChecked = false
  rows.forEach(function(row, idx) {
    if (!row.checkable) return
    var level = checks[idx]
    if (level === undefined || level === null) return
    anyChecked = true
    lines.push("- " + row.text + " : " + (columns[level] || ""))
  })
  if (!anyChecked) lines.push("(aucun critère coché)")
  lines.push("")
  lines.push("Réponds UNIQUEMENT avec le texte de l'appréciation, sans guillemets, sans titre, sans commentaire additionnel, sans markdown.")
  return lines.join("\n")
}

// Gabriel, 2026-10-02: a pure proofreading pass over text Gabriel already
// wrote himself (appreciation generated above, or hand-typed) — fully
// grounded by construction, the only input IS the text to review, nothing
// to invent since there's nothing beyond it to describe. Kept as its own
// separate button alongside the generator above.
function buildAppreciationCheckPrompt(text) {
  var lines = []
  lines.push("Tu es un correcteur professionnel. Voici un texte rédigé par un professeur de lettres (une appréciation destinée à un élève) :")
  lines.push("")
  lines.push(String(text || "").trim())
  lines.push("")
  lines.push("Relis UNIQUEMENT ce texte et signale les fautes d'orthographe et de syntaxe qu'il contient lui-même (accords, conjugaison, ponctuation, construction de phrase...) — pas le contenu du texte ni le jugement porté sur l'élève, seulement la correction de la langue de CE texte.")
  lines.push("Réponds par une liste, un point par ligne, chaque ligne commençant par \"- \", au format : <extrait fautif exact> → <explication brève et proposition de correction>.")
  lines.push("Si tu ne trouves strictement aucune faute, réponds exactement : RAS.")
  lines.push("Ne réponds rien d'autre : pas de titre, pas de commentaire, pas de markdown en dehors des tirets.")
  return lines.join("\n")
}

// "✅ Appliquer les corrections" (Gabriel, 2026-10-02) — a SEPARATE call from
// buildAppreciationCheckPrompt above, deliberately constrained to the
// specific faults that check already surfaced (passed in as `report`
// verbatim), rather than asking for a fresh, unconstrained rewrite: keeps
// the apply step strictly tied to what Gabriel already reviewed on screen.
function buildAppreciationApplyFixesPrompt(text, report) {
  var lines = []
  lines.push("Voici un texte, et une liste de fautes d'orthographe et de syntaxe déjà relevées dans ce texte par un correcteur.")
  lines.push("")
  lines.push("## Texte original")
  lines.push(String(text || "").trim())
  lines.push("")
  lines.push("## Fautes déjà relevées, à corriger")
  lines.push(String(report || "").trim())
  lines.push("")
  lines.push("Réécris le texte en corrigeant UNIQUEMENT les fautes listées ci-dessus, sans rien changer d'autre : ni le sens, ni le ton, ni la structure, ni aucun mot qui n'est concerné par aucune des fautes listées.")
  lines.push("Réponds UNIQUEMENT avec le texte corrigé, sans guillemets, sans titre, sans commentaire additionnel, sans markdown.")
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

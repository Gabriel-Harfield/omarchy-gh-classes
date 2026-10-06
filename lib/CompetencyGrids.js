// Grille templates for the "Eval. Compétences" tab: hardcoded, versioned in
// code rather than user-editable in the app — Gabriel pastes a new grid's
// content into a conversation with Claude and it gets added here as a new
// entry in GRIDS, same spirit as PromptBuilder.js's hardcoded prompts.
//
// Each grid's `rows` is parsed from a small markdown-like outline: "# " and
// "## " lines (deeper levels also supported). A row is a checkbox row
// ("checkable") unless the very next line is one level deeper — i.e. a
// heading that has sub-items becomes a plain section header spanning the
// full table width, and only its children get checkboxes. This mirrors
// Gabriel's own convention ("les titres # possédant un sous-titre ## ne
// posséderont pas de cases à cocher").
//
// Per-student answers are stored as
// { [grid.id]: { checks: { [rowIndex]: colIndex }, appreciation, note } } on
// the Student object (see Store.js) — rowIndex is the row's position in this
// parsed array, so reordering/inserting rows in an existing grid here would
// silently reshuffle already-recorded answers. Only ever append rows to an
// existing grid, or ship a new grid id for a reworked version.

.pragma library

var COLUMNS = ["Non maîtrisé", "Insuffisamment maîtrisé", "En cours de maîtrise", "Maîtrisé"]

// Extended (Gabriel, 2026-09-27) to also capture, for each heading, an
// optional set of 4 palier descriptions ("- Non maîtrisé : ...", one per
// COLUMNS entry, case-insensitive) and an optional "*Point de vigilance* :
// ..." free-text note — both written directly under the heading they
// qualify, before the next heading. These come from a document Gabriel
// writes per grid (the AI correction agent's per-criterion rubric — see
// [[gh-corrections-plugin]]) rather than being hand-typed here; a grid
// built the old way (headings only, no bullets) still parses fine, with
// paliers left null and vigilance left "".
function parseGridMarkdown(text) {
  var lines = String(text || "").split("\n")
  var raw = []
  var palierNames = ["non maîtrisé", "insuffisamment maîtrisé", "en cours de maîtrise", "maîtrisé"]
  for (var i = 0; i < lines.length; i++) {
    var headingMatch = lines[i].match(/^(#{1,6})\s+(.*\S)\s*$/)
    if (headingMatch) {
      raw.push({ level: headingMatch[1].length, text: headingMatch[2], paliers: null, vigilance: "" })
      continue
    }
    if (raw.length === 0) continue
    var current = raw[raw.length - 1]
    var palierMatch = lines[i].match(/^-\s*(Non maîtrisé|Insuffisamment maîtrisé|En cours de maîtrise|Maîtrisé)\s*:\s*(.*\S)\s*$/i)
    if (palierMatch) {
      if (!current.paliers) current.paliers = ["", "", "", ""]
      var colIdx = palierNames.indexOf(palierMatch[1].toLowerCase())
      if (colIdx !== -1) current.paliers[colIdx] = palierMatch[2].trim()
      continue
    }
    // Accepts both "*Point de vigilance* : texte" (COMMENTAIRE_FORMATIF_MD's
    // own convention, label bolded) and "_Point de vigilance : texte_"
    // (Gabriel's own convention in introduction.md, whole line italicized) —
    // rather than force one convention on him, 2026-10-01. The trailing
    // marker (if any) ends up captured as part of the text since it's \S
    // too; stripped explicitly afterward.
    var vigilanceMatch = lines[i].match(/^[_*]?Point de vigilance[_*]?\s*:\s*(.*\S)\s*$/i)
    if (vigilanceMatch) {
      var vText = vigilanceMatch[1].trim().replace(/[_*]$/, "").trim()
      current.vigilance = (current.vigilance ? current.vigilance + " " : "") + vText
    }
  }
  var rows = []
  for (var j = 0; j < raw.length; j++) {
    var hasChild = (j + 1 < raw.length) && (raw[j + 1].level > raw[j].level)
    rows.push({
      level: raw[j].level, text: raw[j].text, checkable: !hasChild,
      paliers: raw[j].paliers, vigilance: raw[j].vigilance
    })
  }
  return rows
}

// Formats a grid's checkable rows + their 4 palier descriptions + any
// vigilance note into the text block the correction agent reads to fill
// the grid (see CompetencyPromptBuilder.buildFillGridPrompt) — centralized
// here so that builder never has to know this parsing/formatting detail,
// and a grid with no paliers written yet (old-style, headings only) simply
// produces an empty string rather than a broken prompt section.
function buildGridRubricText(grid) {
  if (!grid) return ""
  var hasAnyPaliers = grid.rows.some(function(row) { return row.checkable && row.paliers })
  if (!hasAnyPaliers) return ""
  var lines = []
  grid.rows.forEach(function(row) {
    if (!row.checkable) {
      lines.push("# " + row.text)
      lines.push("")
      return
    }
    if (!row.paliers) return
    lines.push("## " + row.text)
    lines.push("")
    for (var i = 0; i < COLUMNS.length; i++) {
      lines.push("- " + COLUMNS[i] + " : " + (row.paliers[i] || "(non précisé)"))
    }
    if (row.vigilance) {
      lines.push("")
      lines.push("*Point de vigilance* : " + row.vigilance)
    }
    lines.push("")
  })
  return lines.join("\n").trim()
}

// The official (État/Éducation nationale) EAF competency list — kept as-is
// for the real bac correction at year's end. Gabriel finds it too vague for
// formative evaluations day to day (see COMMENTAIRE_FORMATIF_MD below,
// his own reworked version for that use).
var COMMENTAIRE_EAF_MD = [
  "# Aptitude à comprendre, à analyser et à interpréter un texte littéraire",
  "## Aptitude à comprendre un texte littéraire",
  "## Aptitude à analyser et à interpréter un texte littéraire",
  "# Aptitude à mobiliser une culture littéraire fondée sur les travaux conduits en cours de français, sur des connaissances et des lectures personnelles",
  "# Aptitude à construire une réflexion en prenant appui sur un texte et à la rendre intelligible",
  "# Maîtrise de la langue et de l'expression à l'écrit",
  "## Aptitude à respecter les normes orthographiques et syntaxiques",
  "## Aptitude à utiliser une langue correcte et adaptée"
].join("\n")

// Gabriel's own, more precise rewrite for day-to-day formative grading
// (2026-09-26) — a handful of obvious typos in his pasted text corrected
// in transcription (réflexionen→réflexion en, prennant→prenant,
// correctment→correctement, orthographiaques→orthographiques, son→sont,
// un annonce→une annonce), wording otherwise kept exactly as given since
// this prints verbatim on documents handed to students. The 4 palier
// descriptions per criterion (2026-09-27, written after real calibration
// testing on TP 1SCHA Sujet A — see [[gh-corrections-plugin]]) are what
// the AI correction agent reads to fill this grid on its own; kept here,
// verbatim including Gabriel's own minor typos in THAT text (pargraphe,
// illutrant, avencer, remplies...) since those don't affect the agent and
// this is the single source of truth he keeps editing directly.
var COMMENTAIRE_FORMATIF_MD = `# Aptitude à comprendre un texte littéraire.

- Non maîtrisé : Le sens du texte n'est pas du tout compris, l'élève commettant des contresens nombreux et graves.
- Insuffisamment maîtrisé : Le sens du texte n'est que partiellement compris, des contresens plus ou moins graves étant encore présents.
- En cours de maîtrise : Le texte est bien compris, mais l'élève n'en saisit pas encore les enjeux interprétatifs.
- Maîtrisé : Le texte est parfaitement bien compris, tant dans son sens premier que second.

# Aptitude à analyser et à interpréter un texte littéraire.

## La problématique et les axes proposés permettent d'engager une véritable réflexion sur le sens du texte.

- Non maîtrisé : Il n'y a aucune forme d'interrogation, exprimée dans l'introduction, conduisant l'analyse du texte.
- Insuffisamment maîtrisé : L'interrogation proposée en introduction n'est pas encore une problématique, mais un simple projet de lecture. En effet, on ne distingue aucune opposition dans la question (par exemple : "en quoi ce texte est-il comique?" = projet de lecture ; "en quoi ce texte, tout en nous faisant rire, développe-t-il une réflexion des plus sérieuses" = problématique, car on opposte le "rire" et le "sérieux").
- En cours de maîtrise : L'interrogation proposée en introduction est bien une problématique, mais celle-ci n'est pas encore tout à fait cohérente avec les axes proposés par la suite (pour rappel : les axes sont censés être une réponse possible ou partielle à la problématique).
- Maîtrisé : L'interrogation proposée en introduction est bien une problématique ; celle-ci est tout à fait cohérente aussi bien vis-à-vis du texte analysé que vis-à-vis du plan proposé.

*Point de vigilance* : une simple opposition d'idées (sentiment / raison ; rire / sérieux ; comique / tragique etc.) est considérée comme une problématique valide si celle-ci est cohérente avec le plan et le texte analysé.

## Les analyses proposées sont précises et s'appuient sur un vocabulaire littéraire précis.

- Non maîtrisé : Aucune citation ni aucun procédé d'analyse littéraire précis (figures de style, analyse du lexique, valeur des verbes, élément de contexte) n'est proposé. Les paragraphes de développement ne font qu'un résumé du texte analysé.
- Insuffisamment maîtrisé : Les citations sont justement relevés, mais aucune analyse précise, par le biais de procédés littéraires correctement identifiés (figures de style, analyse du lexique, valeur des verbes, élément de contexte), n'est proposé. Les paragraphes de développement restent ainsi essentiellement de la paraphrase.
- En cours de maîtrise : Les paragraphes de développement sont irréguliers, certains proposant des citations et analyses de celles-ci pertinentes, d'autres pas. Le développement avance ainsi dans la bonne direction, possède quelques bonnes analyses, mais à encore besoin de davantage de régularité.
- Maîtrisé : Les citations et analyses proposées dans les paragraphes de développement sont justes et précises ; elles illustrent parfaitement l'argument du paragraphe dans lequel elles se trouvent et permettent de faire avancer le raisonnement.

## Les interprétations proposées permettent de faire avancer la réflexion proposée par la problématique.

- Non maîtrisé : Aucune interprétation des citations et analyses proposées dans le pargraphe ; celui-ci est alors, au mieux, un simple relevé de procédés.
- Insuffisamment maîtrisé : L'élève tente des interprétations des éléments cités et analysés, mais celles-ci restent trop superficielles voire hors-sujet.
- En cours de maîtrise : L'élève propose des interprétations pertinentes pour les éléments cités et analysés, mais celles-ci peuvent être encore approfondies afin de mieux faire avancer la thèse de la copie, c'est-à-dire sa réponse à la question problématique posée en introduction.
- Maîtrisé : L'élève propose des interprétations tout à fait justes et pertinentes des citations et analyses avancées ; ces interprétations permettent tout à fait de faire avancer sa thèse, c'est-à-dire sa réponse à la question problématique posée en introduction.

# Aptitude à construire une réflexion en prenant appui sur un texte et à la rendre intelligible.

## Mon travail est correctement mis en page (titres soulignés, saut de ligne entre les parties, alinéas au début de chaque paragraphe, références aux lignes correctement indiquées...).

- Non maîtrisé : La mise en page de la copie est à revoir entièrement : les titres des oeuvres cités ne sont pas soulignés, les références aux lignes après les citations ne sont pas entre parenthèses (format = (l.x) ou x est la ligne de la citation ; l'élève peut également écrire en toutes lettres, avant la citation, par exemple : "... comme nous pouvons le voir à la ligne x : "citation""), on ne distingue pas les différents paragraphes du développement car il n'y a pas d'alinéa, les sauts de lignes ne sont pas respectées entre les parties...
- Insuffisamment maîtrisé : La mise en page globale est bien présente et on distingue bien les différents blocs la composant (introduction, développement avec les différents paragraphes qui le composent, conclusion), mais les éléments de mise ne page plus précis, comme les titres soulignés, les références aux lignes ou les alinéas, ne sont pas encore bien en place.
- En cours de maîtrise : La mise en page est globalement bien en place. On dénombre quelques erreurs mineures ici et là (un titre non souligné, une référence aux lignes qui n'est pas entre parenthèse etc.).
- Maîtrisé : La mise en page est parfaitement en place, toutes les règles et normes de l'exercice cités plus haut sont bien respectées.

## Mon travail est correctement construit, comprenant une introduction, un développement en plusieurs parties avec des sous-parties et une conclusion.

- Non maîtrisé : Le travail présenté est un bloc unique dans lequel on ne distingue pas les différentes parties exigées : introduction, développement en deux ou trois axes avec deux ou trois sous-parties chacun - on va à la ligne et on fait un alinéa entre les sous-parties, on saute une ligne entre les axes, après l'introduction et avant la conclusion).
- Insuffisamment maîtrisé : Le travail est globalement correctement agencé, avec une introduction, une conclusion (comprenant une réponse à la problématique et, si ce n'est fait dans le corps du développement, une synthèse des axes), mais l'ensemble des paragraphes de développement n'est pas présent (une copie de commentaire doit avoir au moins 6 paragraphes de développements, partagés en 2 axes, donc 3 paragraphes de développement par axe).
- En cours de maîtrise : Le travail est globalement bien agencé, l'introduction et la conclusion sont bien en place, tout comme les paragraphes de développement, qui sont bien construits, mais certains sont encore trop longs ou, à l'inverse, trop petits.
- Maîtrisé : Le travail est bien construit, avec une introduction, un développement complet et une conclusion.

*Point de vigilance* : Ce critère ne porte que sur la présence et la séparation typographique des parties, pas sur l'équilibre ou la qualité du contenu de chaque axe.

## Mon introduction est complète, comprenant une présentation de l'extrait, une problématique et une annonce du plan correctement formulées.

- Non maîtrisé : L'introduction est très incomplète, il lui manque un ou plusieurs éléments (à savoir, la présentation de l'extrait = titre, date, auteur, genre, mouvement littéraire, thème + tout autre élément permettant de présenter l'extrait, de le situer dans son contexte etc.).
- Insuffisamment maîtrisé : Les éléments de l'introduction (présentation de l'extrait, présentation de la problématique, annonce du plan) sont bien présents, mais plusieurs d'entres eux ne sont pas encore complets ou correctement agencés (par exemple, la présentation de l'extrait est incomplète et l'annonce du plan est maladroite, nous empêchant de bien distinguer les axes, ou bien cette dernière annonce les axes ET les sous-parties, alors que celles-ci ne doivent pas être annoncées en introduction).
- En cours de maîtrise : L'ensemble des éléments de l'introduction sont bien présents, mais il reste une ou deux imprécisions, tout au plus.
- Maîtrisé : L'ensemble des éléments de l'introduction sont bien présents et complets.

## Mes paragraphes de développement sont correctement construits, avec un argument, des citations dûment analysées étayant ce dernier et une interprétation faisant avancer ma réflexion.

- Non maîtrisé : L'ensemble des paragraphes de développement sont à revoir, ne possédant pas les différentes étapes nécessaires : argument, citation(s) analysé(s) et interprétation faisant avancer la réflexion.
- Insuffisamment maîtrisé : Les paragraphes de développement ne sont pas encore complets, il leur manque tantôt un argument, tantôt des procédés littéraires ou une interprétation.
- En cours de maîtrise : Les paragraphes de développement sont bien agencés, mais il y a encore quelques oublis ici et là, notamment sur les interprétations, dont certaines sont encore absentes.
- Maîtrisé : Les paragraphes de développement sont parfaitement construits, on y distingue bien l'argument justifiant l'axe, la ou les citations les illutrant correctement analysés avec des procédés précis et une interprétation expliquant en quoi l'ensemble fait avencer la thèse.

# Maîtrise de la langue et de l'expression à l'écrit.

## Les normes orthographiques et syntaxiques sont bien respectées.

- Non maîtrisé : La copie est remplies de fautes d'orthographes et de syntaxe suffisamment graves pour qu'on ne parvienne plus à comprendre ce qu'on lit. On peut également relever ici une graphie rendant la copie illisible.
- Insuffisamment maîtrisé : De nombreuses fautes d'orthographe et de syntaxe traversent encore la copie, produisant de temps à autres des ruptures syntaxiques qu'il serait urgent pour l'élève de corriger.
- En cours de maîtrise : Le copie est globalement bien écrite, surtout du point de vue de la syntaxe. En effet, les phrases sont correctement construites, sans ruptures ou presque (on pourra accepter une ou deux ruptures syntaxiques si la copie est par ailleurs bien écrite). Quelques fautes d'orthographe (lexicale ou syntaxique) subsistent néanmoins, mais ne nuisent pas à la compréhension de l'ensemble.
- Maîtrisé : La copie est parfaitement bien rédigé, tant pour ce qui est de l'orthographe que de la syntaxe. On peut admettre ici quelques fautes mineures d'orthographe, mais pas de syntaxe.

## Le style est fluide et le propos cohérent.

- Non maîtrisé : La style est confus, les phrases sont bien trops longues et même quand la syntaxe est correcte, on ne comprends pas toujours où l'élève veut-il en venir. L'ensemble manque ainsi de cohérence.
- Insuffisamment maîtrisé : Le style manque encore par moments de cohérence, est parfois maladroit ou enfantin.
- En cours de maîtrise : Le style est globalement correct, mais il faut encore approfondir l'agencement des connecteurs logiques entre les phrases et paragraphes.
- Maîtrisé : Le style est bien maîtrisé, fluide et propre, avec des phrases complexes correctement agencées et des connecteurs logiques bien employés et faisant avancer correctement la réflexion.

## Le niveau de langue employé est bien adapté à l'exercice.

- Non maîtrisé : L'élève utilise un vocabulaire trop familier et oral.
- Insuffisamment maîtrisé : L'élève utilise un vocabulaire oscillant encore beaucoup trop entre le niveau de langue attendu et le niveau familier / oral.
- En cours de maîtrise : L'élève utilise un niveau de langue approprié, mais quelques mots de vocabulaire pourraient encore être corrigés.
- Maîtrisé : L'élève utilise un niveau de langue parfaitement adapté à l'exercice, sans oralités ni familiarités.`

// "Introduction" (Gabriel, 2026-10-01) — corrects just the introduction of a
// commentaire/dissertation when it's produced as a shared piece of group
// work (the rest of the copy, ex. un paragraphe argumenté, being corrected
// individually via its own separate grid/évaluation) — see
// [[gh-corrections-plugin]]. Verbatim from Gabriel's own
// lib/grids/introduction.md, including his own phrasing — same posture as
// COMMENTAIRE_FORMATIF_MD above, this is the single source of truth he
// keeps editing directly (see that file for the editable mirror).
var INTRODUCTION_MD = `# La présentation de l'extrait est complète et bien formulée.
- Non maîtrisé : La présentation de l'extrait est très maladroitement exprimée et le contenu est très imprécis et incomplet.
- Insuffisamment maîtrisé : La présentation de l'extrait est maladroitement exprimée et le contenu est encore imprécis.
- En cours de maîtrise : La présentation de l'extrait est bien formulée et son contenu satisfaisant, mais quelques imprécisions persistent.
- Maîtrisé : La présentation de l'extrait est bien formulée et complète.

# L'annonce de la problématique est complète et bien formulée.
- Non maîtrisé : La problématique n'est pas du tout cohérente avec le plan qui suit, ne permet pas d'engager une réflexion sur le texte à étudier et n'est pas correctement formulée.
- Insuffisamment maîtrisé : La problématique n'est pas tout à fait cohérente avec le plan qui suit, et ce, quand bien même la formulation pourrait être tout à fait juste.
- En cours de maîtrise : La problématique est juste, cohérente avec le plan qui suit, mais la formulation peut encore gagner en précision.
- Maîtrisé : La problématique est juste, cohérente avec le plan qui suit et parfaitement bien formulée.

_Point de vigilance : si le sujet fourni une problématique et des axes, on s'attend à ce que ceux-ci soient correctement restituées dans l'introduction proposée. Aucun jugement concernant leur contenu n'est ainsi attendu._

# L'annonce des axes est complet et bien formulé.
- Non maîtrisé : L'annonce des axes n'est pas du tout cohérente avec la problématique qui précède, ne permet pas de structurer une réflexion sur le texte à étudier et n'est pas correctement formulée.
- Insuffisamment maîtrisé : L'annonce des axes n'est pas tout à fait cohérente avec la problématique qui précède, et ce, quand bien même la formulation pourrait être tout à fait juste.
- En cours de maîtrise : L'annonce des axes est juste, cohérent avec la problématique qui précède, mais la formulation peut encore gagner en précision.
- Maîtrisé : L'annonce des axes est juste, cohérente avec la problématique qui précède et parfaitement bien formulée.


_Point de vigilance : si le sujet fourni une problématique et des axes, on s'attend à ce que ceux-ci soient correctement restituées dans l'introduction proposée. Aucun jugement concernant leur contenu n'est ainsi attendu. Par ailleurs, on ne doit annoncer que les axes et jamais les sous-parties que ceux-ci contiennent._

# Les normes orthographiques et syntaxiques sont bien respectées.

- Non maîtrisé : L'introduction est remplies de fautes d'orthographes et de syntaxe suffisamment graves pour qu'on ne parvienne plus à comprendre ce qu'on lit. On peut également relever ici une graphie rendant la copie illisible.
- Insuffisamment maîtrisé : De nombreuses fautes d'orthographe et de syntaxe traversent l'introduction, produisant de temps à autres des ruptures syntaxiques qu'il serait urgent pour l'élève de corriger.
- En cours de maîtrise : L'introduction est globalement bien écrite, surtout du point de vue de la syntaxe. En effet, les phrases sont correctement construites, sans ruptures ou presque (on pourra accepter une ou deux ruptures syntaxiques si la copie est par ailleurs bien écrite). Quelques fautes d'orthographe (lexicale ou syntaxique) subsistent néanmoins, mais ne nuisent pas à la compréhension de l'ensemble.
- Maîtrisé : La copie est parfaitement bien rédigé, tant pour ce qui est de l'orthographe que de la syntaxe. On peut admettre ici quelques fautes mineures d'orthographe, mais pas de syntaxe.`

// "Paragraphe argumenté" (Gabriel, 2026-10-01) — corrects the individual
// paragraph each student writes after a shared group introduction (see
// INTRODUCTION_MD above). Headings only, no palier descriptions/vigilance
// notes written yet — fine as-is for manual ticking in "Eval. Compétences"
// (buildGridRubricText() just returns "" for an agent prompt if this grid
// is ever used in the grid-first Corrections pipeline instead, same
// graceful degradation as any other headings-only grid).
var PARAGRAPHE_ARGUMENTE_MD = `# Aptitude à comprendre un texte littéraire.


# Aptitude à analyser et à interpréter un texte littéraire.
## Les analyses proposées sont justes et s'appuient sur un vocabulaire littéraire précis.
## Les interprétations proposées permettent de faire avancer la réflexion proposée par la problématique.


# Aptitude à construire une réflexion en prenant appui sur un texte et à la rendre intelligible.
## Mon travail est correctement mis en page (titres soulignés, saut de ligne entre les parties, alinéas au début de chaque paragraphe, références aux lignes correctement indiquées...).
## Mes paragraphes de développement sont correctement construits, avec un argument, des citations dûment analysées étayant ce dernier et une interprétation faisant avancer ma réflexion.


# Maîtrise de la langue et de l'expression à l'écrit.
## Les normes orthographiques et syntaxiques sont bien respectées.
## Le style est fluide et le propos cohérent.
## Le niveau de langue employé est bien adapté à l'exercice.`

// "Plan détaillé guidé" (Gabriel, 2026-10-06) — built in GH Grilles and
// pasted via "Copier au format GH Classes"; mirror in
// lib/grids/plan-detaille-guide.md. Four top-level criteria, no sub-items, so
// every row is checkable. Headings only, no palier descriptions.
var PLAN_DETAILLE_GUIDE_MD = `# Être capable de citer le texte en le classant de façon pertinente dans le plan.
# Être capable d'analyser avec précision les citations relevées en utilisant, pour ce faire, un vocabulaire littéraire précis.
# Être capable d'expliquer l'effet produit par un procédé d'analyse littéraire.
# Savoir organiser son travail afin de maintenir un rythme de travail suffisant.`

var GRIDS = [
  { id: "commentaire", name: "Commentaire EAF", rows: parseGridMarkdown(COMMENTAIRE_EAF_MD) },
  // Renamed from "Commentaire formatif" (Gabriel, 2026-10-01) — id kept
  // unchanged, stored answers key off id, not name, see the header comment
  // above.
  { id: "commentaire-formatif", name: "Commentaire de texte", rows: parseGridMarkdown(COMMENTAIRE_FORMATIF_MD) },
  { id: "introduction", name: "Introduction", rows: parseGridMarkdown(INTRODUCTION_MD) },
  { id: "paragraphe-argumente", name: "Paragraphe argumenté", rows: parseGridMarkdown(PARAGRAPHE_ARGUMENTE_MD) },
  { id: "plan-detaille-guide", name: "Plan détaillé guidé", rows: parseGridMarkdown(PLAN_DETAILLE_GUIDE_MD) }
]

function findGrid(id) {
  for (var i = 0; i < GRIDS.length; i++) if (GRIDS[i].id === id) return GRIDS[i]
  return null
}

// Fraction of a criterion's own points earned at each palier — Gabriel,
// 2026-09-27, replacing the earlier weighted-AVERAGE-of-official-barème-
// midpoints model: that one had a hard mathematical floor (an average can
// never go below its worst input, so a copy weak on EVERY criterion still
// landed around 9/20, the "Insuffisamment maîtrisé" midpoint, no matter
// how weights were redistributed — verified on a real copy). A SUM of
// earned points has no such floor: a copy weak across the board can
// genuinely sum to a low total, because weaknesses accumulate instead of
// averaging out.
var PALIER_FRACTIONS = [0, 1 / 3, 2 / 3, 1] // Non maîtrisé, Insuffisant, En cours, Maîtrisé

// weights: { "<rowIndex>": points out of 20 } — Gabriel assigns each
// criterion its own point value (ideally summing to 20 across the grid,
// not enforced here), via the "⚖️ Répartir les points" popover. Each
// checked, weighted row contributes points × PALIER_FRACTIONS[level] to
// the total; unweighted or not-yet-checked rows contribute nothing rather
// than being counted as 0, so a partially-filled grid still gives a
// sensible running total. Deliberately produces ONE exact number (Gabriel:
// "chiffrer exactement sur 20 points") rather than a range — severe and
// bienveillante both carry it, so the rest of the pipeline (override,
// display, export) doesn't need to change shape. Gabriel then reweights
// this by hand as needed (progrès de l'élève, contexte du devoir...) —
// this is a starting figure, not a verdict.
function computeWeightedNote(grid, checks, weights) {
  if (!grid) return { severe: "", bienveillante: "" }
  checks = checks || {}
  weights = weights || {}
  var total = 0
  var anyAssigned = false
  grid.rows.forEach(function(row, idx) {
    if (!row.checkable) return
    var points = Number(weights[idx] || 0)
    if (points <= 0) return
    var level = checks[idx]
    if (level === undefined || level === null || PALIER_FRACTIONS[level] === undefined) return
    anyAssigned = true
    total += points * PALIER_FRACTIONS[level]
  })
  if (!anyAssigned) return { severe: "", bienveillante: "" }
  var note = formatNote(total)
  return { severe: note, bienveillante: note }
}

// French grading convention: halves only ("14" or "14,5", never "14,4"),
// comma as the decimal separator — Gabriel, 2026-09-27 (arbitrary tenths
// with a period read as a formatting bug, not a real grade).
function formatNote(n) {
  var rounded = Math.round(n * 2) / 2
  if (Math.abs(rounded - Math.round(rounded)) < 0.01) return String(Math.round(rounded))
  return String(Math.floor(rounded)) + ",5"
}

// Typst's reserved markup characters — escaped so a criterion/name/class
// containing one of these renders as literal text instead of breaking out
// into markup (e.g. a class name with a "#" in it).
function escapeTypst(s) {
  return String(s || "").replace(/[\\#*_$<>@`]/g, "\\$&")
}

// A hard line break the user typed (Enter) must survive into the PDF as a
// visual line break, not get folded into a space the way a lone newline
// normally is in Typst markup — hence #linebreak() between escaped lines
// rather than just joining on "\n".
function toTypstMultiline(text) {
  return escapeTypst(text).split("\n").join(" #linebreak() ")
}

// French school year (rentrée in September) for the footer — "2026-2027"
// from a date anywhere between September 2026 and August 2027 inclusive.
function currentSchoolYear() {
  var now = new Date()
  var y = now.getFullYear()
  return (now.getMonth() + 1 >= 9) ? (y + "-" + (y + 1)) : ((y - 1) + "-" + y)
}

// payload: { checks: { [rowIndex]: colIndex }, appreciation, note,
// justifications, includeJustifications, inlineNote } for one student on
// one grid. justifications/includeJustifications/inlineNote are all
// optional (Gabriel, 2026-09-27, for the Corrections tab's grid-first
// pipeline only — the older Eval. Compétences tab never sets them, and
// omitting them here reproduces exactly its previous output, unchanged).
// intitule is the assignment's own title (e.g. "Devoir sur table n°2"),
// shown as a header — omitted entirely if blank. baremeTotal (Gabriel,
// 2026-10-01) is the évaluation's own grading scale (10 or 20) — only the
// Corrections tab's évaluations carry one (CorrectionsStore.Evaluation
// .baremeTotal); the older Eval. Compétences tab's own call site omits it,
// defaulting to 20, unchanged. Produces a self-contained .typ source (no
// external imports/template) so it compiles standalone via `typst compile`.
function buildTypstSource(studentLabel, className, grid, payload, intitule, baremeTotal) {
  payload = payload || {}
  var total = Number(baremeTotal) === 10 ? 10 : 20
  var checks = payload.checks || {}
  var justifications = payload.justifications || {}
  var appreciation = String(payload.appreciation || "").trim()
  var note = String(payload.note || "").trim()
  intitule = String(intitule || "").trim()
  var footerText = "M.Harfield - " + escapeTypst(className) + " - " + currentSchoolYear()
  var lines = []
  lines.push("#set page(")
  lines.push("  margin: 2cm,")
  lines.push("  footer: align(center)[_" + footerText + "_]")
  lines.push(")")
  // hyphenate: true matters here — "Insuffisamment" alone is wider than the
  // narrow 2.1cm level columns below, and without it Typst won't break a
  // long word without a space, so it just overflows into the next column.
  lines.push("#set text(size: 11pt, lang: \"fr\", hyphenate: true)")
  lines.push("")
  if (intitule) {
    lines.push("#align(center)[#text(size: 13pt, weight: \"bold\")[" + escapeTypst(intitule) + "]]")
    lines.push("#v(0.8em)")
  }
  lines.push("#text(size: 16pt, weight: \"bold\")[" + escapeTypst(studentLabel) + "]")
  lines.push("#v(0.4em)")
  lines.push("#text(size: 13pt, weight: \"bold\")[" + escapeTypst(grid.name) + "]")
  lines.push("#v(0.6em)")
  lines.push("")
  // Fixed, narrow level columns (Critères takes whatever's left) so the
  // table doesn't balloon out with "auto" — headers wrap onto two lines
  // where needed, same trade-off as the app's own table.
  lines.push("#table(")
  lines.push("  columns: (1fr, 2.1cm, 2.1cm, 2.1cm, 2.1cm),")
  lines.push("  align: (left, center, center, center, center),")
  lines.push("  table.header([*Critères*], " + COLUMNS.map(function(c) { return "[*" + escapeTypst(c) + "*]" }).join(", ") + "),")
  grid.rows.forEach(function(row, idx) {
    if (!row.checkable) {
      lines.push("  table.cell(colspan: 5, fill: luma(235))[*" + escapeTypst(row.text) + "*],")
      return
    }
    var marks = [0, 1, 2, 3].map(function(ci) { return checks[idx] === ci ? "X" : "" })
    if (row.level > 1) {
      // A sub-item under a greyed section header: indented (#h) and
      // lightly shaded across the whole row, so it visually reads as
      // belonging to that header rather than a top-level criterion.
      var label = "table.cell(fill: luma(248))[#h(1em)" + escapeTypst(row.text) + "]"
      var cells = marks.map(function(m) { return "table.cell(fill: luma(248))[" + m + "]" })
      lines.push("  " + label + ", " + cells.join(", ") + ",")
    } else {
      var plainCells = marks.map(function(m) { return "[" + m + "]" })
      lines.push("  [" + escapeTypst(row.text) + "], " + plainCells.join(", ") + ",")
    }
  })
  lines.push(")")
  lines.push("")
  if (payload.includeJustifications) {
    lines.push("#v(0.8em)")
    lines.push("*Commentaires par critère*")
    lines.push("")
    grid.rows.forEach(function(row, idx) {
      if (!row.checkable) return
      var j = String(justifications[idx] || "").trim()
      if (!j) return
      lines.push("- *" + escapeTypst(row.text) + "* — " + escapeTypst(j))
    })
    lines.push("")
  }
  lines.push("#v(1.2em)")
  lines.push("*Appréciation*")
  lines.push("")
  if (payload.inlineNote) {
    // Gabriel, 2026-09-27: for the grid-first pipeline's export (a single
    // exact note now, not a range — see computeWeightedNote()), the note
    // sits in bold at the very end of the appreciation paragraph itself
    // rather than as its own separate block below.
    var body = appreciation ? toTypstMultiline(appreciation) : "#text(fill: luma(150))[—]"
    var suffix = note ? " *" + escapeTypst(note) + "/" + total + "*" : ""
    lines.push(body + suffix)
  } else {
    lines.push(appreciation ? toTypstMultiline(appreciation) : "#text(fill: luma(150))[—]")
    lines.push("")
    lines.push("#v(1em)")
    lines.push("*Note : * " + (note ? escapeTypst(note) : "……") + " / " + total)
  }
  return lines.join("\n")
}

// A pipe inside a GFM table cell breaks the table; a literal newline would
// too (it'd be read as a new table row), so both get neutralized — no
// other escaping needed for plain markdown the way Typst needs escapeTypst.
function escapeMarkdownCell(s) {
  return String(s || "").replace(/\|/g, "\\|").replace(/\r?\n/g, " ")
}

// Plain-markdown twin of buildTypstSource (Gabriel, 2026-10-01, "Eval.
// Compétences" tab's own "📋 Copier le code markdown" button) — same
// payload shape, no justifications/inlineNote support since that tab never
// sets them (grid-first Corrections pipeline only, see buildTypstSource's
// own header comment). A plain GFM table can't colspan, so a non-checkable
// section-header row just gets its text bolded in the first column with
// the level columns left blank, rather than Typst's shaded colspan cell.
function buildMarkdownSource(studentLabel, className, grid, payload, intitule, baremeTotal) {
  payload = payload || {}
  var checks = payload.checks || {}
  var appreciation = String(payload.appreciation || "").trim()
  var note = String(payload.note || "").trim()
  intitule = String(intitule || "").trim()
  var total = Number(baremeTotal) === 10 ? 10 : 20
  var lines = []
  if (intitule) {
    lines.push("# " + intitule)
    lines.push("")
  }
  lines.push("**" + studentLabel + "** — " + grid.name + " (" + className + ")")
  lines.push("")
  lines.push("| Critères | " + COLUMNS.join(" | ") + " |")
  lines.push("| --- | " + COLUMNS.map(function() { return ":-:" }).join(" | ") + " |")
  grid.rows.forEach(function(row, idx) {
    if (!row.checkable) {
      lines.push("| **" + escapeMarkdownCell(row.text) + "** | " + COLUMNS.map(function() { return " " }).join(" | ") + " |")
      return
    }
    var marks = [0, 1, 2, 3].map(function(ci) { return checks[idx] === ci ? "X" : " " })
    var label = (row.level > 1 ? "&nbsp;&nbsp;" : "") + escapeMarkdownCell(row.text)
    lines.push("| " + label + " | " + marks.join(" | ") + " |")
  })
  lines.push("")
  lines.push("**Appréciation**")
  lines.push("")
  lines.push(appreciation || "_—_")
  lines.push("")
  lines.push("**Note : " + (note || "……") + " / " + total + "**")
  return lines.join("\n")
}

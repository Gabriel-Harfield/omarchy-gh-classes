// Prompt for the per-copy correction agent (headless Claude Code, run with
// file access — see ClaudeRunner.buildFileCommand). Same "convention-based
// scoping" security model as GH Slide: every path Claude may read or write
// is named explicitly, the run is unattended (no question-asking), and the
// process's working directory is a dedicated per-run folder.
//
// The three output files (appreciation + log + notes) are the load-bearing
// contract the rest of this feature is built on: Panel.qml reads them back
// after the process exits — log.md's content (RAS vs. anything else) is
// what drives the "needs review" flag on the student's row, and notes.txt
// is parsed by parseGrades() below into the three proposed grades, plus
// parseLisibilite() into the agent's self-reported reading-difficulty level
// (drives the readability dot next to "Copier le code" on the student's
// row). This contract is enforced here regardless of what the user's own
// consignes.md/agent.md files say — those two are read BY Claude for the
// substance of the correction, not by this plugin.
//
// Anonymization (Gabriel, 2026-09-19): this prompt never names the student,
// and copyPath here is expected to already point at a copy Panel.qml has
// renamed to something anonymous (see copyCorrectionCopyForRun()) — the
// original, name-bearing file is never referenced from here.

.pragma library

function build(params) {
  var p = params || {}
  var lines = []

  lines.push("Tu es un agent de correction pédagogique, invoqué automatiquement et sans supervision humaine immédiate.")
  lines.push("")
  var writingMode = p.writingMode === "tapuscrit" ? "tapuscrit" : "manuscrit"

  lines.push("## Élève concerné")
  lines.push("Cette correction est anonymisée à dessein : ni le nom de l'élève, ni le nom du fichier ne te sont communiqués, et le fichier de la copie ci-dessous a été renommé pour ne porter aucune trace de son identité. Ne cherche jamais à deviner ou reconstituer qui est l'élève à partir du contenu — ce n'est ni ton rôle, ni nécessaire pour corriger.")
  lines.push("Copie à corriger (PDF) : " + String(p.copyPath || ""))
  lines.push("Type d'écriture : " + (writingMode === "manuscrit" ? "manuscrite" : "tapée à l'ordinateur (tapuscrit)"))
  if (writingMode === "manuscrit") {
    lines.push("Cette copie étant manuscrite, sois particulièrement prudent dans le déchiffrage de l'écriture : si un mot, une phrase ou un passage est illisible, ambigu, ou que tu n'es pas sûr d'avoir bien lu, NE DEVINE PAS silencieusement — signale-le précisément dans le fichier de log pour que l'enseignant vérifie.")
  }
  lines.push("")

  lines.push("## Niveau de lisibilité — à évaluer AVANT de corriger, règle impérative")
  lines.push("Avant de rédiger quoi que ce soit, évalue la lisibilité de l'écriture de la copie et classe-la dans l'un de ces trois niveaux :")
  lines.push("- LISIBLE : aucun souci de compréhension, la copie se lit sans effort particulier.")
  lines.push("- DIFFICILE : quelques passages gênent la lecture (graphie, ratures, organisation confuse...), mais l'essentiel de la copie reste compréhensible — tu peux corriger normalement en signalant ces passages ponctuels dans le log.")
  lines.push("- ILLISIBLE : une part de la copie est si difficile à déchiffrer que rédiger une appréciation complète t'obligerait à SURINTERPRÉTER — à reconstruire du sens plutôt qu'à le lire réellement.")
  if (writingMode === "tapuscrit") {
    lines.push("Cette copie étant tapuscrite, ce niveau sera presque toujours LISIBLE ; ne le baisse que si le fichier lui-même pose un problème de lecture (contenu corrompu, tronqué...).")
  }
  lines.push("Si tu conclus ILLISIBLE : NE TENTE PAS de rédiger l'appréciation normale en trois paragraphes. Laisse le fichier d'appréciation vide (ou n'y écris qu'une seule phrase de constat, ex. \"Copie jugée illisible par l'agent — relecture manuelle nécessaire.\"), détaille dans le log précisément quels passages/quelles zones posent problème, et écris N/A à la place de chacune des trois notes chiffrées plutôt que d'en inventer une. L'enseignant lira la copie lui-même dans ce cas — ton rôle s'arrête à le signaler clairement, pas à deviner à sa place.")
  lines.push("")

  lines.push("## Registre de langage — règle impérative")
  lines.push("Dans l'appréciation, adresse-toi TOUJOURS directement à l'élève à la deuxième personne du PLURIEL (vouvoiement) — jamais de tutoiement, quel que soit l'âge ou le niveau de l'élève. Exemple : \"vous entrez bien dans l'exercice\", jamais \"tu entres bien dans l'exercice\" ni \"Victoria entre bien dans l'exercice\" à la troisième personne.")
  lines.push("N'interpelle JAMAIS l'élève par son prénom ou son nom, nulle part dans le texte — ni en ouverture, ni en cours d'appréciation (pas de \"Marie, votre travail est...\"). Une appréciation de copie n'est pas une lettre adressée à l'élève par son nom : commence directement par une observation sur le travail, sans salutation ni vocatif.")
  lines.push("")

  if (p.niveauClasse || p.bienveillance !== undefined) {
    lines.push("## Contexte de l'évaluation")
    if (p.niveauClasse) lines.push("Niveau de classe : " + String(p.niveauClasse))
    if (p.bienveillance !== undefined && p.bienveillance !== "") lines.push("Niveau de bienveillance demandé : " + String(p.bienveillance) + "/10 (0 = très sévère, 10 = très bienveillant) — voir aussi les paramètres détaillés dans les consignes.")
    lines.push("")
  }

  var addendum = String(p.addendum || "").trim()
  if (addendum) {
    lines.push("## Complément de l'enseignant, spécifique à CETTE correction")
    lines.push("Ceci a été ajouté par l'enseignant après une première correction de cette copie précise (ex. suite à une relecture de son log). Prends-le en compte EN PRIORITÉ et ajuste ton appréciation, ton log et tes trois notes en conséquence :")
    lines.push(addendum)
    lines.push("")
  }

  lines.push("## Fichiers de référence pour cette évaluation")
  lines.push("- Sujet (PDF) : " + String(p.sujetPath || ""))
  if (p.corrigePath) {
    lines.push("- Corrigé (PDF) : " + String(p.corrigePath))
  } else {
    lines.push("- Corrigé : aucun fourni pour cette évaluation (cas fréquent, ex. une fiche de lecture où chaque élève a lu un livre différent) — base-toi uniquement sur le sujet et les consignes pour évaluer la copie.")
  }
  lines.push("- Consignes de correction (markdown) : " + String(p.consignesPath || "") + " — lis ce fichier en premier : il définit les attentes et le barème de cette évaluation.")
  lines.push("- Instructions pour toi, l'agent (markdown) : " + String(p.agentPath || "") + " — lis ce fichier et applique-le rigoureusement pour construire ta réponse (ton, longueur, angle de correction).")
  lines.push("")
  lines.push("## Ce que tu dois produire")
  lines.push("1. Lis les fichiers de référence ci-dessus (sujet, corrigé s'il est fourni, consignes, agent), puis lis la copie de l'élève.")
  lines.push("2. Corrige la copie et rédige une appréciation, dans le style et la longueur indiqués par les instructions de l'agent et les consignes.")
  lines.push("   Structure TOUJOURS l'appréciation en exactement trois paragraphes, dans cet ordre : Méthode, puis Contenu, puis Expression écrite — quelle que soit l'organisation des critères dans les consignes. Si les consignes classent déjà leurs critères sous ces trois mêmes catégories, respecte cette répartition ; sinon, range chaque critère évalué dans la catégorie la plus pertinente parmi les trois. Pas de titres de paragraphe ni de liste à puces dans le rendu final : trois paragraphes de prose, séparés par un saut de ligne.")
  if (p.niveauDetail === "faible") {
    lines.push("   Niveau de détail attendu — FAIBLE : reste bref, un paragraphe court (2 à 3 phrases) par catégorie, sans développer au-delà du nécessaire.")
  } else if (p.niveauDetail === "eleve") {
    lines.push("   Niveau de détail attendu — ÉLEVÉ : développe chaque paragraphe (5 à 8 phrases), en citant et commentant plusieurs passages précis de la copie pour illustrer ton propos.")
  }
  lines.push("3. Écris le CODE TYPST de cette appréciation — uniquement le texte de l'appréciation en syntaxe Typst, pas un document complet (pas de #import, pas de #set page) — exactement dans ce fichier, et nulle part ailleurs : " + String(p.appreciationOutputPath || ""))
  lines.push("4. Écris exactement dans ce fichier, et nulle part ailleurs : " + String(p.logOutputPath || ""))
  lines.push("   - Si tu n'as aucune remarque particulière sur cette correction : écris exactement le mot RAS, rien d'autre.")
  lines.push("   - Sinon, UN POINT PAR LIGNE, chaque ligne commençant par \"- \" : un doute, une difficulté de lecture de la copie, ou un besoin de précision ou d'arbitrage sur ce cas précis. Sois SYNTHÉTIQUE — tirets, formulations courtes (une phrase ou moins par point, quitte à utiliser des flèches ou des raccourcis) plutôt que des paragraphes rédigés : l'enseignant doit pouvoir lire et traiter chaque point d'un coup d'œil, indépendamment des autres.")
  if (p.usesPlanExtraction) {
    lines.push("   - AVANT ces points de vigilance, ajoute dans ce même fichier une section \"## Plan restitué\" : restitue la problématique, le titre de chaque axe et l'argument de chaque sous-partie tels que décrits dans les consignes (section \"Méthode — comment lire un commentaire rédigé\"). Pour chaque élément, précise entre parenthèses s'il est TROUVÉ (formulé clairement), RECONSTRUIT (tu as dû l'inférer) ou ABSENT — ce niveau de détail n'est pas optionnel, c'est lui qui permet d'évaluer la complétude et l'équilibre du plan, jamais un simple \"plan cohérent\" en une phrase.")
  }
  lines.push("5. Propose TROIS notes chiffrées sur 20 pour cette copie, correspondant à trois postures de correction plausibles du même travail : sévère, neutre, bienveillante. Ce ne sont pas trois notes arbitraires : ce sont trois lectures argumentées et cohérentes entre elles (l'écart doit rester raisonnable), qui s'appuient sur les mêmes constats mais pondèrent différemment la rigueur. Si les consignes donnent un barème ou des paliers indicatifs, utilise-les comme repère pour calibrer ces trois notes, sans les appliquer de façon mécanique — ils restent indicatifs, y compris pour toi. Si tu as conclu ILLISIBLE à l'étape de lisibilité ci-dessus, n'invente aucune de ces trois notes : écris N/A pour chacune.")
  lines.push("   Écris ces trois notes ainsi que le niveau de lisibilité exactement dans ce fichier, et nulle part ailleurs : " + String(p.notesOutputPath || "") + ", sous ce format strict, une ligne par valeur, rien d'autre :")
  lines.push("   LISIBILITE: <LISIBLE|DIFFICILE|ILLISIBLE>")
  lines.push("   SEVERE: <note>/20 (ou N/A)")
  lines.push("   NEUTRE: <note>/20 (ou N/A)")
  lines.push("   BIENVEILLANTE: <note>/20 (ou N/A)")
  lines.push("")
  lines.push("## Consignes techniques impératives")
  lines.push("- Ne lis aucun fichier en dehors de ceux listés ci-dessus (sujet, corrigé, consignes, agent, copie de l'élève).")
  lines.push("- N'écris aucun fichier en dehors des trois chemins de sortie indiqués ci-dessus (des fichiers de travail temporaires dans le même dossier qu'eux sont acceptables).")
  lines.push("- Ne pose aucune question : personne ne peut te répondre dans l'immédiat. Fais les choix nécessaires toi-même et signale tes doutes dans le fichier de log plutôt que d'attendre une réponse.")
  lines.push("- Ne génère aucune image de prévisualisation ni aucune sortie superflue : les trois fichiers ci-dessus sont les seuls livrables attendus.")

  return lines.join("\n")
}

// Cheaper alternative to a full recorrection (Gabriel, 2026-09-18): only
// used once an appreciation already exists and Gabriel has commented on
// specific log points. Revises the EXISTING appreciation text in light of
// those comments — no file access needed (never re-reads the copy/sujet/
// consignes), so it runs via ClaudeRunner.buildCommand like the plain
// appreciation generator, not buildFileCommand. Deliberately restates
// (rather than shares) the vouvoiement/no-vocative/3-paragraph rules from
// build() above, so this prompt stays correct on its own even if build()
// changes later.
function buildReformulatePrompt(params) {
  var p = params || {}
  var lines = []

  lines.push("Tu dois RÉVISER une appréciation de copie déjà rédigée, à partir de remarques précises de l'enseignant — tu ne recorriges pas la copie depuis le début, tu ajustes le texte existant.")
  lines.push("")
  lines.push("## Appréciation actuelle (code Typst)")
  lines.push(String(p.currentAppreciation || ""))
  lines.push("")
  lines.push("## Remarques de l'enseignant à prendre en compte")
  ;(p.comments || []).forEach(function(c) {
    lines.push("- Point du log concerné : " + String(c.item || ""))
    lines.push("  Instruction de l'enseignant : " + String(c.comment || ""))
  })
  lines.push("")
  lines.push("## Ce que tu dois produire")
  lines.push("Réécris l'appréciation en intégrant CHACUNE des remarques ci-dessus, en modifiant le moins possible le reste du texte. Respecte impérativement les mêmes règles que pour une correction normale :")
  lines.push("- Vouvoiement systématique, jamais de tutoiement, jamais interpeller l'élève par son prénom ou son nom.")
  lines.push("- Structure en exactement trois paragraphes, dans cet ordre : Méthode, puis Contenu, puis Expression écrite — prose continue, sans titres ni puces.")
  lines.push("Réponds UNIQUEMENT avec le nouveau code Typst de l'appréciation, rien d'autre (pas d'explication, pas de commentaire sur ce que tu as changé).")

  return lines.join("\n")
}

// Tolerant KEY: value parser for notes.txt (same "degrade gracefully"
// posture as the rest of this codebase's parsing — see lib/Files.js and
// GH Slide's own review parser): a missing or unparseable line just
// leaves that grade blank rather than failing the whole correction.
function parseGrades(text) {
  var t = String(text || "")
  var severeMatch = t.match(/S[EÉ]V[EÈ]RE\s*:\s*([^\n\r]+)/i)
  var neutreMatch = t.match(/NEUTRE\s*:\s*([^\n\r]+)/i)
  var bienvMatch = t.match(/BIENVEILLANTE?\s*:\s*([^\n\r]+)/i)
  return {
    severe: severeMatch ? severeMatch[1].trim() : "",
    neutre: neutreMatch ? neutreMatch[1].trim() : "",
    bienveillante: bienvMatch ? bienvMatch[1].trim() : ""
  }
}

// Self-reported reading-difficulty level, same notes.txt file as the three
// grades (see build() above) — a missing/unparseable line just leaves this
// blank, same "degrade gracefully" posture as parseGrades(). Blank means
// "no signal" (ex. a correction done before this feature existed), not
// "lisible" — callers must not treat it as green by default.
function parseLisibilite(text) {
  var t = String(text || "")
  var m = t.match(/LISIBILIT[EÉ]\s*:\s*([^\n\r]+)/i)
  if (!m) return ""
  var v = m[1].trim().toUpperCase()
  if (v.indexOf("ILLISIBLE") !== -1) return "illisible"
  if (v.indexOf("DIFFICILE") !== -1) return "difficile"
  if (v.indexOf("LISIBLE") !== -1) return "lisible"
  return ""
}

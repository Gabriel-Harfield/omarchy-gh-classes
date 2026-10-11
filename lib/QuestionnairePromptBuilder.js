// Prompt de l'agent du pipeline QUESTIONNAIRE (Gabriel, 2026-10-11).
//
// Troisième circuit de l'onglet Corrections, à côté du pipeline grille de
// compétences (CompetencyPromptBuilder) et de l'ancien pipeline libre
// (CorrectionPromptBuilder). Ce qu'il a de propre :
//
//   - l'agent ne rédige AUCUNE appréciation. Un questionnaire se corrige
//     item par item contre un corrigé ; il n'y a pas de jugement global à
//     formuler, et le faire quand même produisait une prose creuse
//     (constat de l'onglet, 2026-10-03, sur le questionnaire de lecture) ;
//   - il ne calcule AUCUNE note : il coche, le plugin compte
//     (QuestionnaireGrid.computeNote) ;
//   - il répond par NUMÉRO d'item, jamais en recopiant le libellé : la
//     grille est déjà parsée côté plugin, et l'appariement ne doit pas
//     dépendre d'une recopie exacte de 80 caractères avec des guillemets
//     français dedans ;
//   - il doit rendre, pour chaque item, CE QU'IL A LU sur la copie
//     (REPONSE) et, quand il a dû trancher, POURQUOI (DOUTE). C'est la
//     leçon du test manuel du 2026-10-11 : une grille cochée en silence
//     oblige à relire les 30 lignes pour lui faire confiance, donc
//     n'économise rien ; une grille cochée avec ses arbitrages signalés
//     se relit en trois lignes.
//
// Le seuil de sévérité (une réponse juste mais incomplète vaut-elle la
// case pleine ?) est le SEUL vrai paramètre de cet exercice — il n'est
// pas écrit en dur ici : il vient de `consignes`, le texte que Gabriel
// écrit dans le wizard, plus la convention de l'italique sur la grille
// elle-même (voir QuestionnaireGrid.cellText()).

.pragma library

// params: { copyPath, writingMode, sujetPath, corrigePath, niveauClasse,
//           columns: [string], rows: [{text}], consignes, addendum,
//           pageImages: [{ label, path }] }
function buildFillPrompt(params) {
  var p = params || {}
  var cols = Array.isArray(p.columns) ? p.columns : []
  var rows = Array.isArray(p.rows) ? p.rows : []
  var writingMode = p.writingMode === "tapuscrit" ? "tapuscrit" : "manuscrit"
  var lines = []

  lines.push("Tu es un agent de correction pédagogique, invoqué automatiquement et sans supervision humaine immédiate.")
  lines.push("")

  lines.push("## Ta tâche, et UNIQUEMENT celle-ci")
  lines.push("Tu corriges un QUESTIONNAIRE : une liste de " + rows.length + " items dont la réponse attendue est connue. Pour chaque item, tu compares ce que l'élève a écrit à la réponse attendue, et tu coches EXACTEMENT UNE des " + cols.length + " cases.")
  lines.push("Tu ne rédiges aucune appréciation. Tu ne calcules aucune note, aucun total, aucun pourcentage : le décompte est fait automatiquement à partir de tes cases, et une addition de ta part ne serait ni lue ni utilisée.")
  lines.push("")

  lines.push("## Élève concerné")
  lines.push("Cette correction est anonymisée à dessein : ni le nom de l'élève, ni le nom du fichier ne te sont communiqués, et le fichier de la copie a été renommé pour ne porter aucune trace de son identité. Ne cherche jamais à deviner qui est l'élève.")
  lines.push("Type d'écriture : " + (writingMode === "manuscrit" ? "manuscrite" : "tapuscrite"))
  // Demi-pages pré-découpées par le plugin (voir Panel.qml,
  // startQuestionnairePageRender) : à taille d'affichage égale, une
  // demi-page porte deux fois plus de détail qu'une page entière, et
  // c'est ce qui fait la différence entre déchiffrer une écriture
  // manuscrite et la deviner. La liste peut être vide (découpe
  // impossible) — on retombe alors sur le PDF seul.
  var images = Array.isArray(p.pageImages) ? p.pageImages : []
  if (images.length > 0) {
    lines.push("La copie t'est fournie DÉCOUPÉE EN DEMI-PAGES, dans l'ordre de lecture — ouvre-les toutes, dans cet ordre, avant de commencer à cocher :")
    for (var im = 0; im < images.length; im++) {
      lines.push("- " + String(images[im].label || "") + " : " + String(images[im].path || ""))
    }
    lines.push("Ces images sont plus lisibles que le PDF d'origine : c'est sur elles que tu dois travailler. Le PDF complet reste disponible en cas de besoin : " + String(p.copyPath || ""))
  } else {
    lines.push("Copie à corriger (PDF) : " + String(p.copyPath || ""))
  }
  if (writingMode === "manuscrit") {
    lines.push("Copie manuscrite : si un mot est illisible ou ambigu, NE DEVINE PAS silencieusement — recopie ce que tu crois lire dans le champ REPONSE et dis-le dans le champ DOUTE de l'item concerné.")
  }
  lines.push("")

  if (p.niveauClasse) {
    lines.push("## Contexte")
    lines.push("Niveau de classe : " + String(p.niveauClasse) + ".")
    lines.push("")
  }

  lines.push("## Fichiers de référence")
  lines.push("- Sujet (PDF) : " + String(p.sujetPath || "") + " — lis-le pour savoir ce qui a été demandé et dans quel ordre.")
  if (p.corrigePath) lines.push("- Corrigé (PDF) : " + String(p.corrigePath))
  lines.push("La grille de correction ne t'est pas donnée sous forme de fichier : ses items sont recopiés tels quels plus bas. N'essaie pas de l'ouvrir.")
  lines.push("")

  var consignes = String(p.consignes || "").trim()
  lines.push("## Consignes de correction de l'enseignant — elles priment sur ton propre jugement")
  if (consignes) {
    lines.push(consignes)
  } else {
    lines.push("(Aucune consigne particulière n'a été écrite pour cette évaluation. Applique la lecture la plus simple de la grille : la case la plus à droite quand la réponse de l'élève est juste et complète, la plus à gauche quand elle est fausse ou absente, une case intermédiaire quand elle n'est juste qu'en partie.)")
  }
  lines.push("")

  // La convention de l'italique n'est rappelée que si la grille en porte
  // vraiment : sinon c'est une règle sans objet, qui invite l'agent à
  // chercher des marques inexistantes.
  var hasItalic = rows.some(function(r) { return String(r.text || "").indexOf("_") !== -1 })
  if (hasItalic) {
    lines.push("## Convention d'écriture de la grille — règle impérative")
    lines.push("Dans les réponses attendues ci-dessous, un passage encadré par des tirets bas, comme _ceci_, est un ÉLÉMENT COMPLÉMENTAIRE : une précision que l'enseignant note pour lui-même, pas une exigence.")
    lines.push("Un élément complémentaire ne doit JAMAIS peser dans ton choix de case : ne baisse pas d'une case parce que l'élève ne l'a pas donné, et ne baisse pas non plus s'il l'a donné de travers. Raisonne exactement comme si ce passage n'était pas écrit. Tout le reste de la ligne, lui, est exigible.")
    lines.push("Exemple : réponse attendue « épithète _détaché_ de limpidité » — un élève qui écrit « épithète de limpidité » a donné la réponse complète ; un élève qui écrit « épithète liée de limpidité » aussi.")
    lines.push("")
  }

  lines.push("## Comment retrouver chaque item sur la copie — règle impérative")
  lines.push("N'apparie JAMAIS les réponses par position : la n-ième réponse de la copie n'est pas forcément l'item n° n. Un élève saute des questions, en traite une deux fois, ou répond dans le désordre, et il n'a aucune raison de signaler l'un ou l'autre.")
  lines.push("Pour chaque item de la grille, cherche sur la copie la réponse qui porte sur CE constituant, ou CETTE question, en te servant du mot/groupe cité en tête de l'item et du sujet. Si tu ne trouves rien qui y corresponde, l'item n'a pas été traité.")
  lines.push("Un item non traité prend la case la plus à gauche (" + String(cols[0] || "") + ") — ce n'est pas la même chose qu'une erreur, alors dis-le dans DOUTE : « non traité ».")
  lines.push("Si l'élève a répondu DEUX FOIS au même item, prends la réponse la plus complète et signale le doublon dans DOUTE.")
  lines.push("")

  lines.push("## Les cases, de gauche à droite")
  for (var c = 0; c < cols.length; c++) lines.push("- " + String(cols[c]))
  lines.push("")

  lines.push("## Les " + rows.length + " items et leur réponse attendue")
  for (var i = 0; i < rows.length; i++) {
    lines.push((i + 1) + ". " + String(rows[i].text || ""))
  }
  lines.push("")

  var addendum = String(p.addendum || "").trim()
  if (addendum) {
    lines.push("## Complément de l'enseignant, spécifique à CETTE copie")
    lines.push("Ajouté après une première correction de cette copie précise. Prends-le en compte EN PRIORITÉ :")
    lines.push(addendum)
    lines.push("")
  }

  lines.push("## Format de réponse strict — réponds UNIQUEMENT avec ce format, rien avant, rien après")
  lines.push("D'abord une section de points de vigilance portant sur la copie dans son ensemble (qualité du scan, pages manquantes, écriture globalement difficile…) — PAS les arbitrages item par item, qui vont dans les champs DOUTE :")
  lines.push("")
  lines.push("## Points de vigilance")
  lines.push("- <un point par ligne, commençant par \"- \", une phrase maximum>")
  lines.push("(ou, si rien à signaler : écris exactement RAS)")
  lines.push("")
  lines.push("Puis un bloc de 4 lignes PAR ITEM, dans l'ordre des numéros, de 1 à " + rows.length + ", séparés par une ligne vide. Aucun item ne doit manquer, même non traité par l'élève :")
  lines.push("")
  lines.push("ITEM: <numéro de l'item, de 1 à " + rows.length + ">")
  lines.push("REPONSE: <ce que l'élève a écrit pour cet item, recopié aussi fidèlement que possible — ou RIEN s'il n'a pas traité l'item>")
  lines.push("CASE: <" + cols.join(" | ") + ">")
  lines.push("DOUTE: <vide si le cas est net ; sinon UNE phrase disant ce que tu as tranché et pourquoi>")
  lines.push("")

  lines.push("## Quand remplir DOUTE — c'est la partie la plus utile de ton travail")
  lines.push("Laisse DOUTE vide quand la réponse est franchement juste ou franchement fausse : l'enseignant n'a alors rien à vérifier, et un commentaire inutile lui coûte du temps de lecture.")
  lines.push("Remplis-le en revanche à chaque fois que ton choix de case pourrait raisonnablement être un autre, notamment :")
  lines.push("- réponse juste mais incomplète, ou plus vague que la réponse attendue ;")
  lines.push("- réponse qui dit la même chose en d'autres termes, et que tu as acceptée ;")
  lines.push("- élève qui ajoute une information fausse en plus d'une réponse juste ;")
  lines.push("- item non traité, ou traité deux fois ;")
  lines.push("- mot que tu n'es pas certain d'avoir bien déchiffré.")
  lines.push("Ne te sers jamais de DOUTE pour justifier une réponse évidente, ni pour résumer la règle de grammaire en jeu.")
  lines.push("")

  lines.push("## Consignes techniques")
  lines.push("- Ne lis aucun fichier en dehors de ceux listés ci-dessus (sujet, corrigé s'il est fourni, copie de l'élève et ses demi-pages).")
  lines.push("- N'écris aucun fichier. Réponds uniquement sur la sortie standard, dans le format ci-dessus.")
  lines.push("- Ne pose aucune question : personne ne peut te répondre dans l'immédiat. Tranche, et dis dans DOUTE ce que tu as tranché.")
  return lines.join("\n")
}

// ---- lecture de la réponse ----------------------------------------------

function stripAccents(s) {
  var map = {
    "à": "a", "â": "a", "ä": "a", "á": "a", "é": "e", "è": "e", "ê": "e", "ë": "e",
    "î": "i", "ï": "i", "í": "i", "ô": "o", "ö": "o", "ó": "o",
    "ù": "u", "û": "u", "ü": "u", "ú": "u", "ç": "c", "ñ": "n"
  }
  var out = ""
  var t = String(s || "").toLowerCase()
  for (var i = 0; i < t.length; i++) out += (map[t.charAt(i)] !== undefined ? map[t.charAt(i)] : t.charAt(i))
  return out
}

function normalizeColumn(s) {
  return stripAccents(s).replace(/[^a-z0-9]/g, "")
}

// Retrouve l'index de colonne annoncé par l'agent. Tolérant par principe
// (même posture que CorrectionPromptBuilder.parseGrades) : on accepte le
// nom exact, le nom sans accents/ponctuation, un préfixe non ambigu, et
// le numéro de colonne. Rien de reconnaissable → -1, l'item reste non
// coché plutôt que coché au hasard.
function matchColumn(value, columns) {
  var cols = Array.isArray(columns) ? columns : []
  var v = normalizeColumn(value)
  if (!v) return -1
  for (var i = 0; i < cols.length; i++) if (normalizeColumn(cols[i]) === v) return i
  var hits = []
  for (var j = 0; j < cols.length; j++) {
    var n = normalizeColumn(cols[j])
    if (n && (n.indexOf(v) === 0 || v.indexOf(n) === 0)) hits.push(j)
  }
  if (hits.length === 1) return hits[0]
  var asNumber = String(value || "").trim().match(/^([1-9])\b/)
  if (asNumber) {
    var idx = Number(asNumber[1]) - 1
    if (idx >= 0 && idx < cols.length) return idx
  }
  return -1
}

// Retourne { log, checks, answers, doubts, missing } — checks/answers/
// doubts indexés par la position de l'item dans `rows` (0-based), sous
// forme de clés chaîne, comme CorrectionsStore les stocke. `missing` est
// la liste des numéros d'items (1-based) que l'agent n'a pas rendus :
// Panel.qml s'en sert pour forcer la relecture plutôt que de laisser
// passer une grille trouée en silence.
function parseFilled(text, rows, columns) {
  var t = String(text || "")
  var list = Array.isArray(rows) ? rows : []
  var logMatch = t.match(/##\s*Points de vigilance\s*\n([\s\S]*?)(?=\n##|\nITEM:|$)/i)
  var log = logMatch ? logMatch[1].trim() : ""

  var checks = {}
  var answers = {}
  var doubts = {}
  var seen = {}
  var blocks = t.split(/\n(?=ITEM:)/)
  for (var b = 0; b < blocks.length; b++) {
    var block = blocks[b]
    var itemM = block.match(/ITEM:\s*#?\s*(\d+)/)
    if (!itemM) continue
    var idx = Number(itemM[1]) - 1
    if (!(idx >= 0 && idx < list.length)) continue
    if (seen[idx]) continue
    seen[idx] = true

    var caseM = block.match(/(?:CASE|VERDICT)\s*:\s*([^\n\r]*)/i)
    var col = caseM ? matchColumn(caseM[1], columns) : -1
    if (col !== -1) checks[String(idx)] = col

    var repM = block.match(/REPONSE\s*:\s*([\s\S]*?)(?=\n\s*(?:CASE|VERDICT|DOUTE)\s*:|\nITEM:|$)/i)
    if (repM) {
      var rep = repM[1].trim()
      if (rep && normalizeColumn(rep) !== "rien") answers[String(idx)] = rep
    }

    var doubtM = block.match(/DOUTE\s*:\s*([\s\S]*?)(?=\nITEM:|$)/i)
    if (doubtM) {
      var d = doubtM[1].trim()
      var dn = normalizeColumn(d)
      if (d && dn !== "" && dn !== "ras" && dn !== "aucun" && dn !== "aucune" && dn !== "na") doubts[String(idx)] = d
    }
  }

  var missing = []
  for (var i = 0; i < list.length; i++) if (checks[String(i)] === undefined) missing.push(i + 1)
  return { log: log, checks: checks, answers: answers, doubts: doubts, missing: missing }
}

if (typeof module !== "undefined") {
  module.exports = {
    buildFillPrompt: buildFillPrompt,
    matchColumn: matchColumn,
    parseFilled: parseFilled
  }
}

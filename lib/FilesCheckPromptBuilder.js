// Prompt for the optional pre-launch file-consistency check (Gabriel,
// 2026-09-17): before creating an évaluation, read sujet/corrigé/consignes/
// agent together and report anything unclear or contradictory, so he can
// fix it before spending real correction runs against it. Read-only by
// design — see ClaudeRunner.buildCheckCommand, which grants Read access
// without the broader --dangerously-skip-permissions the correction agent
// itself needs (that one also writes files; this one never does).

.pragma library

function build(params) {
  var p = params || {}
  var lines = []

  lines.push("Tu es un relecteur pédagogique, invoqué pour vérifier la cohérence et la clarté des documents d'une évaluation avant qu'elle ne soit lancée — pas pour corriger une copie.")
  lines.push("")
  lines.push("## Fichiers à relire")
  lines.push("- Sujet (PDF) : " + String(p.sujetPath || ""))
  if (p.corrigePath) {
    lines.push("- Corrigé (PDF) : " + String(p.corrigePath))
  } else {
    lines.push("- Corrigé : aucun fourni pour cette évaluation.")
  }
  lines.push("- Consignes de correction (markdown) : " + String(p.consignesPath || ""))
  lines.push("- Instructions pour l'agent de correction (markdown) : " + String(p.agentPath || ""))
  lines.push("")
  lines.push("## Ce que tu dois vérifier")
  lines.push("1. Les consignes sont-elles claires et applicables telles quelles par un correcteur qui découvre ce devoir ?")
  lines.push("2. Les consignes sont-elles cohérentes avec ce que le sujet demande réellement (et avec le corrigé, s'il est fourni) ?")
  lines.push("3. Les consignes et les instructions de l'agent se contredisent-elles sur un point quelconque (ton, barème, format attendu) ?")
  lines.push("4. Manque-t-il une précision qui rendrait la correction ambiguë (ex. un critère flou, un barème évoqué mais jamais détaillé) ?")
  lines.push("")
  lines.push("Précision importante : l'agent de correction propose TOUJOURS trois notes indicatives sur 20 (sévère/neutre/bienveillante) pour chaque copie, quelle que soit l'évaluation — y compris quand ce travail n'est pas formellement noté pour l'élève. Ce n'est pas une incohérence à signaler : ne remonte jamais le fait que ces notes existent comme contredisant des consignes disant que le travail n'est \"pas noté\" ou similaire.")
  lines.push("")
  lines.push("## Ce que tu dois produire")
  lines.push("Réponds UNIQUEMENT sur la sortie standard (aucun fichier à créer ou modifier). Si tout est clair et cohérent : réponds exactement le mot RAS, rien d'autre. Sinon, une liste concise de points concrets à clarifier, un point par ligne, chaque ligne commençant par \"- \". Reste bref — quelques lignes maximum, pas une dissertation.")

  return lines.join("\n")
}

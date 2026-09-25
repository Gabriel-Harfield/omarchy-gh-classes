// Headless Claude invocation for the appreciation generator. Unlike GH
// Slide/GH Typst, this call never needs Claude to read or write any file
// — it only ever returns generated text on stdout — so there's no tool
// use involved and no permission-bypass flag needed here.

.pragma library

function buildCommand(promptText) {
  return ["claude", "-p", promptText]
}

// Headless Claude invocation for the Corrections agent, which DOES need
// file access: it reads the sujet/corrigé/consignes/agent files and the
// student's copy PDF, and writes its appreciation + log back out. Same
// convention as GH Slide's own ClaudeRunner.js (this author's plugin
// family): the skip-permissions flag makes the run silent, and
// CorrectionPromptBuilder.js is what scopes what it's allowed to touch by
// naming every path explicitly in the prompt.
function buildFileCommand(promptText) {
  return ["claude", "-p", String(promptText), "--dangerously-skip-permissions"]
}

// Headless Claude invocation for the pre-launch file-consistency check
// (Gabriel, 2026-09-17): needs to read sujet/corrigé/consignes/agent (PDFs
// included) but never writes anything and must stay silent — unlike
// buildFileCommand above, this uses --allowedTools instead of the broader
// --dangerously-skip-permissions: it auto-approves Read calls without a
// prompt, but grants nothing else (no Bash, Write, WebFetch/WebSearch),
// since this run has no legitimate need for any of them.
function buildCheckCommand(promptText) {
  return ["claude", "-p", String(promptText), "--allowedTools", "Read"]
}

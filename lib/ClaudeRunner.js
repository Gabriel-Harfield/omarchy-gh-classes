// Headless Claude invocation for the appreciation generator. Unlike GH
// Slide/GH Typst, this call never needs Claude to read or write any file
// — it only ever returns generated text on stdout — so there's no tool
// use involved and no permission-bypass flag needed here.

.pragma library

// Optional `opts` on every builder below (Gabriel, 2026-10-15): { model, effort }
// — the model alias ("sonnet", "opus"…) and effort level the correction
// run should use, picked per évaluation in the Corrections tab. Empty/absent
// = no flag, i.e. whatever the user's own Claude configuration defaults to.
function withOptions(cmd, opts) {
  var o = opts || {}
  if (o.model) { cmd.push("--model"); cmd.push(String(o.model)) }
  if (o.effort) { cmd.push("--effort"); cmd.push(String(o.effort)) }
  return cmd
}

function buildCommand(promptText, opts) {
  return withOptions(["claude", "-p", promptText], opts)
}

// Headless Claude invocation for the Corrections agent, which DOES need
// file access: it reads the sujet/corrigé/consignes/agent files and the
// student's copy PDF, and writes its appreciation + log back out. Same
// convention as GH Slide's own ClaudeRunner.js (this author's plugin
// family): the skip-permissions flag makes the run silent, and
// CorrectionPromptBuilder.js is what scopes what it's allowed to touch by
// naming every path explicitly in the prompt.
function buildFileCommand(promptText, opts) {
  return withOptions(["claude", "-p", String(promptText), "--dangerously-skip-permissions"], opts)
}

// Headless Claude invocation for the pre-launch file-consistency check
// (Gabriel, 2026-09-17): needs to read sujet/corrigé/consignes/agent (PDFs
// included) but never writes anything and must stay silent — unlike
// buildFileCommand above, this uses --allowedTools instead of the broader
// --dangerously-skip-permissions: it auto-approves Read calls without a
// prompt, but grants nothing else (no Bash, Write, WebFetch/WebSearch),
// since this run has no legitimate need for any of them.
function buildCheckCommand(promptText, opts) {
  return withOptions(["claude", "-p", String(promptText), "--allowedTools", "Read"], opts)
}

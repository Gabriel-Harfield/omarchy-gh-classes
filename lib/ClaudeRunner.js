// Headless Claude invocation for the appreciation generator. Unlike GH
// Slide/GH Typst, this call never needs Claude to read or write any file
// — it only ever returns generated text on stdout — so there's no tool
// use involved and no permission-bypass flag needed here.

.pragma library

function buildCommand(promptText) {
  return ["claude", "-p", promptText]
}

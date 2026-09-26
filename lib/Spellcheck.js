// Local, offline spellcheck (hunspell, no Claude, no network) for the
// "Appréciation" text area in the Eval. Compétences tab. Ported from GH
// Typst's lib/Spellcheck.js (see that file's own header for the full
// design rationale — the two-phase split below, and why positions/dedup
// come from our own tokenize() pass rather than hunspell's own offset
// reporting). This tab's text is a short paragraph, not a whole document,
// so none of GH Typst's large-document tuning matters here — same
// two-phase shape kept only because it's the correct, already-debugged
// shape, not because performance demands it.
//   1. Detection (run on every text change — cheap even unthrottled at
//      this text length): tokenize ourselves, dedupe, hunspell -l (list
//      misspelled words, no suggestions) on just the unique words.
//   2. Suggestions (on demand, one word at a time, when a flagged word is
//      clicked): hunspell -a on that single word.

.pragma library

var WORD_CHAR_CLASS = "A-Za-zÀ-ÖØ-öø-ÿ'’-"
var WORD_RE = new RegExp("[" + WORD_CHAR_CLASS + "]+", "g")

// Tokenizes text into {word, start, end} for every word-like run — French
// letters (incl. accents), apostrophe, hyphen. Punctuation, digits never
// end up inside a token.
function tokenize(text) {
  var out = []
  var m
  WORD_RE.lastIndex = 0
  while ((m = WORD_RE.exec(text)) !== null) {
    out.push({ word: m[0], start: m.index, end: m.index + m[0].length })
  }
  return out
}

function buildDiscoverCommand() {
  return ["hunspell", "-D"]
}

function _basename(p) {
  var idx = p.lastIndexOf("/")
  return idx === -1 ? p : p.slice(idx + 1)
}

// See GH Typst's Spellcheck.js for the full reasoning behind this parse —
// confirmed live against real `hunspell -D` output, not a guess: each
// candidate is a full path, a trailing "DICTIONNAIRES CHARGÉS" section
// lists actual .aff/.dic files (excluded, not valid -d values).
function parseDiscoverOutput(text) {
  var lines = String(text || "").split("\n")
  var candidates = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (line.indexOf(":") !== -1) continue
    if (/\.(aff|dic)$/i.test(line)) continue
    candidates.push(line)
  }
  var frExact = candidates.filter(function(c) { return /^fr[_-]fr$/i.test(_basename(c)) })
  if (frExact.length > 0) return frExact[0]
  var frAny = candidates.filter(function(c) { return /^fr/i.test(_basename(c)) })
  if (frAny.length > 0) return frAny[0]
  return ""
}

function buildDetectCommand(dictName) {
  return ["hunspell", "-l", "-d", dictName]
}

function buildDetectInput(uniqueWords) {
  return uniqueWords.join("\n") + "\n"
}

function parseDetectOutput(rawOutput) {
  var set = {}
  var lines = String(rawOutput || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var w = lines[i]
    if (w !== "") set[w] = true
  }
  return set
}

function uniqueWords(tokens) {
  var seen = {}
  var out = []
  for (var i = 0; i < tokens.length; i++) {
    var w = tokens[i].word
    if (!seen[w]) { seen[w] = true; out.push(w) }
  }
  return out
}

function buildSuggestCommand(dictName) {
  return ["hunspell", "-a", "-d", dictName]
}

function buildSuggestInput(word) {
  return "^" + word + "\n"
}

function parseSuggestOutput(rawOutput) {
  var lines = String(rawOutput || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.charAt(0) === "&") {
      var m = line.match(/^&\s+\S+\s+\d+\s+\d+:\s*(.*)$/)
      if (m) return m[1].length > 0 ? m[1].split(", ") : []
    } else if (line.charAt(0) === "#") {
      return []
    }
  }
  return []
}

# GH Classes — BETA

A classroom-management tool for a teacher: one tab per class, weighted
random student draw, automatic group generation (with "these students
can't be together" constraints), and an AI appreciation generator.

Personal tool, part of this author's unpublished `GH*` teaching-tools
family (see [GH Typst](https://github.com/Gabriel-Harfield/omarchy-gh-typst),
[GH Hub](https://github.com/Gabriel-Harfield/omarchy-gh-hub),
[GH Grilles](https://github.com/Gabriel-Harfield/omarchy-gh-grilles)). No
bar icon — summon it via [OmApp](https://github.com/Gabriel-Harfield/omarchy-omapp) or:

```sh
omarchy-shell shell summon io.github.gabrielharfield.ghclasses
```

**This is an early BETA — a first pass, not fully hardened.** The core
logic (roster parsing, the weighted draw, group generation, prompt
building) has been tested standalone; the interactive class-creation
flow (name + roster file path → new tab) has not yet been click-tested
end to end. Try that one first.

## What it does today

- **Classes** — Paramètres → "Créer une nouvelle classe": give it a name
  and the path to a `.md` file listing your students, one per line,
  always `NOM Prénom` (surname first, in capitals). Each class gets its
  own tab.
- **🎲 Tirage au sort** — draws 3 students, ranked 1/2/3. A student drawn
  often becomes progressively less likely to be drawn again (weight =
  `1 / (1 + nombre de tirages)`), never impossible, just rarer. "📊
  Statistiques" exports a `.csv` with each student's draw count and
  dates.
- **👥 Groupes** — pick a number of groups, optionally mark students who
  must never be grouped together ("⚠ Élèves incompatibles"), then "🔀
  Générer les groupes". Best-effort constraint solving (shuffle + repair
  swaps) — a warning shows if some constraints can't all be satisfied at
  once for the chosen group count.
- **✍ Appréciations** — a minimal AI generator (Copie: méthode / contenu
  / expression, or Bulletin: travail / comportement / axe de
  progression), a max-length dropdown, "🪄 Générer l'appréciation" runs a
  one-shot headless `claude -p` call and shows the result with a copy
  button.
- **📋 Eval. Compétences** — pick a student, a grille type ("Commentaire
  EAF", the official state grid for the real bac correction, "Commentaire
  de texte", Gabriel's own reworded/more precise version for day-to-day
  grading, or "Introduction" for group-written introductions — more to
  come), and type the assignment's own "Intitulé de l'évaluation"
  (shared by every student evaluated on that grille/classe, not retyped
  per student). Tick one mastery level per criterion (Non maîtrisé /
  Insuffisamment maîtrisé / En cours de maîtrise / Maîtrisé — narrow fixed-
  width level columns, headers wrap/hyphenate; "Critères" takes whatever
  width is left and follows the window), plus a scrollable "Appréciation"
  text area and a "Note / 20" field, both saved per student/grille (auto-
  saved shortly after you stop typing). "🎯 Proposer une note" runs a
  one-shot headless `claude -p` call that reads the ticked levels and the
  written appréciation against a fixed barème (Maîtrisé 18-20 / En cours de
  maîtrise 12-17 / Insuffisamment maîtrisé 7-11 / Non maîtrisé 1-6) and
  shows a suggested grade in parentheses next to the field — never
  auto-filled, never exported, purely an in-app hint. "🧠 Générer une
  appréciation" (same headless-`claude -p` mechanism) writes a full
  appréciation straight into the Appréciation field from the ticked grid
  alone, following fixed house rules: vouvoiement, never discouraging, and
  always méthode → contenu → expression in that order — overwrites
  whatever was already typed there, same as regenerating on the other tab.
  Either
  "📋 Copier le code Typst" or "📄 Exporter en PDF" (via `typst compile`)
  produces a standalone document: the intitulé as a header, the student's
  name, the grille name, the filled-in grid, appréciation and note, and a
  running footer ("_M.Harfield - <classe> - <année scolaire>_", the school
  year computed from today's date). Grille templates are hardcoded in
  `lib/CompetencyGrids.js`, not user-editable in the app yet. The
  appréciation field has local, offline spellcheck (hunspell, ported from
  GH Typst's own — no network, no Claude): misspelled words show as
  clickable chips below the text area, each opening a suggestion menu that
  replaces every occurrence of that word. Nothing here is ever cleared
  automatically — a student's table/appréciation/note for a given grille
  stays until you explicitly clear it with "🗑 Réinitialiser cet élève" or
  "🗑 Réinitialiser la classe" (next to the export buttons, both behind a
  confirmation, both scoped to the currently selected grille type only —
  by design, so you can revisit and harmonize past copies at any time).
- **📚 Exercices** — placeholder for now; deferred until the exercise
  database itself exists.

## Install

```sh
omarchy plugin add https://github.com/Gabriel-Harfield/omarchy-gh-classes.git --enable
```

## License

MIT

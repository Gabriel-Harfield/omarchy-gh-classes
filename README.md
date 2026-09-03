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
- **📚 Exercices** — placeholder for now; deferred until the exercise
  database itself exists.

## Install

```sh
omarchy plugin add https://github.com/Gabriel-Harfield/omarchy-gh-classes.git --enable
```

## License

MIT

# À faire : fusionner la grille « Plan, introduction et paragraphe »

Branche `grille-combinee` (ajoutée le 2026-10-16 depuis une autre machine).
Importante pour la correction des vacances : ne pas l'oublier.

## Ce que la branche change (petit, très localisé)
- `lib/CompetencyGrids.js` : nouvelle grille `plan-introduction-et-paragraphe`
  (« Plan, introduction et paragraphe »), qui enchaîne Plan détaillé guidé,
  Introduction et Paragraphe argumenté ; titres des 3 étapes en MAJUSCULES ;
  titres « Aptitude… » du paragraphe argumenté en *italique* (propriété `italic`
  sur les lignes, gérée dans l'export Typst/Markdown).
- `ui/CompetencyGridPopover.qml` : 2 lignes `font.italic`.
- Mise à jour 2026-10-17 : l'introduction n'a plus le critère orthographe/syntaxe ;
  nouveau titre « EXPRESSION ÉCRITE ET MISE EN PAGE » (mise en page + items langue,
  en remplacement de « Maîtrise de la langue… ») ; « Mon paragraphe » au singulier.
  Les numéros de ligne de CETTE grille ont donc changé par rapport au premier
  commit ; les pondérations (competencyWeights) de la grille
  `plan-introduction-et-paragraphe` ont été migrées dans classes.json (Dropbox).
  Si Ostrog a de son côté des coches/poids enregistrés pour cette grille avant la
  fusion, ils seraient décalés : prévenir Gabriel.

## Instructions pour l'agent (autre machine)
1. Vérifier que le travail en cours (onglet Corrections) est commité ; sinon
   demander à Gabriel avant toute chose. Ne rien écraser.
2. `git fetch origin && git merge origin/grille-combinee`
3. Conflits possibles uniquement si `CompetencyGrids.js` ou
   `CompetencyGridPopover.qml` ont été modifiés ici : garder les DEUX
   changements (ne pas supprimer la grille combinée ni la propriété `italic`).
4. Redémarrer le shell, ouvrir Eval. Compétences → la grille doit apparaître.
5. Supprimer ce fichier une fois la fusion faite.

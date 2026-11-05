// Prompt de LECTURE d'une feuille de QCM scannée (une page = une copie).
// L'agent ne juge rien : il dit quelle case est cochée dans chaque question,
// quelle version est imprimée et quel nom est écrit. La note est calculée par
// QcmStore.scoreCopy. Un seul fichier image lu par appel (outil Read seul).

.pragma library

function buildReadPrompt(imagePath, nQuestions, nOptions) {
  return [
    "Tu lis une feuille de QCM scannée (une page, image : " + imagePath + ").",
    "Lis ce fichier avec l'outil Read, puis réponds par UN SEUL objet JSON, sans aucun autre texte.",
    "",
    "Mise en page de la feuille :",
    "- En haut : le titre, « Version N » en haut à droite (N est un nombre imprimé), « Nom, prénom : » suivi du nom écrit à la main, « Classe : » et « Date : ».",
    "- Dessous, " + nQuestions + " questions numérotées 1 à " + nQuestions + ", sur deux colonnes (la colonne de gauche d'abord, puis celle de droite).",
    "- Chaque question a " + nOptions + " propositions, une par ligne, chacune précédée d'une petite case carrée à cocher.",
    "",
    "Pour chaque question, indique la POSITION de la case cochée parmi les propositions de cette question (1 = la proposition tout en haut, " + nOptions + " = la dernière).",
    "- Une case est cochée si elle contient une croix, un trait, un pointage ou est noircie.",
    "- Si l'élève a rayé ou effacé une première coche et en a fait une autre, retiens la dernière et explique-le dans « remarque ».",
    "- Si aucune case n'est cochée, ou si deux cases restent cochées sans que tu puisses trancher, mets \"case\": null et explique-le dans « remarque ».",
    "- Ne regarde jamais le texte des propositions pour deviner la bonne réponse : tu ne corriges pas, tu LIS seulement les cases.",
    "- Si tu hésites sur une lecture (coche faible, ratures), mets-le dans « remarque » en une courte phrase.",
    "",
    "Lis aussi le numéro de version imprimé (« version » : nombre, ou null si illisible) et le nom écrit à la main (« nom » et « prenom » tels que tu les lis ; chaîne vide si illisible).",
    "",
    "Format exact de ta réponse :",
    "{\"version\": 12, \"nom\": \"DUPONT\", \"prenom\": \"Marie\", \"reponses\": [{\"q\": 1, \"case\": 3, \"remarque\": \"\"}, {\"q\": 2, \"case\": null, \"remarque\": \"deux croix\"}]}",
    "Il doit y avoir exactement " + nQuestions + " entrées dans « reponses », une par question, dans l'ordre."
  ].join("\n")
}

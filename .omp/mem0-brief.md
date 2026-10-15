<!-- mem0:brief v5 -->
# Brief mémoire — règles complètes

Généré par le plugin `omp-mem0-memory`. Tu peux éditer ce fichier : il ne sera pas
réécrit tant que le marqueur de version en tête reste `v5`.

## Quand chercher

Le rappel automatique de début de tour est construit à partir de ta demande. Il rate
ce qui est formulé autrement. `mem0_search` dès que le sujet bouge : avant de
débugger un symptôme qui ressemble à du déjà-vu, avant de trancher une question
d'architecture, avant de choisir une convention, avant de répondre à "comment on
fait ici". Une recherche coûte moins qu'une lecture de dépôt.

## Ce qui mérite d'être mémorisé

- **Stack et choix techniques** — langage, framework, versions imposées, gestionnaire
  de paquets, outil de test, linter, cible de déploiement. Tout ce que tu as dû
  chercher dans le dépôt pour pouvoir travailler, et que tu chercherais encore la
  prochaine fois.
- **Décisions d'architecture** — le choix retenu *et* la raison. Une décision sans sa
  raison sera rouverte dans deux mois.
- **Conventions** — nommage, structure de dossiers, patterns imposés, ce qui est
  interdit dans ce dépôt. Surtout celles qui ne sont écrites nulle part.
- **Bugs résolus** — symptôme, cause racine, correctif. C'est la catégorie qui
  rapporte le plus : un bug qui se reproduit coûte beaucoup plus cher qu'un bug
  inédit.
- **Exigences incontournables d'une feature** — les contraintes qui doivent tenir à
  chaque itération : compatibilité descendante, limite de performance, règle métier
  non négociable, exigence d'accessibilité ou de sécurité.
- **Préférences de travail** — comment l'utilisateur veut que tu procèdes sur ce
  projet. Avec `scope: "global"` si c'est vrai pour tous ses projets.

## Ce qu'il ne faut pas mémoriser

L'état courant du code (il change, et le dépôt fait autorité), ce qui est déjà dans
`AGENTS.md` ou le README, un raisonnement intermédiaire, une tâche en cours, un
résultat de test, du bavardage. Et jamais de secret, clé, token ou donnée
personnelle — la rédaction automatique existe mais elle est approximative.

## Comment écrire un souvenir

Une idée par appel, autoportante : quelqu'un doit pouvoir la comprendre dans six mois
sans le contexte de cette conversation. Nomme les fichiers, modules et symboles.

Ton texte est stocké **tel quel** : `mem0_add` n'appelle pas d'extraction LLM par
défaut. Écris donc la phrase finale, pas une note à retravailler.

- OUI — `Tests : XCTest, un fichier par type, fixtures dans Tests/Support. Pas de mocks manuels, on passe par des protocoles + implémentations de test.`
- OUI — `Bug écran de séance figé : cause = Timer non invalidé au dismiss de la vue. Fix = .onDisappear { timer.invalidate() }. Vérifier ce pattern sur toute vue à timer.`
- NON — `On a corrigé le bug du timer.` (ni symptôme, ni cause, ni fix)
- NON — `TabataEngine.swift fait 340 lignes.` (périmé au prochain commit)
- NON — `L'équipe travaille sur une architecture single-app.` (vague, non actionnable, et déjà dit ailleurs)

Une méthode réutilisable en plusieurs étapes (déployer, débugger une catégorie
d'erreur, checklist avant release) → `mem0_add` avec `kind: "procedure"` : le texte est conservé tel quel,
sans réécriture ni fusion.

## Déduplication

`mem0_add` cherche d'abord un souvenir proche dans le même scope. Trois issues :

- **rien de proche** → nouvelle entrée ;
- **le souvenir existant dit déjà ce que tu apportes** → rien n'est écrit, l'entrée
  existante t'est renvoyée ;
- **ton texte complète ou remplace l'existant** → l'entrée est *mise à jour* et la
  version fusionnée t'est renvoyée.

Relis toujours la fusion renvoyée. Si elle est bancale (deux faits distincts collés,
information perdue), réécris l'entrée avec `mem0_update` — c'est prévu pour ça.
Passe `dedupe: false` seulement quand tu sais que le fait doit vivre séparément.

## Quand un souvenir est faux

Le dépôt gagne toujours. Si un souvenir contredit le code réel, il est périmé :
réécris-le avec `mem0_update`, ou supprime-le avec `mem0_forget` s'il est
simplement faux.

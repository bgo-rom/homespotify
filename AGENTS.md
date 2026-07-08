# AGENTS.md — Règles pour toutes les IA du projet HomeSpotify

S'applique à Claude Code, aux sous-agents et à toute autre IA intervenant sur ce dépôt. En cas de conflit, `CLAUDE.md` prime.

## Comportement attendu

- Lire `CLAUDE.md` puis les fichiers listés dans son ordre de lecture avant d'agir.
- Trancher, justifier brièvement, ne pas inventer.
- Signaler explicitement toute incertitude dans une section `À vérifier` plutôt que d'affirmer.
- Respecter le périmètre : ne toucher qu'aux fichiers du projet.

## Gestion des sous-agents

- Un sous-agent = une mission unique, bornée, avec livrable défini.
- Le prompt d'un sous-agent doit être autonome (chemins de fichiers, contexte, critère de fin).
- L'agent principal continue son travail pendant qu'un sous-agent tourne ; il n'intervient que si le sous-agent dévie.
- Les résultats d'un sous-agent sont vérifiés avant intégration — jamais copiés aveuglément.
- Pas de sous-agent pour une tâche faisable directement en moins d'étapes.

## Économie de tokens

- Ne pas relire des fichiers déjà lus dans la session sauf s'ils ont changé.
- Lire des portions ciblées des gros fichiers, pas leur intégralité.
- Réponses sans préambule ni répétition de la question.
- Pas de génération de contenu non demandé.

## Style de code futur

(Applicable dès la Phase 1 de la roadmap — aucun code avant.)

- TypeScript strict (`strict: true`), pas de `any` non justifié.
- Fonctions courtes, noms explicites, pas de commentaires redondants avec le code.
- Erreurs gérées explicitement ; jamais de `catch` silencieux.
- Tests sur la logique métier critique : détection de qualité, scanner, streaming Range.
- Conventions du fichier voisin : le nouveau code ressemble au code existant.

## Sécurité

- Aucun secret en clair dans le code ou la doc ; variables d'environnement + `.env` gitignoré.
- Toute route API future : authentification obligatoire par défaut.
- Valider toutes les entrées externes (uploads, chemins de fichiers, tags de métadonnées — risque d'injection via tags).
- Jamais de chemin de fichier construit depuis une entrée utilisateur sans normalisation (path traversal).
- Aucun contournement DRM, aucune intégration de source illégale.

## Performance

- Le serveur tourne H24 sur une machine personnelle : sobriété CPU/RAM exigée.
- Pas de traitement lourd au démarrage ; scanner et analyses en tâches de fond avec file d'attente.
- Réponses API paginées dès que la bibliothèque peut dépasser quelques centaines d'éléments.

## Gestion des gros fichiers audio

- Un FLAC fait 20–60 Mo, un album 300–800 Mo : **jamais** charger un fichier audio entier en mémoire.
- Lecture et envoi en flux (streams) uniquement ; support HTTP Range obligatoire.
- Hash de fichiers par flux (streaming hash), pas par lecture complète en RAM.
- Les fichiers audio ne transitent jamais par la base de données ; la DB ne stocke que chemins et métadonnées.
- Aucun fichier audio dans le dépôt git.

## Cohérence documentaire

- Toute modification qui contredit un fichier de fondation impose la mise à jour de ce fichier dans le même lot de travail.
- Les leçons apprises vont dans `LESSONS.md`, les décisions dans `TECH_DECISIONS.md` — pas d'information orpheline dans les messages de chat.
- Ne jamais supprimer d'information utile d'un document ; déplacer ou marquer obsolète si besoin.

## Interdiction d'inventer une qualité audio

- La qualité affichée d'un fichier provient **exclusivement** d'une analyse technique (ffprobe ou équivalent) : codec, fréquence d'échantillonnage, profondeur de bits, débit.
- Une extension `.flac` ou un tag ne prouve rien : un MP3 réencodé en FLAC reste du lossy.
- Sans analyse, la qualité est `inconnue` — jamais supposée.
- Interdiction de présenter à l'utilisateur final une piste comme « lossless » si la provenance ou l'analyse ne le confirme pas.

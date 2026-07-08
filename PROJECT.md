# PROJECT.md — HomeSpotify

## Vision

Application musicale personnelle type Spotify, 100 % auto-hébergée sur un serveur maison H24. Bibliothèque privée, streaming vers mobile, mode hors ligne, interface moderne — avec une priorité absolue : **la qualité audio réelle, vérifiée, jamais inventée**.

## Objectifs

1. Ajouter des musiques depuis une interface (upload / import).
2. Importer les fichiers dans la meilleure qualité réellement possible selon la source.
3. Stocker proprement les fichiers sur le serveur (arborescence normalisée, pas de doublons).
4. Gérer les métadonnées : artiste, album, titre, pochette, année, genre, **qualité audio mesurée**.
5. Streamer vers une application mobile (Wi-Fi local et accès distant sécurisé).
6. Mode hors ligne : cache local des pistes choisies sur le téléphone.
7. Interface moderne, fluide, stylée.
8. Base saine de production : tests, sauvegardes, logs, monitoring — pas un prototype jetable.

## Non-objectifs

- Pas de service multi-utilisateurs public ni de partage externe.
- Pas de recommandation algorithmique / IA de découverte (éventuel plus tard).
- Pas de contournement DRM, pas d'intégration de sources illégales.
- Pas de réimplémentation de Spotify Connect, paroles synchronisées, podcasts (hors périmètre initial).
- Pas de support d'un parc de serveurs : une seule machine cible.

## Contraintes

- Serveur personnel unique, allumé H24 : sobriété CPU/RAM/disque.
- Fichiers audio volumineux (FLAC 20–60 Mo/piste) : streaming par flux obligatoire, jamais de chargement complet en mémoire.
- Réseau domestique + accès distant : l'exposition à Internet doit être minimale et sécurisée.
- Utilisateur principal unique (usage personnel/familial).
- La qualité stockée en base = specs **mesurées** + statut dérivé de la **provenance déclarée**, jamais de l'extension.
- **Ingestion WAV-only** (décidé 2026-07-08) : seuls des WAV PCM 16 bit / 44,1–48 kHz sont importés ; l'optimisation est gérée manuellement en amont. Coût assumé : ~2× l'espace d'un FLAC équivalent.

## Priorités (ordre strict)

1. Qualité audio vérifiée et intégrité de la bibliothèque.
2. Fiabilité du streaming (Range, reprise, stabilité).
3. Simplicité d'exploitation (une personne maintient tout).
4. Expérience mobile fluide + hors ligne.
5. Esthétique de l'interface.

> Règle : simple avant beau. Une fonctionnalité stable et laide passe avant une fonctionnalité belle et fragile.

## MVP

- Import par upload de WAV possédés, avec extraction des métadonnées et qualité mesurée. ✅ (Phase 2)
- Base de données de la bibliothèque (pistes, qualité, provenance). ✅ (Phase 2)
- API de streaming avec HTTP Range. ✅ (Phase 2)
- Client minimal (web mobile-first) : parcourir la bibliothèque, lire une piste. 🚧 (lecteur dev `/player` livré ; vrai client en Phase 4)
- Scanner d'un dossier de musique existant (hors upload). ✅ (Phase 2, CLI `scan`)
- Téléchargement pour cache hors ligne mobile. ✅ (route `download` + `etag`/`lastModified`, Phase 3 amorcée)

## Version production

- Application mobile installable avec cache hors ligne synchronisé.
- Authentification, accès distant sécurisé (VPN d'abord).
- Enrichissement de métadonnées (MusicBrainz) et pochettes haute résolution.
- File d'import avec détection de doublons et rapport de qualité.
- Sauvegardes automatiques (DB + musique), logs structurés, monitoring avec alertes.
- Déploiement reproductible (Docker Compose).

## Limites légales et techniques

- **Légal** : seuls les fichiers possédés ou légalement téléchargeables sont importés. Les flux des services de streaming (Spotify, Deezer, YouTube…) sont protégés par DRM/CGU : leur extraction est exclue du projet. Détail dans `AUDIO_SOURCING.md`.
- **Technique** : une source compressée (YouTube, MP3) ne peut jamais redevenir lossless. Le projet affiche la qualité réelle, y compris quand elle est médiocre.
- **Réseau** : le débit montant de la connexion domestique borne la qualité de streaming à distance ; un transcodage à la volée (FLAC → Opus) est prévu pour ce cas.

## Critères de réussite

- 100 % des pistes en base ont une qualité mesurée (codec, échantillonnage, bits, débit) ou le statut `inconnue`.
- Aucune piste marquée lossless sans preuve d'analyse.
- Lecture instantanée (< 1 s) en local, reprise de lecture après coupure réseau.
- Une piste mise en cache se lit en mode avion.
- Le serveur tient 30 jours sans intervention manuelle.
- Restauration complète testée depuis une sauvegarde.

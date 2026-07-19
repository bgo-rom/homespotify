# MULTI_USER_DATA_MODEL.md — Modèle de données multi-utilisateur (cible)

> Statut : **document de conception** (2026-07-11). Décrit le modèle cible pour le passage
> de la bibliothèque au multi-utilisateur. Dans la phase actuelle, seules les tables
> `users`, `sessions` et `audit_logs` existent ; l'API renvoie `storageUsage: null`
> partout — aucune valeur n'est inventée tant que les relations ci-dessous n'existent pas.

## Principe fondateur

Un fichier audio physique existe **une seule fois** sur le disque (table `tracks`,
dédupliquée par hash SHA-256 — déjà en place). Plusieurs utilisateurs peuvent y avoir
accès. Ce qui devient « par utilisateur », ce sont des **relations logiques**, jamais des
copies de fichiers.

## Tables cibles

### `user_tracks` — accès d'un utilisateur à une piste

| Colonne | Type | Rôle |
|---|---|---|
| `user_id` | FK `users.id` | propriétaire logique de l'accès |
| `track_id` | FK `tracks.id` | piste physique partagée |
| `source` | text | comment l'accès est né : `acquisition`, `import`, `grant_owner`, `shared_library` |
| `created_at` | text ISO | date d'attribution |

Clé primaire composite (`user_id`, `track_id`). La suppression d'un compte supprime ses
lignes `user_tracks`, **jamais** le fichier physique ni la ligne `tracks` : une piste
sans plus aucun accès reste dans la bibliothèque (le OWNER décide séparément d'un
éventuel nettoyage — action explicite, pas automatique).

### `favorites` — favoris par utilisateur

| Colonne | Type |
|---|---|
| `user_id` | FK `users.id` |
| `track_id` | FK `tracks.id` |
| `created_at` | text ISO |

Clé primaire (`user_id`, `track_id`). Ce modèle est actif et constitue la source
de vérité ; l'ancien JSON mobile a été supprimé sans migration de données locales.

### `playlists` / `playlist_tracks`

| `playlists` | | `playlist_tracks` | |
|---|---|---|---|
| `id` (pk) | | `playlist_id` (FK) | |
| `user_id` (FK) | | `track_id` (FK) | |
| `name` | | `position` (int) | |
| `created_at`, `updated_at` | | `added_at` | |

Une playlist appartient à un utilisateur. Le partage de playlists entre comptes est hors
périmètre (à décider plus tard : table `playlist_shares`). Ce modèle est actif et
le JSON mobile a été supprimé.

### `acquisition_jobs` / `acquisition_requests`

| `acquisition_requests` | | `acquisition_jobs` | |
|---|---|---|---|
| `id` (pk) | | `id` (pk) | |
| `user_id` (FK) — demandeur | | `request_id` (FK) | |
| `provider_id`, `query`, `selection_json` | | `status`, `progress`, `error` | |
| `status` (`pending`, `approved`, `rejected`) | | `track_id` nullable (résultat) | |
| `created_at`, `decided_at`, `decided_by` (FK users) | | `created_at`, `updated_at` | |

Un `USER` **demande** ; le `OWNER` (ou un `ADMIN` doté du droit explicite) **approuve**.
Le job qui aboutit crée la ligne `tracks` (si hash inconnu) puis une ligne `user_tracks`
pour le demandeur. Remplace le stockage en mémoire du mock actuel.

## Stockage attribué à un utilisateur (calcul futur)

Le « stockage utilisateur » est une **valeur logique**, pas un usage disque réel :

- **Attribution simple** : `SUM(tracks.size_bytes)` sur les lignes `user_tracks` de
  l'utilisateur. Simple mais compte un fichier partagé une fois **par utilisateur**.
- **Méthode retenue contre le double comptage** : coût partagé —
  `SUM(tracks.size_bytes / nombre_d_utilisateurs_ayant_acces)` (répartition au prorata,
  calculée par une requête groupée sur `user_tracks`). Le total des quotas logiques reste
  alors égal à l'espace disque réellement consommé.
- Les deux valeurs peuvent être exposées (`storageAttributed`, `storageShared`) ; les
  quotas éventuels s'appliqueront sur la valeur au prorata.

`user_tracks` est désormais actif. L'endpoint self-summary expose le stockage
logique du compte courant.

## Suppression d'un compte — comportement des données (documenté dès maintenant)

Aujourd'hui (phase auth) : suppression transactionnelle de `users` + `sessions` ;
`audit_logs` conserve les entrées (l'`actorUserId`/`targetUserId` devient un ID orphelin
assumé, le journal reste une trace historique). Aucun fichier audio n'est touché.

Cible multi-utilisateur : la suppression retirera aussi `user_tracks`, `favorites`,
`playlists`/`playlist_tracks` et anonymisera les `acquisition_requests` du compte. Les
lignes `tracks` et les fichiers physiques ne sont **jamais** supprimés automatiquement.

## Verrous activés

1. `tracks`, cover, stream, download et sync passent par `requireAuth` et sont
   filtrés via `user_tracks`.
2. La migration attribue les pistes existantes au OWNER, avec backfill au
   démarrage et après bootstrap.
3. Flutter transmet le Bearer au lecteur just_audio et aux pochettes. La lecture
   réelle reste à confirmer sur le vrai téléphone Android.

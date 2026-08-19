# HomeSpotify H24 — É4 : copie additive de la bibliothèque vers HYDRA

**Préparé, non exécuté.** Aucune copie n'a lieu avant validation du rapport É1–É3.

---

## 0. Correction d'un écart constaté pendant É3

Le périmètre n'est plus de 173 fichiers.

| Source | Phase 1 (2026-08-17 ~16:20) | É3 (2026-08-18 14:23) |
|---|---|---|
| Fichiers `.flac` sur le gros PC | 173 | **175** |
| Entrées de l'index Storage Agent | 173 (`generatedAt` 2026-08-16T19:41) | **175** (`generatedAt` 2026-08-17T19:10) |
| Lignes `tracks` en base PROD | 173 | **175** |

Deux pistes ont été acquises **après** l'audit de Phase 1 :

```
#175  winnterzuko - Rollo      2026-08-17T19:10:19.854Z
#174  winnterzuko - Trotski    2026-08-17T19:09:50.700Z
```

Conséquence de méthode : **le manifeste M0 doit être construit au moment de la copie**, jamais
recopié d'un audit antérieur. PROD reste vivante pendant tout le chantier ; toute valeur figée
devient fausse. Le manifeste porte donc son propre horodatage et son propre décompte, et la
vérification finale compare HYDRA au **manifeste**, pas à un nombre écrit dans un document.

Le fichier `.wav` présent dans l'arborescence (`autres : 1`) n'est **pas** dans l'index : il n'est
donc pas au périmètre. La copie suit l'index, pas le système de fichiers.

---

## 1. Manifeste M0

Construit sur le gros PC, **en lecture seule**, immédiatement avant la copie :

Pour chaque entrée `trackId → relativePath` de `index.json` :

| Champ | Source |
|---|---|
| `trackId` | clé de l'index |
| `relativePath` | valeur de l'index, **octet pour octet** |
| `sizeBytes` | `Get-Item` |
| `sha256` | `Get-FileHash` |
| `pathBytesUtf8` | encodage UTF-8 du chemin relatif, en hexadécimal |
| `nfcEqual` | le chemin est-il déjà en forme NFC ? |

Le manifeste est écrit en UTF-8 sans BOM, horodaté, et **son propre SHA-256 est relevé** avant
usage : c'est la référence de la copie et de la vérification.

Contrôles bloquants à la construction :

1. chaque `relativePath` de l'index correspond à un fichier réellement présent ;
2. aucun chemin ne contient `..`, ni chemin absolu, ni lettre de lecteur ;
3. le décompte du manifeste est égal au décompte de l'index ;
4. aucun doublon de `relativePath`.

---

## 2. Le vrai risque : la normalisation Unicode (R1)

La bibliothèque contient des chemins accentués — `MA_TÊTE.flac`, `No_lys`, des parenthèses. Si la
copie normalise différemment `Ê` (NFC `U+00CA` contre NFD `U+0045 U+0302`), le fichier existera sur
HYDRA mais l'agent répondra **404 `TRACK_NOT_INDEXED`**, parce que l'index contient l'autre forme.
Ce serait un échec silencieux, invisible tant qu'on ne lit pas précisément cette piste.

C'est pour cela que la vérification ne se contente pas d'un décompte : elle compare les
**octets UTF-8** des chemins relatifs, des deux côtés, entrée par entrée. NTFS conserve les octets
tels qu'écrits ; c'est l'outil de copie qui peut normaliser. `robocopy` en mode fichier ne
renormalise pas, mais on le vérifie au lieu de le supposer.

---

## 3. Déroulé

- **É4.1 — Ouverture de la surface d'écriture.** `NT SERVICE\HomeSpotifyStorageAgent` passe de
  `ReadAndExecute` à `Modify` sur `D:\HomeSpotifyStorage\music`. Sans cela, les imports durables
  de l'agent 0.3.0 échoueraient. Réversible d'une commande.
- **É4.2 — Manifeste M0** construit sur le gros PC (§1), copié sur HYDRA pour la vérification.
- **É4.3 — Copie** par le LAN, **additive**, source montée en lecture seule côté logique :
  `robocopy` en mode miroir **désactivé** — aucun `/MIR`, aucun `/PURGE`. Rien n'est supprimé, ni
  sur le gros PC, ni sur HYDRA. Reprise possible sans tout refaire.
- **É4.4 — Vérification 175/175** sur HYDRA :
  - SHA-256 recalculé fichier par fichier et comparé au manifeste ;
  - égalité **octet pour octet** des chemins relatifs ;
  - taille identique ;
  - aucun fichier surnuméraire sous la racine.
  Un seul écart ⇒ arrêt, aucun basculement d'index.
- **É4.5 — Publication de l'index** sur HYDRA, copié depuis le gros PC (mêmes `trackId`, mêmes
  `relativePath`). L'agent le recharge à chaud en 5 s.
- **É4.6 — Qualification depuis le VPS**, sans toucher PROD : `HEAD` et `GET` avec `Range` en HMAC
  signé sur `<HYDRA_WG_IP>:3100`, pour au moins :
  - une piste à chemin accentué (`MA_TÊTE.flac`) ;
  - une piste absente du cache VPS ;
  - une des deux pistes récentes (#174, #175) ;
  - comparaison taille + empreinte avec la réponse de `<OLD_AGENT_WG_IP>` pour les mêmes `trackId`.

---

## 4. Ce qui n'est pas touché

- La bibliothèque du gros PC : **lecture seule**, aucun déplacement, aucune suppression.
- `AUDIO_REMOTE_BASE_URL` : reste sur `http://<OLD_AGENT_WG_IP>:3100`.
- PROD : continue d'être servie par le gros PC pendant toute la copie.
- Le pair WireGuard `<OLD_AGENT_WG_IP>`.

## 5. Rollback

La copie étant additive et la source intacte, le rollback d'É4 est le retrait de ce qui a été
écrit sur HYDRA : suppression du contenu de `D:\HomeSpotifyStorage\music` et retour de l'index à
l'état vide. Aucune conséquence sur PROD, qui n'a jamais dépendu de HYDRA à ce stade.

## 6. Point ouvert

La bibliothèque peut encore grandir entre le manifeste et la bascule — elle l'a déjà fait deux
fois en 24 h. La copie É4 n'est donc pas un instantané définitif : une passe de rattrapage,
identique et additive, sera à rejouer juste avant É7, sur un manifeste régénéré.

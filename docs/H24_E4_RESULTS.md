# HomeSpotify H24 — É4 : copie additive et qualification du stockage HYDRA (2026-08-18)

Double stockage en place. **PROD inchangée**, `AUDIO_REMOTE_BASE_URL` toujours sur
`http://<OLD_AGENT_WG_IP>:3100`. Aucune suppression nulle part.

> Les fichiers copiés sur HYDRA sont **temporaires**, destinés à la qualification et au rollback.
> Le reset à zéro sera un chantier coordonné, après bascule validée, avec sauvegarde DB + stockage
> + caches.

---

## 1. Manifeste M0

Construit **juste avant la copie**, depuis l'index autoritaire du gros PC, en lecture seule.

| | |
|---|---|
| Source index | `C:\ProgramData\HomeSpotify\StorageAgent\data\index.json` |
| `indexGeneratedAt` | `2026-08-17T19:10:19.858Z` |
| Racine source | `F:\dev\homespotify\storage\music` |
| Entrées | **175** |
| Taille totale | **3,339 Gio** (3 585 487 704 octets) |
| SHA-256 de M0 | `5ecdc59776b5dde19a789e9f47eade7b641ec1b84ed662dfdc249a60f8acf92d` |

Chaque entrée porte : `relativePath`, `sizeBytes`, `sha256`, `extension`, `mtimeUtc`
(**information seulement, jamais preuve**), `pathUtf8Hex` et `isNfc`.

## 2. Anomalies source

| Contrôle | Résultat |
|---|---|
| Entrées d'index sans fichier | **0** |
| Doublons de `relativePath` | **0** |
| Collisions de casse | **0** |
| Chemins non-NFC | **0** — les 175 sont en NFC |
| Extensions | `.flac = 175` |

**Présents sur disque mais hors index — ni copiés, ni supprimés :**

```
.gitkeep
Artiste_inconnu/Album_inconnu/Ajna___Britney_(All_Black).wav
```

Le périmètre autoritaire est l'index, pas le système de fichiers. Ces deux fichiers restent en
place sur le gros PC.

## 3. Traitement du risque R1 — Unicode et chemins

Les chemins réellement présents dans la bibliothèque :

```
Dexa/No_lys/MA_TÊTE.flac
Elton_John/Too_Low_For_Zero/I'm_Still_Standing.flac
Michael_Sembello/'80s_Pop_#1's/Maniac___From__Flashdance__Soundtrack.flac
Van_Halen/1984_(Remastered)/Jump___2015_Remaster.flac
Eurythmics/Sweet_Dreams_(Are_Made_Of_This)/…
```

Accents, apostrophes, `#`, parenthèses — précisément ce qui casse une copie pilotée par un shell.

**Méthode retenue : les noms de fichiers ne transitent jamais par un shell.** Ils vivent à
l'intérieur d'archives ZIP dont les entrées sont écrites **et relues** avec un `UTF8Encoding`
explicite, via `System.IO.Compression.ZipArchive`. Aucun échappement à faire, donc aucun
échappement à rater ; aucune normalisation possible en chemin. Seuls des noms ASCII
(`batch-N.zip`) apparaissent sur une ligne de commande.

La vérification ne compare pas des chaînes mais les **octets UTF-8** des chemins relatifs,
reconstruits par énumération du système de fichiers côté HYDRA et confrontés au `pathUtf8Hex` de
M0.

## 4. Copie

| | |
|---|---|
| Méthode | 7 lots de 25 fichiers, archive ZIP `NoCompression` → `scp` → extraction .NET |
| Additive | **oui** — aucun `/MIR`, aucun `/PURGE`, aucune suppression, aucun déplacement, aucun renommage |
| Reprise | 3 tentatives par transfert, 2 par extraction, par lot |
| Début / fin | 14:53:05 → 15:37:59 — **44 min 54 s** |
| Échecs / reprises | **0** |
| Fichiers copiés | **175 / 175** |

Débit effectif ≈ **1,3 Mo/s**. C'est la limite du Wi-Fi et de `scp`, pas du disque : un argument
concret de plus pour le switch Ethernet.

Zone de transit vidée après extraction : 0 fichier résiduel.

## 5. Vérification M0 → HYDRA

```
=== VERIFICATION M0 -> HYDRA ===
  entrees manifeste : 175
  fichiers presents : 175
  paths exacts      : 175/175
  sizes exactes     : 175/175
  SHA-256 exacts    : 175/175
  manquants         : 0
  hors manifeste (non supprimes) : 0
  VERDICT VERIFICATION : PASS
```

**Aucune tolérance appliquée, aucune n'a été nécessaire.**

### ACL finales

| Chemin | Droits |
|---|---|
| `D:\HomeSpotifyStorage\music` | `NT SERVICE\HomeSpotifyStorageAgent` **Modify**, Administrateurs FC, SYSTEM FC |
| `D:\` (racine) | CREATEUR PROPRIETAIRE, SYSTEM, Administrateurs — **inchangée**, jamais globalement inscriptible |

`Modify` est conservé sur la racine musicale : c'est l'état cible d'un agent qui doit accepter les
imports durables du VPS. Le rétrécir maintenant pour le rouvrir en É7 créerait un risque d'oubli,
avec échec silencieux à la clé.

## 6. Index HYDRA

| | Gros PC | HYDRA |
|---|---|---|
| Entrées | 175 | **175** |
| `generatedAt` | `2026-08-17T19:10:19.858Z` | **identique** |
| SHA-256 du fichier | `8e3e3f47…80f7` | **identique** |

Rechargé **à chaud** par l'agent, sans redémarrage :

```
STORAGE_AGENT_INDEX_LOADED  entryCount=175  generatedAt=2026-08-17T19:10:19.858Z
```

## 7. Lecture réelle depuis le VPS

Requêtes HMAC signées vers `<HYDRA_WG_IP>:3100`.

**`HEAD` — `content-length` confronté à M0**

| Cas | trackId | Résultat |
|---|---|---|
| accentué `MA_TÊTE.flac` | 7 | 200 · 14 254 943 · **OK** |
| apostrophe `I'm_Still_Standing` | 9 | 200 · 22 932 072 · **OK** |
| dièse `'80s_Pop_#1's` | 13 | 200 · 30 634 066 · **OK** |
| parenthèses `1984_(Remastered)` | 4 | 200 · 33 231 759 · **OK** |
| récent (adressé par contenu) | 174 | 200 · 17 602 626 · **OK** |
| récent | 175 | 200 · 16 481 222 · **OK** |
| simple `AC_DC` | 2 | 200 · 32 736 249 · **OK** |

**`GET` complet — SHA-256 des octets reçus confronté à M0**

| Cas | trackId | Octets | SHA-256 |
|---|---|---|---|
| accentué | 7 | 14 254 943 | **conforme** |
| dièse | 13 | 30 634 066 | **conforme** |
| récent | 174 | 17 602 626 | **conforme** |

**`Range`** : `bytes=0-1048575` sur trackId 2 → **206**, 1 048 576 octets.

Les pistes 174 et 175 vivent sous `.homespotify/objects/<xx>/<sha256>` — la disposition adressée
par contenu de la surface d'écriture durable de l'agent 0.3.0. Elles se lisent correctement.

## 8. Dérive et rattrapage

| | M0 | État autoritaire après copie |
|---|---|---|
| `indexGeneratedAt` | `2026-08-17T19:10:19.858Z` | **identique** |
| Entrées | 175 | **175** |
| Nouveaux | — | **0** |
| Disparus | — | **0** |

**Delta M1 vide.** Aucune dérive pendant les 45 minutes de copie, aucun rattrapage nécessaire.

Une dernière passe reste obligatoire juste avant É7 : la bibliothèque a grandi deux fois en 24 h
avant ce chantier, elle peut recommencer.

## 9. Double stockage

| | `<OLD_AGENT_WG_IP>` (gros PC) | `<HYDRA_WG_IP>` (HYDRA) |
|---|---|---|
| Version agent | 0.3.0 | 0.3.0 |
| `indexEntryCount` | **175** | **175** |
| `indexGeneratedAt` | `2026-08-17T19:10:19.858Z` | **identique** |
| `/health` en HMAC | 200 | 200 |

Les deux agents présentent le **même instantané M0**. PROD n'utilise que `<OLD_AGENT_WG_IP>`.

## 10. Stabilité et intégrité de la source

**HYDRA**

| | |
|---|---|
| WD Elements | `Healthy`, **39 °C**, 6 h, 0 erreur de lecture |
| SSD système | `Healthy`, 40 °C, 3636 h |
| `D:` | **3,56 Go utilisés**, 3722,4 Go libres, `Healthy` |
| Carte (ACPI) | 27,9 °C |
| Services | agent, tunnel, `sshd`, Tailscale — tous `Running / Automatic` |
| Processus `node` | 1 seul, 76 Mo, 1,9 s CPU — **aucun zombie** |
| Erreurs disque/USB 24 h | **AUCUNE** |
| Erreurs système depuis le boot | 3, toutes préexistantes et sans rapport (Secure Boot désactivé au BIOS, lecture de config pare-feu au démarrage, service Intel lent) |

**Gros PC — source intacte**

| | |
|---|---|
| Fichiers sous la racine | **177** (175 indexés + `.gitkeep` + 1 `.wav`) |
| Entrées M0 présentes, taille conforme | **175/175**, 0 écart |
| Sondage d'empreintes | 5/5 conformes, dont `'80s_Pop_#1's` |
| Agent + tunnel | `Running / Automatic` |

**PROD**

`/health` public **200** · `api-shadow` actif · `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100` ·
handshakes WireGuard frais sur les deux pairs, compteurs du gros PC préservés (22,48 Gio).

## 11. Verdict

| Critère | Résultat |
|---|---|
| Manifeste cohérent | ✅ 175, 0 anomalie |
| Copie complète | ✅ 175/175, 0 échec |
| Chemins exacts | ✅ 175/175, comparaison octet pour octet |
| SHA-256 exacts | ✅ 175/175 |
| Index HYDRA cohérent | ✅ 175, empreinte identique, rechargé à chaud |
| Lecture depuis le VPS | ✅ HEAD, GET complet et Range, chemins sensibles compris |
| Ancien stockage intact | ✅ source vérifiée, agent opérationnel |
| PROD inchangée | ✅ |

# H24_E4_PASS

## 12. Préparation d'É5

É5 qualifie HYDRA **en conditions de production, sans bascule**. Rien n'y modifie
`AUDIO_REMOTE_BASE_URL`.

- **É5.1** — Lecture exhaustive : `HEAD` sur les 175 entrées depuis le VPS, `content-length`
  confronté à M0. Ce qu'É4 a fait sur 7 pistes, étendu à la totalité.
- **É5.2** — Échantillon large de `GET` complets avec comparaison SHA-256, dimensionné pour rester
  raisonnable sur le lien Wi-Fi (~1,3 Mo/s) : viser 20 à 25 pistes, tous cas sensibles inclus.
- **É5.3** — `Range` multiples et non alignés, y compris en fin de fichier, pour reproduire le
  comportement réel de Media3.
- **É5.4** — Test de charge modéré : plusieurs flux concurrents, plafond de l'agent à 8, afin de
  vérifier `maxConcurrentStreams` et l'absence de saturation du tunnel.
- **É5.5** — Endurance : lecture longue et continue pour vérifier qu'aucun `BODY_TIMEOUT` ni
  décrochage USB n'apparaît côté HYDRA, sur le modèle du chantier de fiabilité déjà mené.
- **É5.6** — Comparaison directe `<OLD_AGENT_WG_IP>` contre `<HYDRA_WG_IP>` sur les mêmes `trackId` : mêmes
  tailles, mêmes empreintes, latences relevées.
- **É5.7** — Redémarrage à froid supplémentaire, puis rejeu d'un sous-ensemble, pour prouver que la
  chaîne tunnel → agent → lecture survit sans intervention.

Points ouverts pour la suite :

1. le test Tailscale **depuis l'extérieur du domicile** reste à faire avant É7 ;
2. le débit Wi-Fi de 1,3 Mo/s devra être réévalué une fois le switch Ethernet en place — il
   conditionne le confort de lecture en cas de défaut de cache VPS ;
3. la passe de rattrapage finale, obligatoire juste avant É7.

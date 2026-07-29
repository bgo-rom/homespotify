# Phase 6.4B1 — Hardening, release et rollback

Date réelle : 2026-07-29
Verdict : **NO-GO**

Le hardening MemoryMax et le cycle réel A → B → A → B sont qualifiés. Le
verdict global reste NO-GO parce que le compte d'exécution ne possède pas le
droit Windows nécessaire pour arrêter `HomeSpotifyStorageAgent`. Le service
n'a jamais été arrêté et le test hors ligne n'a donc pas été simulé.

## Releases et artefacts

- Release A :
  `20260728T185714Z-88a6d12f-f09a54cf`
  (`88a6d12f74a73daebbcb1077e86c132977417d6c`).
- Release B :
  `20260729T200813Z-596e4764-f09a54cf`
  (`596e476453996f21d5f403390d57e8a6e6850813`).
- Aucun diff Git entre A et B pour `services/api`,
  `services/storage-agent`, `migrations`, `package.json` et `pnpm-lock.yaml`.
- A et B : 119 fichiers runtime, 1 095 066 octets,
  `manifestSha256=f09a54cf44d4ec6ab756972687a5262a724ee674b80444937ec18f8a9c9ba562`.
- Aucun source map, `.env`, secret ou installation npm. Bundle partagé
  `linux-x64-node22.18.0-abi127`, Node v22.18.0, ABI 127.

## MemoryMax

Le pic réel 6.4A est 114 892 KiB, soit 112,199 MiB. La limite de 384 MiB vaut
3,422 fois ce pic et 402 653 184 octets. Elle est appliquée par :

`/etc/systemd/system/homespotify-api-shadow.service.d/20-memory.conf`

```ini
[Service]
MemoryAccounting=yes
MemoryMax=384M
```

Avant application : `MemoryMax=infinity`, PID 64872. Après application :
PID 77701, health au troisième essai, `MemoryMax=402653184`, service
`active/running`, `disabled`, listener unique `127.0.0.1:3002`.

Surveillance réelle de 15 minutes, 16 échantillons :

- PID 77701 et `NRestarts=0` stables ;
- RSS 108 048–113 408 KiB ;
- MemoryCurrent 58 056 704–63 369 216 octets ;
- MemoryPeak 65 785 856 octets, lu dans le cgroup ;
- FD 29 et threads 11 stables ;
- health 200 et listener loopback unique à chaque échantillon ;
- aucun warning, erreur ou OOM pendant la fenêtre.

`systemd-analyze verify` a exposé une anomalie antérieure :
`StartLimitIntervalSec` était sous `[Service]`. L'unité originale est
sauvegardée dans
`/var/backups/homespotify-api-shadow.service.phase64b1-20260729`; les deux
directives StartLimit ont été déplacées sous `[Unit]`. La vérification est
ensuite silencieuse et le redémarrage donne le PID final 79141.

Rollback du drop-in :

1. supprimer uniquement
   `/etc/systemd/system/homespotify-api-shadow.service.d/20-memory.conf` ;
2. exécuter `systemctl daemon-reload` ;
3. redémarrer uniquement `homespotify-api-shadow.service` ;
4. vérifier `MemoryMax=infinity`, health 200, listener loopback et
   `is-enabled=disabled`.

## Promotion, rollback et re-promotion

### A → B

- bascule atomique en 1 657 ms, health au septième essai ;
- PID 77701 → 78439 ;
- auth 401 sans jeton et 200 avec jeton ;
- liste, pochette, HEAD 200, Range 206, GET 200 ;
- piste 119 : 18 619 182 octets, SHA-256 exact, `CACHE_HIT`, aucun upstream ;
- SQLite `integrity_check=ok`, zéro violation FK, 18 migrations ;
- cache persistant après restart ;
- surveillance 5 minutes : PID stable, RSS 88 904–93 620 KiB,
  `NRestarts=0`, health 200, aucun warning.

### B → A réel

- durée totale : 1 594 ms ;
- indisponibilité localhost : 1 526,8 ms ;
- 30 sondes en échec, retour 200 à la 31e tentative ;
- PID 78439 → 78633 ;
- release A, auth, HEAD/Range/GET, hash, cache sans upstream, SQLite,
  listener et journald conformes.

### A → B finale

- durée : 1 663 ms, health au septième essai ;
- PID 78719 avant la correction syntaxique systemd, puis PID final 79141 ;
- release B et contrôles essentiels conformes.

État final :

- `current` → release B ;
- `previous` → release A ;
- shadow `active/running`, `disabled`, `NRestarts=0` ;
- listener unique `127.0.0.1:3002` ;
- MemoryMax effectif 384 MiB.

## Test Storage Agent hors ligne

Préconditions confirmées : `HomeSpotifyApi` et
`HomeSpotifyStorageAgent` sont `Running`, l'API Windows écoute sur 3000 et le
health public vaut 200. La piste 119 est en cache. La piste 1 a été choisie
dynamiquement comme absente du cache
(`2e116d1386519cf794fe00869ada92b05235e00200cb41a652c2b8205d7e13b7`,
28 870 968 octets).

L'arrêt a été refusé par Windows :

`Stop-Service: Impossible d'ouvrir le service HomeSpotifyStorageAgent`

La première tentative avait masqué cette erreur initiale par une erreur dans
le `finally`; les contrôles suivants prouvent que le service n'avait jamais
quitté `Running`. Aucune élévation UAC ni contournement de droits n'a été
tenté. Conséquences :

- test cached/offline : **NON EXÉCUTÉ** ;
- comportement uncached hors ligne : **NON EXÉCUTÉ** ;
- récupération après redémarrage : **NON EXÉCUTÉ** ;
- aucun `.part`, aucun objet piste 1, cache inchangé ;
- les deux services Windows et le health public sont restés sains.

## Contrôles finaux

- cache : un objet qualifié, zéro `.part` ;
- SQLite : integrity `ok`, zéro violation FK, 18 migrations ;
- Caddy actif, empreinte inchangée
  `a3b4ca2b441f311a9970755830b866b36247db8619a07583f5b9b9e796785cc4` ;
- public `/health=200`, WireGuard `wg0` actif ;
- services Windows `Running`, production Windows toujours sur 3000 ;
- aucun résidu `phase64b1-*` sous `/run` ;
- aucun port public ajouté, aucune bascule publique ;
- aucun reboot, aucun `systemctl enable`, aucun push, aucun tag.

## À vérifier

- Relancer uniquement le test Storage Agent hors ligne depuis une console
  Windows explicitement élevée, avec le même `try/finally` borné à 90 s.
- Ne pas commencer la Phase 6.4B2 avant validation explicite et passage de ce
  dernier gate.

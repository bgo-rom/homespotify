# WinSW — préparation Phase 3 (NON INSTALLÉ)

Ce dossier contient **uniquement un modèle**. Au terme de la Phase 2 :

- aucun service Windows n'est installé ;
- aucun service n'est démarré ;
- aucun compte Windows n'est créé ;
- aucune règle de pare-feu n'est ajoutée ou modifiée ;
- `WinSW.exe` n'est pas présent dans le dépôt.

## Fichier

| Fichier | Rôle |
| --- | --- |
| `homespotify-storage-agent.xml.example` | Modèle de configuration WinSW, inerte. |

L'extension `.example` est délibérée : WinSW n'accepte qu'un XML portant
exactement le nom de l'exécutable, ce modèle ne peut donc pas être exécuté par
accident.

## Ce qui reste à faire en Phase 3

1. Créer le compte local dédié `HomeSpotifySA` — non administrateur, sans
   session interactive, avec le seul droit « Ouvrir une session en tant que
   service ».
2. Créer `C:\ProgramData\HomeSpotify\storage-agent\agent.env` avec des ACL
   restreintes (SYSTEM, Administrateurs, `HomeSpotifySA` en lecture) et y placer
   le secret partagé. Ce fichier ne doit jamais entrer dans le dépôt.
3. Accorder à `HomeSpotifySA` la lecture seule sur la racine musicale et sur le
   fichier d'index.
4. `pnpm --filter @homespotify/storage-agent build` puis copier `WinSW.exe`
   renommé à côté du XML.
5. Basculer `STORAGE_AGENT_HOST` sur `10.8.0.2` (bind WireGuard).
6. Remplacer la règle Windows générique Node.js — trop permissive — par une
   règle d'entrée dédiée : port 3100/TCP, interface WireGuard, source
   `10.8.0.1` uniquement.
7. Installer puis démarrer le service, et vérifier `/internal/storage/health`
   depuis le VPS.

Tant que l'étape 6 n'est pas faite, l'agent ne doit rester lié qu'à
`127.0.0.1` : c'est la condition posée par l'audit de Phase 1.5.

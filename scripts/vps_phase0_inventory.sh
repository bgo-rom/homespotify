#!/usr/bin/env bash
# =============================================================================
# HomeSpotify — Inventaire Phase 0 du VPS (LECTURE SEULE)
# =============================================================================
#
# Ce script NE MODIFIE RIEN :
#   - n'installe aucun paquet
#   - ne redémarre aucun service
#   - ne touche ni à Caddy, ni à WireGuard, ni au pare-feu
#   - n'affiche aucune clé privée, aucun token, aucun fichier d'environnement
#
# Toute clé éventuellement rencontrée est caviardée avant écriture.
#
# Usage :
#   bash vps_phase0_inventory.sh
#
# Le rapport est écrit dans : ~/homespotify-vps-inventory-<date>.txt
# Relisez-le avant de le partager.
# =============================================================================

set -uo pipefail   # pas de -e : une commande absente ne doit pas interrompre l'inventaire

REPORT="${HOME}/homespotify-vps-inventory-$(date +%Y%m%d-%H%M%S).txt"

# Caviarde toute clé/secret qui apparaîtrait dans une sortie.
redact() {
  sed -E \
    -e 's/(PrivateKey[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/I' \
    -e 's/(PresharedKey[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/I' \
    -e 's/(private_key|secret|token|password|passwd|api[_-]?key)([[:space:]]*[:=][[:space:]]*).*/\1\2<REDACTED>/I' \
    -e 's#(Authorization:[[:space:]]*)[^ ]+#\1<REDACTED>#I' \
    -e 's/[A-Za-z0-9+\/]{43}=/<REDACTED-BASE64-KEY>/g'
}

section() { printf '\n===== %s =====\n' "$1"; }

# Exécute une commande si elle existe, sinon signale l'absence.
try() {
  local label="$1"; shift
  printf -- '--- %s ---\n' "$label"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 | redact
  else
    printf '(commande absente : %s)\n' "$1"
  fi
}

{
  printf 'HomeSpotify — inventaire VPS Phase 0\n'
  printf 'Date    : %s\n' "$(date -Is)"
  printf 'Hôte    : %s\n' "$(hostname)"
  printf 'Script  : lecture seule, aucune modification\n'

  # ---------------------------------------------------------------- SYSTÈME
  section 'SYSTÈME'
  try 'Distribution' cat /etc/os-release
  printf -- '--- Noyau / architecture ---\n'; uname -a 2>&1 | redact
  printf -- '--- CPU ---\n'
  printf 'vCPU : %s\n' "$(nproc 2>/dev/null || echo '?')"
  grep -m1 'model name' /proc/cpuinfo 2>/dev/null || echo '(modèle indisponible)'
  printf -- '--- Mémoire ---\n'; free -h 2>&1
  printf -- '--- Swap ---\n'; swapon --show 2>&1 || echo '(aucun swap)'
  printf -- '--- Uptime ---\n'; uptime 2>&1
  printf -- '--- Heure / NTP ---\n'; timedatectl 2>&1 || date

  # ----------------------------------------------------------------- DISQUE
  section 'DISQUE (déterminant pour le budget de cache)'
  printf -- '--- df -h ---\n'; df -h 2>&1
  printf -- '--- df -h / (partition racine) ---\n'; df -h / 2>&1
  printf -- '--- Inodes ---\n'; df -i 2>&1
  printf -- '--- Partitions ---\n'; lsblk 2>&1 || echo '(lsblk absent)'
  printf -- '--- Tailles des répertoires clés ---\n'
  for d in /var /var/lib /var/log /var/cache /opt /home /tmp; do
    if [ -d "$d" ]; then
      printf '%-12s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    fi
  done
  printf -- '--- 10 plus gros répertoires sous /var ---\n'
  du -h --max-depth=2 /var 2>/dev/null | sort -rh | head -10

  # ------------------------------------------------------------ ENVIRONNEMENT
  section 'ENVIRONNEMENT D EXÉCUTION'
  try 'Node.js' node --version
  try 'npm' npm --version
  try 'pnpm' pnpm --version
  try 'Python 3 (build natif)' python3 --version
  printf -- '--- Outils de compilation (better-sqlite3, @node-rs/argon2) ---\n'
  for t in gcc g++ make; do
    printf '%-6s %s\n' "$t" "$(command -v $t >/dev/null 2>&1 && echo présent || echo ABSENT)"
  done
  try 'sqlite3 CLI' sqlite3 --version
  try 'ffmpeg' ffmpeg -version
  try 'ffprobe' ffprobe -version

  # ------------------------------------------------------------------ CADDY
  section 'CADDY'
  try 'Version' caddy version
  printf -- '--- Statut du service ---\n'
  systemctl is-active caddy 2>&1 || true
  systemctl status caddy --no-pager 2>&1 | head -15 | redact || true
  printf -- '--- Emplacement du Caddyfile ---\n'
  for f in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile ~/Caddyfile; do
    [ -f "$f" ] && printf 'TROUVÉ : %s\n' "$f"
  done
  printf -- '--- Contenu du Caddyfile (caviardé) ---\n'
  if [ -r /etc/caddy/Caddyfile ]; then
    redact < /etc/caddy/Caddyfile
  else
    printf '(illisible sans privilèges — relancer : sudo cat /etc/caddy/Caddyfile)\n'
  fi
  printf -- '--- Certificats (chemins uniquement, jamais les clés) ---\n'
  find /var/lib/caddy -name '*.crt' 2>/dev/null | head -10 || echo '(aucun)'
  printf -- '--- Journaux Caddy récents (30 dernières lignes, caviardées) ---\n'
  if [ -d /var/log/caddy ]; then
    tail -n 30 /var/log/caddy/*.log 2>/dev/null | redact || echo '(illisible)'
  else
    journalctl -u caddy -n 30 --no-pager 2>&1 | redact || echo '(indisponible)'
  fi

  # -------------------------------------------------------------- WIREGUARD
  section 'WIREGUARD (clés systématiquement caviardées)'
  printf -- '--- wg show (sans clés privées) ---\n'
  if command -v wg >/dev/null 2>&1; then
    wg show 2>&1 | redact || echo '(nécessite sudo : sudo wg show)'
  else
    echo '(commande wg absente)'
  fi
  printf -- '--- Interfaces WireGuard ---\n'
  ip -brief address show type wireguard 2>&1 || ip -brief address 2>&1 | grep -i wg || echo '(aucune interface wg)'
  printf -- '--- Configuration (caviardée) ---\n'
  if [ -r /etc/wireguard/wg0.conf ]; then
    redact < /etc/wireguard/wg0.conf
  else
    printf '(illisible sans privilèges — relancer : sudo cat /etc/wireguard/wg0.conf | sed -E "s/(PrivateKey|PresharedKey).*/\\1 = <REDACTED>/I")\n'
  fi
  printf -- '--- Statut du service ---\n'
  systemctl is-active wg-quick@wg0 2>&1 || true

  # ------------------------------------------------------------------ RÉSEAU
  section 'RÉSEAU'
  printf -- '--- Adresses ---\n'; ip -brief address 2>&1
  printf -- '--- Routes ---\n'; ip route 2>&1
  printf -- '--- Ports en écoute ---\n'
  ss -tulpn 2>&1 | redact || netstat -tulpn 2>&1 | redact || echo '(ss et netstat absents)'
  printf -- '--- Pare-feu (synthèse) ---\n'
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>&1 || echo '(nécessite sudo)'
  elif command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>&1 | head -40 | redact || echo '(nécessite sudo)'
  else
    iptables -L -n 2>&1 | head -30 || echo '(indisponible sans sudo)'
  fi

  # ------------------------------------------------------------ HOMESPOTIFY
  section 'SERVICES HOMESPOTIFY EXISTANTS'
  printf -- '--- Unités systemd ---\n'
  systemctl list-units --all --no-pager 2>/dev/null | grep -i homespotify || echo '(aucune unité HomeSpotify)'
  printf -- '--- Répertoires cibles ---\n'
  for d in /opt/homespotify /var/lib/homespotify /etc/homespotify /var/log/homespotify /var/backups/homespotify; do
    if [ -e "$d" ]; then
      printf '%-30s EXISTE DÉJÀ (%s)\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else
      printf '%-30s absent (normal avant migration)\n' "$d"
    fi
  done
  printf -- '--- Utilisateur système homespotify ---\n'
  id homespotify 2>&1 || echo '(utilisateur absent — normal avant migration)'

  section 'FIN DE L INVENTAIRE'
  printf 'Rapport : %s\n' "$REPORT"
  printf 'Relisez-le avant partage : aucun secret ne devrait y figurer.\n'

} > "$REPORT" 2>&1

chmod 600 "$REPORT"

echo "Inventaire terminé."
echo "Rapport : $REPORT"
echo
echo "Vérification anti-secret avant partage :"
echo "  grep -iE 'privatekey|presharedkey|secret|token|password' \"$REPORT\""
echo "  (les correspondances doivent toutes afficher <REDACTED>)"

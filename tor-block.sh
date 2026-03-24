#!/bin/bash
set -euo pipefail

# =============================================================================
# Purpose:     Tor exit node blocking via iptables + ipset
#
# NOTE: For devoops.lol infrastructure this script has LIMITED effect:
#
#   Web traffic (Moodle/Keycloak/Guacamole):
#     Tor → Cloudflare edge → cloudflared tunnel → VM (127.0.0.1)
#     Real client IP never reaches VM. Block Tor at Cloudflare WAF instead:
#     Security → WAF → Create Rule → IP Source Category = Anonymous Proxies → Block
#
#   SSH traffic:
#     Already restricted to 192.168.2.197 (Guacamole) only via iptables.
#     Tor cannot reach SSH regardless of this script.
#
#   This script is retained as a defence-in-depth measure for any future
#   services exposed directly (not behind Cloudflare tunnel).
#
# Usage:       sudo bash tor-block.sh
# Cron:        0 */6 * * * root /usr/local/sbin/tor-block.sh
# Last Updated: 2026-03
# =============================================================================

IPSET_NAME="tor_exits"
TOR_LIST_URL="https://check.torproject.org/torbulkexitlist"
RULES_FILE="/etc/iptables/rules.v4"
LOG_TAG="tor-block"

[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }
command -v ipset &>/dev/null || apt-get install -y -qq ipset
mkdir -p /etc/iptables

# === CREATE OR FLUSH ipset ===
if ipset list "$IPSET_NAME" &>/dev/null; then
  ipset flush "$IPSET_NAME"
  echo "[INFO] Flushed existing ipset: $IPSET_NAME"
else
  ipset create "$IPSET_NAME" hash:net maxelem 65536
  echo "[INFO] Created ipset: $IPSET_NAME"
fi

# === DOWNLOAD TOR EXIT LIST ===
echo "[INFO] Downloading Tor exit node list..."
TMP_FILE=$(mktemp)
# Force IPv4 — harden-common.sh disables IPv6 via sysctl
if ! curl -4 -sSf --max-time 30 "$TOR_LIST_URL" -o "$TMP_FILE"; then
  echo "[WARN] Failed to download Tor list — keeping existing rules."
  rm -f "$TMP_FILE"
  exit 0
fi

# === POPULATE ipset ===
COUNT=0
while IFS= read -r ip; do
  [[ "$ip" =~ ^#.*$ || -z "$ip" ]] && continue
  ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
  COUNT=$((COUNT + 1))
done < "$TMP_FILE"
rm -f "$TMP_FILE"
echo "[INFO] Loaded $COUNT Tor exit IPs into ipset"

# === APPLY IPTABLES RULES (idempotent) ===
# Remove existing tor rules to avoid duplicates
iptables -D INPUT -m set --match-set "$IPSET_NAME" src -j DROP \
  2>/dev/null || true
iptables -D INPUT -m set --match-set "$IPSET_NAME" src \
  -j LOG --log-prefix "TOR_BLOCKED: " --log-level 4 2>/dev/null || true

# Insert after loopback (pos 1) and ESTABLISHED (pos 2) rules
# so legitimate established connections are never interrupted
iptables -I INPUT 3 -m set --match-set "$IPSET_NAME" src \
  -j LOG --log-prefix "TOR_BLOCKED: " --log-level 4
iptables -I INPUT 4 -m set --match-set "$IPSET_NAME" src -j DROP

echo "[INFO] iptables rules inserted at position 3-4 (after lo + ESTABLISHED)"

# === PERSIST ===
ipset save | tee /etc/ipset.rules > /dev/null
iptables-save | tee "$RULES_FILE" > /dev/null
netfilter-persistent save 2>/dev/null || true

# === BOOT PERSISTENCE FOR ipset ===
if [[ ! -f /etc/systemd/system/ipset-restore.service ]]; then
  cat > /etc/systemd/system/ipset-restore.service << 'EOF'
[Unit]
Description=Restore ipset rules on boot
Before=netfilter-persistent.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f /etc/ipset.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ipset-restore.service
  echo "[INFO] ipset-restore.service installed"
fi

# === CRON ===
CRON_FILE="/etc/cron.d/tor-block"
if [[ ! -f "$CRON_FILE" ]]; then
  echo "0 */6 * * * root /usr/local/sbin/tor-block.sh >> /var/log/tor-block.log 2>&1" \
    > "$CRON_FILE"
  echo "[INFO] Cron job created: $CRON_FILE (every 6 hours)"
fi

# Copy self to sbin for cron use
cp "$0" /usr/local/sbin/tor-block.sh
chmod +x /usr/local/sbin/tor-block.sh

echo ""
echo "[INFO] ============================================================"
echo "[INFO] Tor blocking complete. IPs loaded: $COUNT"
echo ""
echo "[NOTE] Web traffic is protected by Cloudflare WAF (Anonymous Proxies rule)"
echo "[NOTE] SSH is protected by iptables source restriction (Guacamole only)"
echo "[NOTE] This ipset provides defence-in-depth for any direct-exposed services"
echo "[INFO] ============================================================"

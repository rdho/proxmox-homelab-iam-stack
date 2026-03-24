#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Continue Moodle setup from the point where Apache failed due to
#              missing Let's Encrypt cert (SSLCertificateFile does not exist).
#
#              This script:
#                1. Fixes loopback iptables (blocks 127.0.0.1 → Apache/PHP-FPM)
#                2. Generates a self-signed cert so Apache can start cleanly
#                3. Runs certbot (Cloudflare DNS-01) to get real Let's Encrypt cert
#                4. Swaps Apache config to the real cert and reloads
#                5. Installs cloudflared tunnel for learn.sampledomain.com
#                6. Validates everything end-to-end
#
# Usage:       sudo bash moodle-continue.sh <CF_API_TOKEN> <CF_TUNNEL_TOKEN>
#
#              CF_API_TOKEN    — Cloudflare API token with Zone:DNS:Edit on sampledomain.com
#                                Create at: dash.cloudflare.com → My Profile → API Tokens
#                                Use template: "Edit zone DNS" → Zone: sampledomain.com
#
#              CF_TUNNEL_TOKEN — Cloudflare Tunnel token (remotely-managed tunnel)
#                                Create at: dash.cloudflare.com → Zero Trust →
#                                Networks → Tunnels → Create tunnel → Cloudflared
#                                Name it "moodle", copy the token shown
#
# Prerequisites:
#   - install-moodle.sh completed (Apache, PHP, PostgreSQL, Moodle files installed)
#   - Outbound internet access from this VM
#
# Last Updated: 2026-03
# =============================================================================

# === VARIABLES ===
DOMAIN="learn.sampledomain.com"
ADMIN_EMAIL="admin@sampledomain.com"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
CF_CREDS="/etc/letsencrypt/cloudflare.ini"
SELF_SIGNED_DIR="/etc/apache2/ssl/selfsigned"
HTTPS_CONF="/etc/apache2/sites-available/moodle-https.conf"
TUNNEL_NAME="moodle"

# === ARGS ===
CF_API_TOKEN="${1:-}"
CF_TUNNEL_TOKEN="${2:-}"

# === PREFLIGHT ===
[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

if [[ -z "$CF_API_TOKEN" ]]; then
  echo "[ERROR] Missing Cloudflare API token."
  echo "        Usage: sudo bash $0 <CF_API_TOKEN> <CF_TUNNEL_TOKEN>"
  echo ""
  echo "        CF_API_TOKEN:    Zone:DNS:Edit token from dash.cloudflare.com"
  echo "        CF_TUNNEL_TOKEN: Tunnel token from Zero Trust → Tunnels"
  exit 1
fi

if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
  echo "[ERROR] Missing Cloudflare Tunnel token."
  echo "        Usage: sudo bash $0 <CF_API_TOKEN> <CF_TUNNEL_TOKEN>"
  echo ""
  echo "        Create at: Zero Trust → Networks → Tunnels → Create tunnel"
  echo "        Choose 'Cloudflared', name it '${TUNNEL_NAME}', copy the token."
  exit 1
fi

echo "[INFO] ============================================================"
echo "[INFO] Moodle post-install continuation script"
echo "[INFO] DOMAIN : $DOMAIN"
echo "[INFO] ============================================================"

# === STEP 1: fix loopback iptables ============================================
# install-moodle.sh adds a blanket DROP for unexpected traffic but doesn't
# explicitly allow loopback. This blocks Apache → PHP-FPM (Unix socket is fine,
# but any 127.0.0.1 TCP traffic — including health checks — gets dropped).
# Insert ACCEPT for lo at position 1, before any DROP rules.
echo ""
echo "[STEP 1] Fixing loopback iptables rule..."
if iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
  echo "[OK]   Loopback ACCEPT rule already present. Skipping."
else
  iptables -I INPUT 1 -i lo -j ACCEPT
  echo "[OK]   Loopback ACCEPT rule inserted at position 1."
fi
iptables-save > /etc/iptables/rules.v4
echo "[OK]   iptables rules saved."

# === STEP 2: verify Apache and PHP-FPM are installed =========================
echo ""
echo "[STEP 2] Checking Apache and PHP-FPM..."
command -v apache2 &>/dev/null || { echo "[ERROR] Apache not installed. Run install-moodle.sh first."; exit 1; }
systemctl is-enabled php8.3-fpm &>/dev/null || { echo "[ERROR] php8.3-fpm not installed."; exit 1; }
[[ -f "$HTTPS_CONF" ]] || { echo "[ERROR] $HTTPS_CONF not found. Run install-moodle.sh first."; exit 1; }
echo "[OK]   Apache and PHP-FPM present."

# === STEP 3: bootstrap Apache with self-signed cert ==========================
# Apache refuses to start (even configtest fails) if SSLCertificateFile points
# at a non-existent file. We generate a 1-day self-signed cert at the exact
# path the config references, so Apache can start. Certbot will overwrite it.
echo ""
echo "[STEP 3] Creating self-signed bootstrap certificate..."
mkdir -p "$SELF_SIGNED_DIR"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${SELF_SIGNED_DIR}/privkey.pem" \
  -out    "${SELF_SIGNED_DIR}/fullchain.pem" \
  -days 1 \
  -subj "/CN=${DOMAIN}/O=Bootstrap/C=ID" \
  -addext "subjectAltName=DNS:${DOMAIN}" \
  2>/dev/null
echo "[OK]   Self-signed cert created at ${SELF_SIGNED_DIR}"

# Point the HTTPS vhost at the self-signed cert temporarily
# We do a targeted sed rather than rewriting the whole file
cp "$HTTPS_CONF" "${HTTPS_CONF}.bak.$(date +%Y%m%d%H%M%S)"

sed -i \
  "s|SSLCertificateFile.*|SSLCertificateFile    ${SELF_SIGNED_DIR}/fullchain.pem|" \
  "$HTTPS_CONF"
sed -i \
  "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile ${SELF_SIGNED_DIR}/privkey.pem|" \
  "$HTTPS_CONF"

echo "[INFO] Testing Apache config with bootstrap cert..."
if ! apache2ctl configtest 2>&1; then
  echo "[ERROR] Apache configtest failed even with self-signed cert."
  echo "        Check the output above."
  exit 1
fi

echo "[INFO] Starting Apache..."
systemctl enable apache2
systemctl restart apache2
systemctl is-active --quiet apache2 \
  && echo "[OK]   Apache is running." \
  || { echo "[ERROR] Apache failed to start. Check: journalctl -u apache2 -n 30"; exit 1; }

# === STEP 4: install certbot Cloudflare plugin ================================
echo ""
echo "[STEP 4] Installing certbot Cloudflare DNS plugin..."
apt-get install -y python3-certbot-dns-cloudflare

# === STEP 5: write Cloudflare API credentials =================================
echo ""
echo "[STEP 5] Writing Cloudflare API credentials for certbot..."
mkdir -p /etc/letsencrypt
cat > "$CF_CREDS" << EOF
# Cloudflare API token — Zone:DNS:Edit on sampledomain.com
# Generated by moodle-continue.sh
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
chmod 600 "$CF_CREDS"
echo "[OK]   Credentials written to $CF_CREDS (mode 600)"

# === STEP 6: obtain Let's Encrypt certificate =================================
# DNS-01 challenge works even before the Cloudflare Tunnel is active.
# --dns-cloudflare-propagation-seconds 30: Cloudflare propagates near-instantly
# but Let's Encrypt resolvers can lag; 30s is reliable without being slow.
echo ""
echo "[STEP 6] Requesting Let's Encrypt certificate for ${DOMAIN}..."
echo "[INFO]  This takes ~30-60 seconds for DNS propagation..."

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_CREDS" \
  --dns-cloudflare-propagation-seconds 30 \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --email "$ADMIN_EMAIL" \
  -d "$DOMAIN"

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "[ERROR] Certbot ran but cert not found at ${CERT_DIR}/fullchain.pem"
  echo "        Check: /var/log/letsencrypt/letsencrypt.log"
  exit 1
fi

EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)
echo "[OK]   Certificate obtained. Expires: $EXPIRY"

# === STEP 7: swap Apache to real cert =========================================
echo ""
echo "[STEP 7] Updating Apache vhost to use Let's Encrypt cert..."

sed -i \
  "s|SSLCertificateFile.*|SSLCertificateFile    ${CERT_DIR}/fullchain.pem|" \
  "$HTTPS_CONF"
sed -i \
  "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile ${CERT_DIR}/privkey.pem|" \
  "$HTTPS_CONF"

echo "[INFO] Testing Apache config with real cert..."
if ! apache2ctl configtest 2>&1; then
  echo "[ERROR] Apache configtest failed after cert swap. Reverting to self-signed..."
  sed -i \
    "s|SSLCertificateFile.*|SSLCertificateFile    ${SELF_SIGNED_DIR}/fullchain.pem|" \
    "$HTTPS_CONF"
  sed -i \
    "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile ${SELF_SIGNED_DIR}/privkey.pem|" \
    "$HTTPS_CONF"
  apache2ctl configtest && systemctl reload apache2
  echo "[ERROR] Investigate the Apache error above, then re-run this script."
  exit 1
fi

systemctl reload apache2
echo "[OK]   Apache reloaded with Let's Encrypt certificate."

# === STEP 8: certbot renewal hook =============================================
echo ""
echo "[STEP 8] Installing certbot renewal deploy hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-apache2.sh << 'HOOK'
#!/usr/bin/env bash
systemctl reload apache2
echo "[$(date)] Apache reloaded after cert renewal" >> /var/log/letsencrypt-deploy.log
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-apache2.sh
echo "[OK]   Renewal hook: /etc/letsencrypt/renewal-hooks/deploy/reload-apache2.sh"

# Dry-run to confirm auto-renewal is working
echo "[INFO] Testing certbot auto-renewal (dry run)..."
certbot renew --dry-run --quiet \
  && echo "[OK]   Auto-renewal dry-run passed." \
  || echo "[WARN] Auto-renewal dry-run failed — check /var/log/letsencrypt/letsencrypt.log"

# === STEP 9: install cloudflared ==============================================
echo ""
echo "[STEP 9] Configuring Cloudflare Tunnel (${TUNNEL_NAME})..."

if ! command -v cloudflared &>/dev/null; then
  echo "[INFO] cloudflared not found, installing..."
  curl -sSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y cloudflared
fi

CLOUDFLARED_VER=$(cloudflared --version 2>&1 | head -1)
echo "[INFO] cloudflared version: $CLOUDFLARED_VER"

# Remove any existing cloudflared service before reinstalling (idempotent)
systemctl stop cloudflared 2>/dev/null || true
cloudflared service uninstall 2>/dev/null || true

echo "[INFO] Installing cloudflared service with tunnel token..."
cloudflared service install "$CF_TUNNEL_TOKEN"

if [[ ! -f /etc/systemd/system/cloudflared.service ]]; then
  echo "[ERROR] cloudflared service file not created. Token may be invalid."
  echo "        Verify your tunnel token in the Cloudflare Zero Trust dashboard."
  exit 1
fi

# Write ingress config
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
# Cloudflare Tunnel config for Moodle VM
# Tunnel token is stored in the systemd service unit.

ingress:
  - hostname: ${DOMAIN}
    service: https://${DOMAIN}
    originRequest:
      noTLSVerify: false
      originServerName: ${DOMAIN}
  - service: http_status:404
EOF
echo "[OK]   Ingress config written to /etc/cloudflared/config.yml"

systemctl daemon-reload
systemctl enable --now cloudflared

echo "[INFO] Waiting 10s for tunnel to connect..."
sleep 10

if systemctl is-active --quiet cloudflared; then
  echo "[OK]   cloudflared is running."
else
  echo "[WARN] cloudflared is not active. Checking logs..."
  journalctl -u cloudflared -n 20 --no-pager
  echo ""
  echo "[WARN] Common causes:"
  echo "  - Invalid tunnel token (re-check in Cloudflare Zero Trust dashboard)"
  echo "  - Outbound port 7844 (UDP/TCP) blocked by upstream firewall"
fi

# === STEP 10: configure public hostname in Cloudflare dashboard ===============
echo ""
echo "[INFO] ============================================================"
echo "[INFO] ACTION REQUIRED in Cloudflare Dashboard:"
echo ""
echo "  1. Go to: Zero Trust → Networks → Tunnels"
echo "  2. Find tunnel '${TUNNEL_NAME}' → Edit → Public Hostname tab"
echo "  3. Add a public hostname:"
echo "       Subdomain : learn"
echo "       Domain    : sampledomain.com"
echo "       Type      : HTTPS"
echo "       URL       : localhost:443"
echo ""
echo "  This creates: learn.sampledomain.com → <UUID>.cfargotunnel.com (CNAME)"
echo "[INFO] ============================================================"

# === STEP 11: end-to-end validation ===========================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Running validation checks..."

# Apache status
echo -n "[CHECK] Apache service...                          "
systemctl is-active --quiet apache2 && echo "OK" || echo "FAIL"

# PHP-FPM status
echo -n "[CHECK] PHP 8.3 FPM service...                     "
systemctl is-active --quiet php8.3-fpm && echo "OK" || echo "FAIL"

# PostgreSQL status
echo -n "[CHECK] PostgreSQL service...                      "
systemctl is-active --quiet postgresql && echo "OK" || echo "FAIL"

# Cert validity
echo -n "[CHECK] Let's Encrypt cert...                      "
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  DAYS_LEFT=$(( ( $(date -d "$(openssl x509 -enddate -noout \
    -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
  echo "OK (${DAYS_LEFT} days remaining)"
else
  echo "FAIL — cert file not found"
fi

# Apache HTTPS responding locally
echo -n "[CHECK] Apache HTTPS on port 443...                "
HTTP_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
  --max-time 5 --insecure "https://127.0.0.1/" 2>/dev/null || echo "000")
[[ "$HTTP_STATUS" != "000" ]] \
  && echo "OK (HTTP $HTTP_STATUS)" \
  || echo "FAIL (no response)"

# Moodle config.php exists
echo -n "[CHECK] Moodle config.php...                       "
[[ -f /var/www/moodle/config.php ]] && echo "OK" || echo "FAIL — run install-moodle.sh"

# cloudflared status
echo -n "[CHECK] cloudflared service...                     "
systemctl is-active --quiet cloudflared && echo "OK" || echo "FAIL"

# Loopback iptables
echo -n "[CHECK] Loopback iptables ACCEPT rule...           "
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null && echo "OK" || echo "FAIL"

echo "[INFO] ============================================================"

# === SUMMARY ==================================================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Moodle continuation setup complete!"
echo ""
echo "[INFO] Services:"
echo "  Apache    : $(systemctl is-active apache2)"
echo "  PHP-FPM   : $(systemctl is-active php8.3-fpm)"
echo "  PostgreSQL: $(systemctl is-active postgresql)"
echo "  cloudflared: $(systemctl is-active cloudflared)"
echo ""
echo "[INFO] Next steps:"
echo "  1. Add public hostname in CF dashboard (see ACTION REQUIRED above)"
echo "  2. Complete Moodle web installer:"
echo "       https://${DOMAIN}/install.php"
echo "     DB details: cat /root/.moodle_db_pass"
echo "  3. Configure Keycloak OIDC in Moodle admin panel"
echo "  4. Run shared scripts:"
echo "       sudo bash harden-common.sh 192.168.2.197"
echo "       sudo bash tor-block.sh"
echo "       sudo bash tune-performance.sh web"
echo "[INFO] ============================================================"

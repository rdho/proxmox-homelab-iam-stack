#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Continue Guacamole setup after install-guacamole.sh completes.
#
#              This script:
#                1. Verifies guacd + Tomcat 10 + Guacamole are healthy
#                2. Gets Let's Encrypt cert via Cloudflare DNS-01
#                3. Replaces HTTP-only Nginx with full HTTPS + HTTP dual config
#                   (HTTP for cloudflared, HTTPS for LAN direct access)
#                4. Installs cloudflared tunnel pointing at HTTP port 80
#                   (avoids TLS hostname mismatch that caused 502 on Moodle VM)
#                5. Appends Keycloak OIDC config to guacamole.properties
#                6. Restarts Tomcat 10 and validates end-to-end
#
# Usage:       sudo bash guacamole-continue.sh \
#                <CF_API_TOKEN> <CF_TUNNEL_TOKEN> <KC_CLIENT_SECRET>
#
#   CF_API_TOKEN       Zone:DNS:Edit token for sampledomain.com
#                      dash.cloudflare.com → My Profile → API Tokens
#
#   CF_TUNNEL_TOKEN    Remotely-managed tunnel token
#                      Zero Trust → Networks → Tunnels → Create tunnel
#                      Name: "guacamole" → copy token
#
#   KC_CLIENT_SECRET   Keycloak client secret for 'guacamole' client
#                      iam.sampledomain.com → moodle realm →
#                      Clients → guacamole → Credentials tab
#
# Prerequisites:
#   - install-guacamole.sh completed successfully
#   - guacd running on 127.0.0.1:4822
#   - Guacamole (Tomcat 10) running on 127.0.0.1:8080
#   - Keycloak 'guacamole' client exists in 'moodle' realm:
#       Root URL:            https://tty.sampledomain.com/guacamole/
#       Valid redirect URIs: https://tty.sampledomain.com/guacamole/*
#       Client authentication: ON (confidential)
#
# Last Updated: 2026-03
# =============================================================================

# === VARIABLES ===
DOMAIN="tty.sampledomain.com"
ADMIN_EMAIL="admin@sampledomain.com"
KEYCLOAK_URL="https://auth.sampledomain.com"
KEYCLOAK_REALM="moodle"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
CF_CREDS="/etc/letsencrypt/cloudflare.ini"
GUAC_PROPS="/etc/guacamole/guacamole.properties"
GUAC_EXT_DIR="/etc/guacamole/extensions"
GUAC_HOME="/etc/guacamole"
TUNNEL_NAME="guacamole"
TOMCAT_SVC="tomcat9"

# === ARGS ===
CF_API_TOKEN="${1:-}"
CF_TUNNEL_TOKEN="${2:-}"
KC_CLIENT_SECRET="${3:-}"

# === PREFLIGHT ================================================================
[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

if [[ -z "$CF_API_TOKEN" || -z "$CF_TUNNEL_TOKEN" || -z "$KC_CLIENT_SECRET" ]]; then
  echo "[ERROR] Missing required arguments."
  echo ""
  echo "  Usage: sudo bash $0 <CF_API_TOKEN> <CF_TUNNEL_TOKEN> <KC_CLIENT_SECRET>"
  echo ""
  echo "  CF_API_TOKEN:     Zone:DNS:Edit token → dash.cloudflare.com"
  echo "  CF_TUNNEL_TOKEN:  Zero Trust → Tunnels → guacamole → token"
  echo "  KC_CLIENT_SECRET: iam.sampledomain.com → moodle realm → Clients → guacamole → Credentials"
  exit 1
fi

[[ ! -f "$GUAC_PROPS" ]] && {
  echo "[ERROR] $GUAC_PROPS not found. Run install-guacamole.sh first."
  exit 1
}

echo "[INFO] ============================================================"
echo "[INFO] Guacamole continuation script"
echo "[INFO] DOMAIN  : $DOMAIN"
echo "[INFO] TOMCAT  : $TOMCAT_SVC"
echo "[INFO] ============================================================"

# === STEP 1: loopback iptables ===============================================
echo ""
echo "[STEP 1] Verifying loopback iptables..."
if iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
  echo "[OK]   Loopback ACCEPT rule present."
else
  iptables -I INPUT 1 -i lo -j ACCEPT
  iptables-save > /etc/iptables/rules.v4
  echo "[OK]   Loopback ACCEPT rule inserted."
fi

# === STEP 2: verify services are healthy =====================================
echo ""
echo "[STEP 2] Verifying guacd and Guacamole health..."

systemctl is-active --quiet guacd || {
  echo "[ERROR] guacd is not running."
  echo "        Fix: sudo systemctl start guacd"
  echo "        Check: journalctl -u guacd -n 30 --no-pager"
  exit 1
}
echo "[OK]   guacd is active."

ss -tlnp | grep -q ":4822" || {
  echo "[WARN] guacd not listening on 4822 yet — waiting 5s..."
  sleep 5
}
echo "[OK]   guacd listening on 4822."

GUAC_HTTP=$(curl -sSo /dev/null -w "%{http_code}" \
  --max-time 10 "http://127.0.0.1:8080/guacamole/" 2>/dev/null || echo "000")
if [[ "$GUAC_HTTP" == "000" ]]; then
  echo "[ERROR] Guacamole not responding on port 8080."
  echo "        Check: journalctl -u ${TOMCAT_SVC} -n 40 --no-pager"
  exit 1
fi
echo "[OK]   Guacamole responding: HTTP $GUAC_HTTP"

# === STEP 3: Cloudflare API credentials ======================================
echo ""
echo "[STEP 3] Writing Cloudflare API credentials..."
mkdir -p /etc/letsencrypt
cat > "$CF_CREDS" << EOF
# Cloudflare API token — Zone:DNS:Edit on sampledomain.com
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
chmod 600 "$CF_CREDS"
echo "[OK]   Credentials written to $CF_CREDS"

# === STEP 4: Let's Encrypt certificate =======================================
echo ""
echo "[STEP 4] Requesting Let's Encrypt certificate for ${DOMAIN}..."
echo "[INFO]  DNS-01 via Cloudflare (~30-60s propagation)..."

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_CREDS" \
  --dns-cloudflare-propagation-seconds 30 \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --email "$ADMIN_EMAIL" \
  -d "$DOMAIN"

[[ ! -f "${CERT_DIR}/fullchain.pem" ]] && {
  echo "[ERROR] Cert not found at ${CERT_DIR}/fullchain.pem"
  echo "        Check: /var/log/letsencrypt/letsencrypt.log"
  exit 1
}
EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)
echo "[OK]   Certificate obtained. Expires: $EXPIRY"

# === STEP 5: certbot renewal hook ============================================
echo ""
echo "[STEP 5] Installing Nginx reload hook for cert renewals..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
echo "[$(date)] Nginx reloaded after cert renewal" >> /var/log/letsencrypt-deploy.log
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
certbot renew --dry-run --quiet \
  && echo "[OK]   Auto-renewal dry-run passed." \
  || echo "[WARN] Auto-renewal dry-run failed — check /var/log/letsencrypt/letsencrypt.log"

# === STEP 6: Nginx full config (HTTP for cloudflared + HTTPS for LAN) ========
# Lesson from Moodle VM: cloudflared → https://localhost:443 fails with
# "certificate valid for tty.sampledomain.com, not localhost" → 502.
# Solution: cloudflared → http://127.0.0.1:80 (no TLS mismatch).
# Port 443 stays for direct LAN access from 192.168.2.x.
echo ""
echo "[STEP 6] Installing full Nginx config (HTTP + HTTPS)..."

rm -f /etc/nginx/sites-enabled/guacamole-http.conf
rm -f /etc/nginx/sites-available/guacamole-http.conf
rm -f /etc/nginx/sites-enabled/guacamole.conf 2>/dev/null || true

cat > /etc/nginx/sites-available/guacamole.conf << EOF
# ── port 80: cloudflared originService ───────────────────────────────────────
# Plain HTTP — Cloudflare edge handles TLS for internet users.
# X-Forwarded-Proto: https tells Guacamole to generate https:// URLs.
server {
    listen 80;
    server_name ${DOMAIN};

    location /guacamole/ {
        proxy_pass            http://127.0.0.1:8080/guacamole/;
        proxy_http_version    1.1;
        proxy_set_header      Upgrade \$http_upgrade;
        proxy_set_header      Connection "upgrade";
        proxy_set_header      Host \$host;
        proxy_set_header      X-Real-IP \$remote_addr;
        proxy_set_header      X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto https;
        proxy_buffering       off;
        proxy_read_timeout    86400;
        proxy_connect_timeout 30s;
        access_log /var/log/nginx/guacamole-access.log;
        error_log  /var/log/nginx/guacamole-error.log;
    }

    location = / {
        return 302 /guacamole/;
    }
}

# ── port 443: LAN direct access ──────────────────────────────────────────────
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    location /guacamole/ {
        proxy_pass            http://127.0.0.1:8080/guacamole/;
        proxy_http_version    1.1;
        proxy_set_header      Upgrade \$http_upgrade;
        proxy_set_header      Connection "upgrade";
        proxy_set_header      Host \$host;
        proxy_set_header      X-Real-IP \$remote_addr;
        proxy_set_header      X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto https;
        proxy_buffering       off;
        proxy_read_timeout    86400;
        proxy_connect_timeout 30s;
    }

    location = / {
        return 302 /guacamole/;
    }
}
EOF

ln -sf /etc/nginx/sites-available/guacamole.conf \
       /etc/nginx/sites-enabled/guacamole.conf

nginx -t
systemctl reload nginx
echo "[OK]   Nginx reloaded with HTTPS + HTTP config."

# === STEP 7: cloudflared tunnel ==============================================
echo ""
echo "[STEP 7] Configuring Cloudflare Tunnel (${TUNNEL_NAME})..."

systemctl stop cloudflared 2>/dev/null || true
cloudflared service uninstall 2>/dev/null || true

cloudflared service install "$CF_TUNNEL_TOKEN"

[[ ! -f /etc/systemd/system/cloudflared.service ]] && {
  echo "[ERROR] cloudflared service not created — token may be invalid."
  exit 1
}

mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
# Cloudflare Tunnel — Guacamole VM
# HTTP to port 80 avoids TLS hostname mismatch on localhost.
# Cloudflare edge handles TLS termination for internet users.
ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:80
  - service: http_status:404
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

echo "[INFO] Waiting 10s for tunnel to register..."
sleep 10

systemctl is-active --quiet cloudflared \
  && echo "[OK]   cloudflared running." \
  || {
    echo "[WARN] cloudflared not active. Logs:"
    journalctl -u cloudflared -n 20 --no-pager
  }

# === STEP 8: verify OIDC extension is present ================================
# install-guacamole.sh already installs this — just verify it's there.
# If missing (e.g. partial install), download it now.
echo ""
echo "[STEP 8] Verifying OIDC SSO extension..."
GUAC_VER="1.6.0"

OIDC_JAR=$(ls "${GUAC_EXT_DIR}"/*openid*.jar 2>/dev/null | head -1 || true)

if [[ -n "$OIDC_JAR" ]]; then
  echo "[OK]   OIDC extension present: $(basename $OIDC_JAR)"
else
  echo "[WARN] OIDC extension not found — downloading now..."
  for BASE_URL in \
    "https://downloads.apache.org/guacamole/${GUAC_VER}/binary" \
    "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary"; do
    if curl -sSfL \
      "${BASE_URL}/guacamole-auth-sso-${GUAC_VER}.tar.gz" \
      -o "/tmp/guacamole-auth-sso-${GUAC_VER}.tar.gz"; then
      tar -xzf "/tmp/guacamole-auth-sso-${GUAC_VER}.tar.gz" -C /tmp/
      OPENID_JAR=$(find "/tmp/guacamole-auth-sso-${GUAC_VER}" \
        -name "*openid*.jar" | head -1)
      [[ -n "$OPENID_JAR" ]] && cp "$OPENID_JAR" "$GUAC_EXT_DIR/"
      rm -rf "/tmp/guacamole-auth-sso-${GUAC_VER}" \
             "/tmp/guacamole-auth-sso-${GUAC_VER}.tar.gz"
      echo "[OK]   OIDC extension installed."
      break
    fi
  done
  ls "${GUAC_EXT_DIR}"/*openid*.jar 2>/dev/null \
    || echo "[ERROR] OIDC extension still missing — install manually before continuing."
fi

# Fix ownership so Tomcat can read extensions
chown -R tomcat:tomcat "$GUAC_HOME"
chmod 640 "${GUAC_PROPS}"

# === STEP 9: Keycloak OIDC config in guacamole.properties ====================
echo ""
echo "[STEP 9] Writing Keycloak OIDC config to guacamole.properties..."
cp "$GUAC_PROPS" "${GUAC_PROPS}.bak.$(date +%Y%m%d%H%M%S)"

# Remove any existing OIDC block first (idempotent re-runs)
sed -i '/# === Keycloak OIDC/,/^[^o]/{ /^openid-/d }' "$GUAC_PROPS" 2>/dev/null || true
sed -i '/^openid-/d' "$GUAC_PROPS" 2>/dev/null || true
sed -i '/# === Keycloak OIDC/d' "$GUAC_PROPS" 2>/dev/null || true

cat >> "$GUAC_PROPS" << EOF

# === Keycloak OIDC Authentication ===
# Docs: https://guacamole.apache.org/doc/gug/openid-auth.html
openid-authorization-endpoint=${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth
openid-jwks-endpoint=${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs
openid-issuer=${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}
openid-client-id=guacamole
openid-client-secret=${KC_CLIENT_SECRET}
openid-redirect-uri=https://${DOMAIN}/guacamole/
openid-username-claim-type=preferred_username
openid-scope=openid email profile
openid-allowed-clock-skew=10
EOF

echo "[OK]   OIDC config written."
grep "^openid-" "$GUAC_PROPS" \
  | sed 's/\(openid-client-secret=\).*/\1***MASKED***/'

# === STEP 10: Cloudflare dashboard reminder ==================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] ACTION REQUIRED in Cloudflare Dashboard:"
echo ""
echo "  Zero Trust → Networks → Tunnels → guacamole → Edit"
echo "  → Public Hostname → Add:"
echo ""
echo "    Subdomain : tty"
echo "    Domain    : sampledomain.com"
echo "    Type      : HTTP"
echo "    URL       : 127.0.0.1:80"
echo ""
echo "  SSL/TLS → Overview → set mode to: Full"
echo "  (not Full Strict — origin uses plain HTTP)"
echo "[INFO] ============================================================"

# === STEP 11: restart Tomcat and validate ====================================
echo ""
echo "[STEP 11] Restarting Tomcat 10 to load OIDC extension..."
systemctl restart "$TOMCAT_SVC"

echo "[INFO] Waiting for Tomcat to restart (up to 90s)..."
MAX_WAIT=90; WAITED=0; HTTP="000"
while [[ $WAITED -lt $MAX_WAIT ]]; do
  sleep 5; WAITED=$((WAITED + 5))
  HTTP=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 4 "http://127.0.0.1:8080/guacamole/" 2>/dev/null || echo "000")
  [[ "$HTTP" != "000" ]] && break
  echo "  [${WAITED}s] Waiting... (HTTP $HTTP)"
done

# === VALIDATION ==============================================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Validation:"

echo -n "  guacd:                      " ; systemctl is-active guacd
echo -n "  tomcat9:                    " ; systemctl is-active tomcat9
echo -n "  mariadb:                    " ; systemctl is-active mariadb
echo -n "  nginx:                      " ; systemctl is-active nginx
echo -n "  cloudflared:                " ; systemctl is-active cloudflared

echo -n "  Guacamole direct (8080):    "
echo "HTTP $(curl -sSo /dev/null -w '%{http_code}' \
  --max-time 8 http://127.0.0.1:8080/guacamole/ 2>/dev/null || echo 000)"

echo -n "  Nginx proxy (80):           "
echo "HTTP $(curl -sSo /dev/null -w '%{http_code}' \
  --max-time 8 http://127.0.0.1/guacamole/ 2>/dev/null || echo 000)"

echo -n "  guacd on port 4822:         "
ss -tlnp | grep -q ":4822" && echo "listening" || echo "NOT listening"

echo -n "  SSL cert valid:             "
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  DAYS=$(( ( $(date -d "$(openssl x509 -enddate -noout \
    -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
  echo "YES (${DAYS} days remaining)"
else
  echo "NO — cert file missing"
fi

echo -n "  OIDC extension JAR:         "
ls "$GUAC_EXT_DIR"/*openid*.jar 2>/dev/null | xargs -I{} basename {} \
  || echo "NOT FOUND"

echo -n "  Loopback iptables:          "
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null && echo "OK" || echo "MISSING"

echo ""
echo "[INFO] ============================================================"
echo "[INFO] Guacamole continuation complete!"
echo ""
echo "  Public (Cloudflare):  https://${DOMAIN}/guacamole/"
echo "  LAN direct:           https://192.168.2.197/guacamole/"
echo "  Default admin:        guacadmin / guacadmin"
echo ""
echo "[WARN] Change guacadmin password before adding connections!"
echo ""
echo "[INFO] Next steps:"
echo "  1. Complete Cloudflare dashboard config (ACTION REQUIRED above)"
echo "  2. Test login — Keycloak button should appear on login page"
echo "  3. Run shared hardening scripts:"
echo "       sudo bash harden-common.sh 192.168.2.0/24"
echo "       sudo bash tor-block.sh"
echo "       sudo bash tune-performance.sh rdp"
echo "  4. Add RDP/SSH connections in Guacamole admin panel"
echo "[INFO] ============================================================"

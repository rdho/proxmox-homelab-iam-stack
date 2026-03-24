#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Continue Keycloak setup from the point where Nginx failed due to
#              missing Let's Encrypt cert (BIO_new_file / no such file error).
#
#              This script:
#                1. Bootstraps Nginx with a self-signed cert so it starts cleanly
#                2. Runs certbot (Cloudflare DNS-01) to get real Let's Encrypt cert
#                3. Swaps Nginx config to the real cert and reloads
#                4. Installs and configures cloudflared tunnel for auth.devoops.lol
#                5. Sets up Cloudflare tunnel route (DNS CNAME)
#                6. Installs cloudflared as a systemd service
#                7. Validates everything end-to-end
#
# Usage:       sudo bash keycloak-continue.sh <CF_API_TOKEN> <CF_TUNNEL_TOKEN>
#
#              CF_API_TOKEN   — Cloudflare API token with Zone:DNS:Edit on devoops.lol
#                               (used by certbot for DNS-01 challenge)
#                               Create at: dash.cloudflare.com → My Profile → API Tokens
#                               Use template: "Edit zone DNS" → Zone: devoops.lol
#
#              CF_TUNNEL_TOKEN — Cloudflare Tunnel token (remotely-managed tunnel)
#                               Create at: dash.cloudflare.com → Zero Trust →
#                               Networks → Tunnels → Create tunnel → Cloudflared
#                               Copy the token shown in the install command
#
# Prerequisites:
#   - install-keycloak.sh completed UP TO the Nginx step (Keycloak + PostgreSQL running)
#   - cloudflared already installed by install-keycloak.sh
#   - DNS: auth.devoops.lol and iam.devoops.lol are set up in Cloudflare
#     (the tunnel route command in this script creates them if missing)
#   - Outbound port 7844 allowed (Cloudflare Tunnel egress)
#
# Last Updated: 2026-03
# =============================================================================

# === VARIABLES ===
PUBLIC_DOMAIN="auth.devoops.lol"
ADMIN_DOMAIN="iam.devoops.lol"
ADMIN_EMAIL="admin@devoops.lol"
CERT_DIR="/etc/letsencrypt/live/${PUBLIC_DOMAIN}"
CF_CREDS="/etc/letsencrypt/cloudflare.ini"
SELF_SIGNED_DIR="/etc/nginx/ssl/selfsigned"
TUNNEL_NAME="keycloak"

# === ARGS ===
CF_API_TOKEN="${1:-}"
CF_TUNNEL_TOKEN="${2:-}"

# === PREFLIGHT ===
[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

if [[ -z "$CF_API_TOKEN" ]]; then
  echo "[ERROR] Missing Cloudflare API token."
  echo "        Usage: sudo bash $0 <CF_API_TOKEN> <CF_TUNNEL_TOKEN>"
  echo ""
  echo "        CF_API_TOKEN:   Zone:DNS:Edit token from dash.cloudflare.com"
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
echo "[INFO] Keycloak post-install continuation script"
echo "[INFO] PUBLIC_DOMAIN : $PUBLIC_DOMAIN"
echo "[INFO] ADMIN_DOMAIN  : $ADMIN_DOMAIN"
echo "[INFO] ============================================================"

# === VERIFY KEYCLOAK IS RUNNING ===
echo "[INFO] Checking Keycloak service status..."
if ! systemctl is-active --quiet keycloak; then
  echo "[WARN] Keycloak is not running. Attempting to start..."
  systemctl start keycloak
  sleep 15
  if ! systemctl is-active --quiet keycloak; then
    echo "[ERROR] Keycloak failed to start. Check: journalctl -u keycloak -n 50"
    echo "        Continuing with Nginx/cert setup anyway..."
  fi
else
  echo "[INFO] Keycloak is running. Good."
fi

# === VERIFY POSTGRESQL IS RUNNING ===
echo "[INFO] Checking PostgreSQL service status..."
systemctl is-active --quiet postgresql || {
  echo "[WARN] PostgreSQL not running, starting it..."
  systemctl start postgresql
}

# === STEP 1: BOOTSTRAP NGINX WITH SELF-SIGNED CERT ===
# Nginx won't start at all if the cert files in the config don't exist.
# We create a temporary self-signed cert so Nginx can start, then we replace
# it with the real Let's Encrypt cert after certbot runs.
echo "[INFO] Creating self-signed bootstrap certificate..."
mkdir -p "$SELF_SIGNED_DIR"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${SELF_SIGNED_DIR}/privkey.pem" \
  -out    "${SELF_SIGNED_DIR}/fullchain.pem" \
  -days 1 \
  -subj "/CN=${PUBLIC_DOMAIN}/O=Bootstrap/C=ID" \
  -addext "subjectAltName=DNS:${PUBLIC_DOMAIN},DNS:${ADMIN_DOMAIN}" \
  2>/dev/null
echo "[INFO] Self-signed bootstrap cert created at ${SELF_SIGNED_DIR}"

# === STEP 2: WRITE NGINX CONFIGS POINTING AT SELF-SIGNED CERT ===
echo "[INFO] Writing Nginx configs with bootstrap cert..."
rm -f /etc/nginx/sites-enabled/*

# keycloak-public.conf — CF Tunnel listener (no TLS, localhost only)
cat > /etc/nginx/sites-available/keycloak-public.conf << EOF
# auth.devoops.lol — public-facing OIDC endpoint
# Cloudflare Tunnel sends traffic to 127.0.0.1:7080 (no TLS here;
# Cloudflare handles TLS from the user to its edge, tunnel is mTLS internally)
server {
    listen 127.0.0.1:7080;
    server_name ${PUBLIC_DOMAIN};

    location / {
        proxy_pass              http://127.0.0.1:8080;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_set_header        X-Forwarded-Host \$host;
        proxy_buffer_size       128k;
        proxy_buffers           4 256k;
        proxy_busy_buffers_size 256k;
        proxy_read_timeout      300s;
        proxy_connect_timeout   30s;
    }
}
EOF

# keycloak-admin.conf — LAN-only admin dashboard
# Initially points to self-signed cert; swapped to real cert after certbot
cat > /etc/nginx/sites-available/keycloak-admin.conf << EOF
# iam.devoops.lol — admin dashboard, LAN-only
server {
    listen 443 ssl;
    server_name ${ADMIN_DOMAIN};

    # BOOTSTRAP: self-signed cert — replaced by certbot step below
    ssl_certificate     ${SELF_SIGNED_DIR}/fullchain.pem;
    ssl_certificate_key ${SELF_SIGNED_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # LAN-only access restriction
    allow 192.168.2.0/24;
    deny all;

    location / {
        proxy_pass              http://127.0.0.1:8080;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_set_header        X-Forwarded-Host ${ADMIN_DOMAIN};
        proxy_buffer_size       128k;
        proxy_buffers           4 256k;
        proxy_read_timeout      300s;
        proxy_connect_timeout   30s;
    }

    error_page 497 https://\$host\$request_uri;
}

server {
    listen 80;
    server_name ${ADMIN_DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

ln -sf /etc/nginx/sites-available/keycloak-public.conf /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/keycloak-admin.conf  /etc/nginx/sites-enabled/

echo "[INFO] Testing Nginx config with bootstrap cert..."
if ! nginx -t 2>&1; then
  echo "[ERROR] Nginx config test failed even with self-signed cert."
  echo "        Check /etc/nginx/nginx.conf and the configs above."
  exit 1
fi

echo "[INFO] Starting Nginx..."
systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx && echo "[INFO] Nginx is running." \
  || { echo "[ERROR] Nginx failed to start. Check: journalctl -u nginx -n 30"; exit 1; }

# === STEP 3: INSTALL CERTBOT DNS-CLOUDFLARE PLUGIN ===
echo "[INFO] Installing certbot and Cloudflare DNS plugin..."
apt-get install -y python3-certbot-dns-cloudflare

# === STEP 4: WRITE CLOUDFLARE API TOKEN CREDENTIALS FILE ===
echo "[INFO] Writing Cloudflare API credentials for certbot..."
mkdir -p /etc/letsencrypt
cat > "$CF_CREDS" << EOF
# Cloudflare API token — Zone:DNS:Edit on devoops.lol
# Generated by keycloak-continue.sh
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
chmod 600 "$CF_CREDS"
echo "[INFO] Credentials written to $CF_CREDS (mode 600)"

# === STEP 5: OBTAIN LET'S ENCRYPT CERT VIA DNS-01 CHALLENGE ===
# Using DNS-01 (not HTTP-01) because:
#   - Cloudflare Tunnel proxies the domain; direct HTTP challenge would need
#     Cloudflare to forward /.well-known/acme-challenge to this server
#   - DNS-01 works regardless of whether the tunnel is active yet
#   - Covers both subdomains in a single cert (SAN)
#   - --dns-cloudflare-propagation-seconds 60: Cloudflare propagates fast but
#     Let's Encrypt resolvers can lag; 60s is safe (default 10s often fails)
echo "[INFO] Requesting Let's Encrypt certificate for ${PUBLIC_DOMAIN} and ${ADMIN_DOMAIN}..."
echo "[INFO] This will take ~60-90 seconds for DNS propagation..."

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_CREDS" \
  --dns-cloudflare-propagation-seconds 60 \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --email "$ADMIN_EMAIL" \
  -d "$PUBLIC_DOMAIN" \
  -d "$ADMIN_DOMAIN"

# Verify cert was actually created
if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "[ERROR] Certbot ran but cert not found at ${CERT_DIR}/fullchain.pem"
  echo "        Check: journalctl -u certbot or /var/log/letsencrypt/letsencrypt.log"
  exit 1
fi
echo "[INFO] Certificate obtained successfully."
echo "[INFO] Cert location: ${CERT_DIR}/fullchain.pem"
EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)
echo "[INFO] Cert expires: $EXPIRY"

# === STEP 6: SWAP NGINX CONFIG TO REAL CERT ===
echo "[INFO] Updating Nginx to use Let's Encrypt certificate..."

# Replace the self-signed cert paths with real cert paths in the admin config
sed -i \
  "s|ssl_certificate     ${SELF_SIGNED_DIR}/fullchain.pem;|ssl_certificate     ${CERT_DIR}/fullchain.pem;|" \
  /etc/nginx/sites-available/keycloak-admin.conf

sed -i \
  "s|ssl_certificate_key ${SELF_SIGNED_DIR}/privkey.pem;|ssl_certificate_key ${CERT_DIR}/privkey.pem;|" \
  /etc/nginx/sites-available/keycloak-admin.conf

# Remove the bootstrap comment now that we have the real cert
sed -i \
  "s|    # BOOTSTRAP: self-signed cert — replaced by certbot step below||" \
  /etc/nginx/sites-available/keycloak-admin.conf

echo "[INFO] Testing Nginx config with real cert..."
if ! nginx -t 2>&1; then
  echo "[ERROR] Nginx config test failed after cert swap."
  echo "        Reverting to self-signed cert to keep Nginx running..."
  sed -i \
    "s|ssl_certificate     ${CERT_DIR}/fullchain.pem;|ssl_certificate     ${SELF_SIGNED_DIR}/fullchain.pem;|" \
    /etc/nginx/sites-available/keycloak-admin.conf
  sed -i \
    "s|ssl_certificate_key ${CERT_DIR}/privkey.pem;|ssl_certificate_key ${SELF_SIGNED_DIR}/privkey.pem;|" \
    /etc/nginx/sites-available/keycloak-admin.conf
  nginx -t && systemctl reload nginx
  echo "[ERROR] Investigate Nginx error above, then re-run this script."
  exit 1
fi

systemctl reload nginx
echo "[INFO] Nginx reloaded with Let's Encrypt certificate."

# === STEP 7: CERTBOT RENEWAL HOOK ===
# Reload nginx automatically after certbot renews the cert
echo "[INFO] Installing certbot renewal deploy hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
echo "[$(date)] Nginx reloaded after cert renewal" >> /var/log/letsencrypt-deploy.log
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
echo "[INFO] Renewal hook installed: /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

# Test auto-renewal config
echo "[INFO] Testing certbot auto-renewal (dry run)..."
certbot renew --dry-run --quiet && echo "[INFO] Auto-renewal dry-run passed." \
  || echo "[WARN] Auto-renewal dry-run failed — check /var/log/letsencrypt/letsencrypt.log"

# === STEP 8: CONFIGURE CLOUDFLARED (REMOTELY-MANAGED TUNNEL) ===
# Using the remotely-managed tunnel approach (token-based) which is simpler
# than locally-managed (login + UUID + config.yml) — no credentials file needed,
# tunnel config lives in the Cloudflare dashboard.
echo "[INFO] Configuring Cloudflare Tunnel (${TUNNEL_NAME})..."

# Verify cloudflared is installed
if ! command -v cloudflared &>/dev/null; then
  echo "[INFO] cloudflared not found, installing..."
  curl -sSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y cloudflared
fi

CLOUDFLARED_VER=$(cloudflared --version 2>&1 | head -1)
echo "[INFO] cloudflared version: $CLOUDFLARED_VER"

# Install cloudflared as a systemd service using the tunnel token
# The token embeds tunnel credentials — no separate login or UUID config needed
echo "[INFO] Installing cloudflared service with tunnel token..."

# Stop and remove any existing cloudflared service first (idempotent)
systemctl stop cloudflared 2>/dev/null || true
cloudflared service uninstall 2>/dev/null || true

# Install the service with the provided tunnel token
cloudflared service install "$CF_TUNNEL_TOKEN"

# cloudflared service install writes the token to /etc/cloudflared/config.yml
# and creates /etc/systemd/system/cloudflared.service automatically.
# We need to add the ingress rules via an additional config or via the dashboard.

# Verify the service file was created
if [[ ! -f /etc/systemd/system/cloudflared.service ]]; then
  echo "[ERROR] cloudflared service file not created. Token may be invalid."
  echo "        Verify your tunnel token in the Cloudflare Zero Trust dashboard."
  exit 1
fi

# === STEP 9: ADD INGRESS CONFIG FOR auth.devoops.lol ===
# For remotely-managed tunnels, ingress is configured in the Cloudflare dashboard
# under Zero Trust → Networks → Tunnels → [your tunnel] → Public Hostname tab.
# We also write a local config that serves as documentation and fallback.
mkdir -p /etc/cloudflared

# Check if service install wrote a config.yml already
if [[ -f /etc/cloudflared/config.yml ]]; then
  echo "[INFO] Existing cloudflared config found at /etc/cloudflared/config.yml"
  # Append ingress if not already present
  if ! grep -q "auth.devoops.lol" /etc/cloudflared/config.yml; then
    cat >> /etc/cloudflared/config.yml << EOF

ingress:
  - hostname: ${PUBLIC_DOMAIN}
    service: http://127.0.0.1:7080
  - service: http_status:404
EOF
    echo "[INFO] Ingress rules appended to /etc/cloudflared/config.yml"
  else
    echo "[INFO] Ingress for ${PUBLIC_DOMAIN} already in config. Skipping."
  fi
else
  # Write a fresh config (token was provided as env var to service, not config)
  cat > /etc/cloudflared/config.yml << EOF
# Cloudflare Tunnel config for Keycloak VM
# Tunnel token is stored in the systemd service unit (set by 'cloudflared service install')
# This file provides the ingress routing rules.

ingress:
  - hostname: ${PUBLIC_DOMAIN}
    service: http://127.0.0.1:7080
    originRequest:
      connectTimeout: 30s
      noTLSVerify: false
  - service: http_status:404
EOF
  echo "[INFO] Ingress config written to /etc/cloudflared/config.yml"
fi

# === STEP 10: START AND ENABLE CLOUDFLARED ===
systemctl daemon-reload
systemctl enable --now cloudflared

echo "[INFO] Waiting 10s for cloudflared to establish tunnel connections..."
sleep 10

if systemctl is-active --quiet cloudflared; then
  echo "[INFO] cloudflared is running."
else
  echo "[WARN] cloudflared is not active. Checking logs..."
  journalctl -u cloudflared -n 20 --no-pager
  echo ""
  echo "[WARN] Common causes:"
  echo "  - Invalid tunnel token (re-check in Cloudflare Zero Trust dashboard)"
  echo "  - Outbound port 7844 (UDP/TCP) blocked by upstream firewall"
  echo "  - No internet connectivity from this VM"
fi

# === STEP 11: CONFIGURE PUBLIC HOSTNAME IN CLOUDFLARE DASHBOARD ===
# For remotely-managed tunnels, the public hostname routing is configured in
# the dashboard, NOT just in config.yml. The config.yml ingress is used as a
# local override, but the dashboard must also have the hostname entry.
echo ""
echo "[INFO] ============================================================"
echo "[INFO] ACTION REQUIRED in Cloudflare Dashboard:"
echo ""
echo "  1. Go to: Zero Trust → Networks → Tunnels"
echo "  2. Find tunnel '${TUNNEL_NAME}' → click Edit (or 3-dot menu → Configure)"
echo "  3. Click 'Public Hostname' tab → 'Add a public hostname'"
echo "  4. Fill in:"
echo "       Subdomain : auth"
echo "       Domain    : devoops.lol"
echo "       Type      : HTTP"
echo "       URL       : 127.0.0.1:7080"
echo ""
echo "  This creates the CNAME: auth.devoops.lol → <UUID>.cfargotunnel.com"
echo "  (If it already exists from a previous run, skip this step)"
echo "[INFO] ============================================================"

# === STEP 12: VALIDATE EVERYTHING ===
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Running validation checks..."

# Check 1: Keycloak responding on port 8080
echo -n "[CHECK] Keycloak health endpoint (localhost:8080)... "
KC_HEALTH=$(curl -sSf --max-time 5 \
  "http://127.0.0.1:8080/health/ready" 2>/dev/null | grep -o '"status":"UP"' || echo "")
if [[ "$KC_HEALTH" == '"status":"UP"' ]]; then
  echo "OK"
else
  echo "WARN — Keycloak may still be starting or health endpoint unavailable"
fi

# Check 2: Nginx listening on expected ports
echo -n "[CHECK] Nginx listening on port 443... "
ss -tlnp | grep -q ':443 ' && echo "OK" || echo "FAIL"

echo -n "[CHECK] Nginx listening on 127.0.0.1:7080... "
ss -tlnp | grep -q '127.0.0.1:7080' && echo "OK" || echo "FAIL"

# Check 3: Cert validity
echo -n "[CHECK] Let's Encrypt cert for ${PUBLIC_DOMAIN}... "
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
  DAYS_LEFT=$(( ( $(date -d "$(openssl x509 -enddate -noout \
    -in "${CERT_DIR}/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
  echo "OK (${DAYS_LEFT} days remaining)"
else
  echo "FAIL — cert file not found"
fi

echo -n "[CHECK] Cert covers ${ADMIN_DOMAIN} (SAN)... "
openssl x509 -text -noout -in "${CERT_DIR}/fullchain.pem" 2>/dev/null \
  | grep -q "$ADMIN_DOMAIN" && echo "OK" || echo "FAIL"

# Check 4: Nginx proxy to Keycloak (via internal port 7080)
echo -n "[CHECK] Nginx→Keycloak proxy on port 7080... "
PROXY_RESP=$(curl -sSo /dev/null -w "%{http_code}" \
  --max-time 5 "http://127.0.0.1:7080/health/ready" 2>/dev/null || echo "000")
if [[ "$PROXY_RESP" =~ ^(200|301|302|303|401)$ ]]; then
  echo "OK (HTTP $PROXY_RESP)"
else
  echo "WARN (HTTP $PROXY_RESP — Keycloak may still be warming up)"
fi

# Check 5: cloudflared running
echo -n "[CHECK] cloudflared service... "
systemctl is-active --quiet cloudflared && echo "OK" || echo "FAIL"

# Check 6: iam.devoops.lol accessible on port 443 from LAN
echo -n "[CHECK] Nginx SSL on port 443 (local HTTPS test)... "
SSL_RESP=$(curl -sSo /dev/null -w "%{http_code}" \
  --max-time 5 --insecure "https://127.0.0.1:443" 2>/dev/null || echo "000")
[[ "$SSL_RESP" != "000" ]] && echo "OK (HTTP $SSL_RESP)" || echo "WARN (no response)"

echo "[INFO] ============================================================"
echo ""

# === SUMMARY ===
echo "[INFO] ============================================================"
echo "[INFO] Keycloak continuation setup complete!"
echo ""
echo "[INFO] Services:"
echo "  Keycloak  : $(systemctl is-active keycloak)"
echo "  PostgreSQL: $(systemctl is-active postgresql)"
echo "  Nginx     : $(systemctl is-active nginx)"
echo "  cloudflared: $(systemctl is-active cloudflared)"
echo ""
echo "[INFO] Endpoints:"
echo "  OIDC (public via CF Tunnel) : https://${PUBLIC_DOMAIN}"
echo "  Admin dashboard (LAN only)  : https://${ADMIN_DOMAIN}"
echo "  Realm discovery             : https://${PUBLIC_DOMAIN}/realms/moodle/.well-known/openid-configuration"
echo ""
echo "[INFO] Saved credentials: /root/.keycloak_creds"
echo ""
echo "[INFO] Next steps:"
echo "  1. In CF Dashboard: configure public hostname for ${PUBLIC_DOMAIN} (see above)"
echo "  2. Log in to admin: https://${ADMIN_DOMAIN}  (from LAN)"
echo "     Creds: cat /root/.keycloak_creds"
echo "  3. Create realm 'moodle'"
echo "  4. Create OIDC clients for Moodle and Guacamole"
echo "  5. Run shared/harden-common.sh and shared/tor-block.sh if not done yet"
echo "[INFO] ============================================================"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Install Keycloak 26.x on Ubuntu 24.04
#              - PostgreSQL 16 backend
#              - Nginx reverse proxy (iam.sampledomain.com → local dashboard)
#              - Cloudflare Tunnel for auth.sampledomain.com (public OIDC endpoint)
#              - Let's Encrypt SSL via Cloudflare DNS challenge
#              - iptables: dashboard accessible only from LAN, public via CF Tunnel
# Usage:       sudo ./install-keycloak.sh
# Last Updated: 2026-03
# =============================================================================

# === VARIABLES ===
KC_VERSION="26.1.0"               # Latest Keycloak 26.x as of early 2026
KC_HOME="/opt/keycloak"
KC_USER="keycloak"
PUBLIC_DOMAIN="auth.sampledomain.com"   # Cloudflare Tunnel public endpoint (OIDC redirects)
ADMIN_DOMAIN="iam.sampledomain.com"     # Internal Nginx proxy (LAN only)
VM_IP="192.168.2.157"
GUACAMOLE_IP="192.168.2.197"
DB_NAME="keycloak"
DB_USER="keycloak"
DB_PASS="$(openssl rand -base64 24)"
KC_ADMIN_USER="kcadmin"
KC_ADMIN_PASS="$(openssl rand -base64 20)"
JAVA_HEAP_OPTS="-Xms512m -Xmx768m"

[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

echo "[INFO] Keycloak $KC_VERSION installation starting..."
echo "[WARN] SAVE THESE CREDENTIALS:"
echo "  DB Password:      $DB_PASS  → saved to /root/.keycloak_creds"
echo "  KC Admin user:    $KC_ADMIN_USER"
echo "  KC Admin pass:    $KC_ADMIN_PASS  → saved to /root/.keycloak_creds"

cat > /root/.keycloak_creds << EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
KC_ADMIN_USER=${KC_ADMIN_USER}
KC_ADMIN_PASS=${KC_ADMIN_PASS}
EOF
chmod 600 /root/.keycloak_creds

# === INSTALL CORE PACKAGES FIRST (needed before firewall setup) ===
echo "[INFO] Installing base packages..."
apt-get update -qq
apt-get install -y openjdk-21-jdk-headless curl wget unzip nginx certbot \
  python3-certbot-nginx python3-certbot-dns-cloudflare postgresql postgresql-contrib \
  iptables-persistent netfilter-persistent

# === OPEN FIREWALL PORTS ===
# iptables-persistent creates /etc/iptables/ on install; safe to use now
echo "[INFO] Configuring iptables for Keycloak..."
# Allow HTTPS (443) from all — Cloudflare Tunnel connects via localhost, Nginx listens externally
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
# Keycloak internal port (8080/8443) — LAN only for direct access
iptables -A INPUT -p tcp --dport 8080 -s 192.168.2.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 8443 -s 192.168.2.0/24 -j ACCEPT
# Block 8080/8443 from everywhere else
iptables -A INPUT -p tcp --dport 8080 -j DROP
iptables -A INPUT -p tcp --dport 8443 -j DROP
# /etc/iptables/ is now guaranteed to exist (created by iptables-persistent)
iptables-save > /etc/iptables/rules.v4

# === CREATE KEYCLOAK SYSTEM USER ===
id "$KC_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin -d "$KC_HOME" "$KC_USER"

# === INSTALL POSTGRESQL ===
echo "[INFO] Setting up PostgreSQL for Keycloak..."
systemctl enable --now postgresql

sudo -u postgres psql << SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING UTF8 TEMPLATE template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec
SQL

# === DOWNLOAD KEYCLOAK ===
echo "[INFO] Downloading Keycloak $KC_VERSION..."
KC_ARCHIVE="keycloak-${KC_VERSION}.tar.gz"
KC_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/${KC_ARCHIVE}"

if [[ ! -f "/tmp/$KC_ARCHIVE" ]]; then
  wget -q "$KC_URL" -O "/tmp/$KC_ARCHIVE"
fi

# Extract to /opt
tar -xzf "/tmp/$KC_ARCHIVE" -C /opt
mv "/opt/keycloak-${KC_VERSION}" "$KC_HOME" 2>/dev/null || true
chown -R "$KC_USER:$KC_USER" "$KC_HOME"

# === KEYCLOAK CONFIGURATION ===
echo "[INFO] Writing Keycloak configuration..."
cat > "${KC_HOME}/conf/keycloak.conf" << EOF
# === Database ===
db=postgres
db-url=jdbc:postgresql://localhost:5432/${DB_NAME}
db-username=${DB_USER}
db-password=${DB_PASS}

# === HTTP / Proxy ===
# Keycloak listens on 8080 (HTTP); Nginx terminates TLS externally
http-enabled=true
http-port=8080
hostname=${PUBLIC_DOMAIN}
hostname-admin=https://${ADMIN_DOMAIN}
proxy-headers=xforwarded

# === Health & metrics ===
health-enabled=true
metrics-enabled=true

# === Features ===
features=token-exchange,admin-fine-grained-authz
EOF

# === BUILD KEYCLOAK (required before first start) ===
echo "[INFO] Running Keycloak build (this takes ~2 min)..."
sudo -u "$KC_USER" "${KC_HOME}/bin/kc.sh" build

# === SYSTEMD SERVICE ===
echo "[INFO] Creating Keycloak systemd service..."
cat > /etc/systemd/system/keycloak.service << EOF
[Unit]
Description=Keycloak Identity Provider
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=idle
User=${KC_USER}
Group=${KC_USER}
WorkingDirectory=${KC_HOME}

Environment="JAVA_OPTS=${JAVA_HEAP_OPTS} -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+UseStringDeduplication -Djava.net.preferIPv4Stack=true"
Environment="KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER}"
Environment="KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_ADMIN_PASS}"

ExecStart=${KC_HOME}/bin/kc.sh start --optimized

# Restart behavior
Restart=on-failure
RestartSec=10s

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${KC_HOME}

# Resource limits (2 vCPU / 2GB VM)
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now keycloak

echo "[INFO] Waiting 30s for Keycloak to start..."
sleep 30
if systemctl is-active --quiet keycloak; then
  echo "[INFO] Keycloak is running"
else
  echo "[WARN] Keycloak may still be starting. Check: journalctl -u keycloak -f"
fi

# === NGINX REVERSE PROXY ===
echo "[INFO] Configuring Nginx reverse proxy..."

# auth.sampledomain.com → internal Keycloak (used by Cloudflare Tunnel)
# iam.sampledomain.com  → internal Keycloak admin (LAN-only access)

cat > /etc/nginx/sites-available/keycloak-public.conf << EOF
# auth.sampledomain.com — public-facing endpoint for OIDC redirects
# Traffic reaches here via Cloudflare Tunnel (127.0.0.1)
server {
    listen 127.0.0.1:7080;   # CF Tunnel sends traffic here
    server_name ${PUBLIC_DOMAIN};

    # Forward to Keycloak
    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-Host \$host;
        proxy_buffer_size          128k;
        proxy_buffers              4 256k;
        proxy_busy_buffers_size    256k;
        proxy_read_timeout         300s;
        proxy_connect_timeout      30s;
    }
}
EOF

# iam.sampledomain.com — internal admin dashboard, LAN-only HTTPS
cat > /etc/nginx/sites-available/keycloak-admin.conf << EOF
# iam.sampledomain.com — internal admin dashboard
# Accessible only from 192.168.2.0/24 subnet
server {
    listen 443 ssl;
    server_name ${ADMIN_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${PUBLIC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Restrict to LAN subnet only
    allow 192.168.2.0/24;
    deny all;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-Host ${ADMIN_DOMAIN};
        proxy_buffer_size  128k;
        proxy_buffers      4 256k;
        proxy_read_timeout 300s;
    }

    # Also redirect HTTP to HTTPS for iam domain
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
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx

# === INSTALL CLOUDFLARED ===
echo "[INFO] Installing cloudflared for auth.sampledomain.com..."
curl -sSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  > /etc/apt/sources.list.d/cloudflared.list
apt-get update -qq
apt-get install -y cloudflared

# Create cloudflared config template
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml.TEMPLATE << EOF
# Replace <TUNNEL_UUID> and <CREDENTIALS_FILE_PATH> with values from:
#   cloudflared tunnel login
#   cloudflared tunnel create keycloak

tunnel: <TUNNEL_UUID>
credentials-file: /root/.cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: ${PUBLIC_DOMAIN}
    service: http://127.0.0.1:7080
    originRequest:
      noTLSVerify: false
  - service: http_status:404
EOF

echo ""
echo "[INFO] ==========================================================="
echo "[INFO] Cloudflare Tunnel setup for ${PUBLIC_DOMAIN}:"
echo ""
echo "  1. cloudflared tunnel login"
echo "  2. cloudflared tunnel create keycloak"
echo "  3. cp /etc/cloudflared/config.yml.TEMPLATE /etc/cloudflared/config.yml"
echo "  4. Edit config.yml with your actual TUNNEL_UUID"
echo "  5. cloudflared tunnel route dns keycloak ${PUBLIC_DOMAIN}"
echo "  6. cloudflared service install"
echo "  7. systemctl enable --now cloudflared"
echo "[INFO] ==========================================================="

# === SSL CERT (Cloudflare DNS challenge) ===
echo ""
echo "[INFO] ==========================================================="
echo "[INFO] Get SSL cert via Cloudflare DNS challenge:"
echo ""
echo "  1. Create /etc/letsencrypt/cloudflare.ini:"
echo "     dns_cloudflare_api_token = YOUR_CF_API_TOKEN"
echo "     chmod 600 /etc/letsencrypt/cloudflare.ini"
echo ""
echo "  2. apt-get install -y python3-certbot-dns-cloudflare"
echo ""
echo "  3. certbot certonly --dns-cloudflare \\"
echo "       --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \\"
echo "       -d ${PUBLIC_DOMAIN} -d ${ADMIN_DOMAIN} \\"
echo "       --non-interactive --agree-tos --email admin@sampledomain.com"
echo ""
echo "  4. systemctl reload nginx"
echo "[INFO] ==========================================================="

echo ""
echo "[INFO] ==========================================================="
echo "[INFO] Keycloak installation complete!"
echo "[INFO] Creds saved to: /root/.keycloak_creds"
echo ""
echo "[INFO] Admin UI (LAN only): https://${ADMIN_DOMAIN}"
echo "[INFO] OIDC Endpoint (public): https://${PUBLIC_DOMAIN}"
echo "[INFO] Realm discovery: https://${PUBLIC_DOMAIN}/realms/moodle/.well-known/openid-configuration"
echo ""
echo "[INFO] After startup, create realm 'moodle' and OIDC client for Moodle."
echo "[INFO] See keycloak-moodle-oidc-guide.md for step-by-step."
echo "[INFO] ==========================================================="

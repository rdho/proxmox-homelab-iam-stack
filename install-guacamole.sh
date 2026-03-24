#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Purpose:     Install Apache Guacamole 1.5.5 on Ubuntu 24.04 from source
#              - Builds guacd (C server) from source
#              - Deploys guacamole.war to Tomcat 9
#              - MariaDB backend for user/connection storage
#              - Nginx reverse proxy (HTTP only — SSL added by continue script)
#              - iptables: loopback ACCEPT first (fixes 502/504 on all VMs)
#              - cloudflared binary installed (service configured in continue script)
#
# Intentionally does NOT:
#   - Configure Nginx SSL (cert doesn't exist yet)
#   - Start cloudflared tunnel (token provided in continue script)
#   - Configure Keycloak OIDC (client secret provided in continue script)
#
# Usage:       sudo bash install-guacamole.sh
# Continue:    sudo bash guacamole-continue.sh <CF_API_TOKEN> <CF_TUNNEL_TOKEN> <KC_CLIENT_SECRET>
# Last Updated: 2026-03
# =============================================================================

GUAC_VER="1.6.0"
DOMAIN="tty.devoops.lol"
GUAC_DB="guacamole_db"
GUAC_DB_USER="guacamole_user"
GUAC_DB_PASS="$(openssl rand -base64 24)"
TOMCAT_SVC="tomcat9"
TOMCAT9_VER="9.0.115"
TOMCAT_WEBAPPS="/opt/tomcat9/webapps"
GUAC_HOME="/etc/guacamole"

[[ $EUID -ne 0 ]] && { echo "[ERROR] Must run as root"; exit 1; }

echo "[INFO] ============================================================"
echo "[INFO] Guacamole ${GUAC_VER} manual install — $DOMAIN"
echo "[INFO] ============================================================"

cat > /root/.guacamole_creds << EOF
GUAC_VER=${GUAC_VER}
GUAC_DB=${GUAC_DB}
GUAC_DB_USER=${GUAC_DB_USER}
GUAC_DB_PASS=${GUAC_DB_PASS}
TOMCAT_SVC=${TOMCAT_SVC}
EOF
chmod 600 /root/.guacamole_creds
echo "[INFO] Creds saved to /root/.guacamole_creds"

# =============================================================================
# STEP 1: iptables — loopback ACCEPT must be first
# =============================================================================
echo ""
echo "[STEP 1] Installing iptables-persistent and configuring firewall..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  iptables-persistent netfilter-persistent

iptables -I INPUT 1 -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22  -j ACCEPT
iptables -A INPUT -p tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -j DROP
iptables-save > /etc/iptables/rules.v4
echo "[OK]   iptables saved (loopback ACCEPT at position 1)"

# =============================================================================
# STEP 2: build dependencies
# =============================================================================
echo ""
echo "[STEP 2] Installing build dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential libcairo2-dev libjpeg-turbo8-dev \
  libpng-dev libtool-bin libossp-uuid-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
  freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev \
  libtelnet-dev libwebsockets-dev libssl-dev \
  libwebp-dev libpulse-dev libvorbis-dev libgsm1-dev \
  ghostscript libjpeg-dev \
  wget curl git unzip \
  default-jdk default-jdk \
  mariadb-server mariadb-client \
  nginx certbot python3-certbot-dns-cloudflare \
  ipset
echo "[OK]   Build dependencies installed."

# =============================================================================
# STEP 3: download source and binaries
# =============================================================================
echo ""
echo "[STEP 3] Downloading Guacamole ${GUAC_VER}..."
cd /tmp

wget -q --show-progress \
  "https://downloads.apache.org/guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz" \
  || wget -q "https://archive.apache.org/dist/guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz"

wget -q --show-progress \
  "https://downloads.apache.org/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war" \
  || wget -q "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war"

wget -q --show-progress \
  "https://downloads.apache.org/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz" \
  || wget -q "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz"

wget -q --show-progress \
  "https://downloads.apache.org/guacamole/${GUAC_VER}/binary/guacamole-auth-sso-${GUAC_VER}.tar.gz" \
  || wget -q "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-sso-${GUAC_VER}.tar.gz"

CONNECTOR_VER="8.0.33"
wget -q --show-progress \
  "https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j-${CONNECTOR_VER}.tar.gz"

echo "[OK]   All downloads complete."

# =============================================================================
# STEP 4: build and install guacd
# =============================================================================
echo ""
echo "[STEP 4] Building guacd from source (2-3 min)..."
cd /tmp
tar -xzf "guacamole-server-${GUAC_VER}.tar.gz"
cd "guacamole-server-${GUAC_VER}"

./configure --with-init-dir=/etc/init.d 2>&1 | tail -20
make -j"$(nproc)"
make install
ldconfig

if ! id guacd &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin guacd
fi

cat > /etc/systemd/system/guacd.service << 'EOF'
[Unit]
Description=Guacamole Server (guacd)
After=network.target

[Service]
Type=forking
User=guacd
Group=guacd
ExecStart=/usr/local/sbin/guacd -b 127.0.0.1 -l 4822
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now guacd
echo "[OK]   guacd $(guacd --version 2>&1 | head -1) running."

# =============================================================================
# STEP 5: deploy guacamole.war
# =============================================================================
echo ""
echo "[STEP 5] Deploying guacamole.war to Tomcat 9..."
systemctl enable --now tomcat9

cp "/tmp/guacamole-${GUAC_VER}.war" "${TOMCAT_WEBAPPS}/guacamole.war"
chown tomcat:tomcat "${TOMCAT_WEBAPPS}/guacamole.war"

mkdir -p "$GUAC_HOME"/{extensions,lib}
grep -q "GUACAMOLE_HOME" /opt/tomcat9/bin/setenv.sh 2>/dev/null || echo "export GUACAMOLE_HOME=/etc/guacamole" >> /opt/tomcat9/bin/setenv.sh
  || echo 'GUACAMOLE_HOME=/etc/guacamole' >> /opt/tomcat9/bin/setenv.sh

echo "[OK]   guacamole.war deployed."

# =============================================================================
# STEP 6: JDBC extension + MySQL connector
# =============================================================================
echo ""
echo "[STEP 6] Installing JDBC extension and MySQL connector..."
cd /tmp

tar -xzf "guacamole-auth-jdbc-${GUAC_VER}.tar.gz"
cp "guacamole-auth-jdbc-${GUAC_VER}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar" \
   "${GUAC_HOME}/extensions/"

tar -xzf "mysql-connector-j-${CONNECTOR_VER}.tar.gz"
cp "mysql-connector-j-${CONNECTOR_VER}/mysql-connector-j-${CONNECTOR_VER}.jar" \
   "${GUAC_HOME}/lib/"

echo "[OK]   JDBC extension and connector installed."

# =============================================================================
# STEP 7: OIDC SSO extension
# =============================================================================
echo ""
echo "[STEP 7] Installing OIDC SSO extension..."
cd /tmp
tar -xzf "guacamole-auth-sso-${GUAC_VER}.tar.gz"

OPENID_JAR=$(find "/tmp/guacamole-auth-sso-${GUAC_VER}" -name "*openid*.jar" | head -1)
if [[ -n "$OPENID_JAR" ]]; then
  cp "$OPENID_JAR" "${GUAC_HOME}/extensions/"
  echo "[OK]   $(basename $OPENID_JAR) installed."
else
  echo "[WARN] openid JAR not found — will need manual install before continue script"
fi

# =============================================================================
# STEP 8: MariaDB setup
# =============================================================================
echo ""
echo "[STEP 8] Configuring MariaDB..."
systemctl enable --now mariadb

mysql -u root << SQL
CREATE DATABASE IF NOT EXISTS ${GUAC_DB}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${GUAC_DB_USER}'@'localhost'
  IDENTIFIED BY '${GUAC_DB_PASS}';
GRANT SELECT,INSERT,UPDATE,DELETE
  ON ${GUAC_DB}.* TO '${GUAC_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

SCHEMA_DIR="/tmp/guacamole-auth-jdbc-${GUAC_VER}/mysql/schema"
cat "${SCHEMA_DIR}/001-create-schema.sql" \
    "${SCHEMA_DIR}/002-create-admin-user.sql" \
  | mysql -u root "${GUAC_DB}"

echo "[OK]   Database ready. Default login: guacadmin / guacadmin"

# =============================================================================
# STEP 9: guacamole.properties
# =============================================================================
echo ""
echo "[STEP 9] Writing guacamole.properties..."
cat > "${GUAC_HOME}/guacamole.properties" << EOF
# guacd connection
guacd-hostname: localhost
guacd-port:     4822

# MariaDB backend
mysql-hostname:  localhost
mysql-port:      3306
mysql-database:  ${GUAC_DB}
mysql-username:  ${GUAC_DB_USER}
mysql-password:  ${GUAC_DB_PASS}

# Auto-create DB accounts for OIDC users on first login
mysql-auto-create-accounts: true
EOF

chown -R tomcat:tomcat "$GUAC_HOME"
chmod 640 "${GUAC_HOME}/guacamole.properties"
echo "[OK]   guacamole.properties written."

# =============================================================================
# STEP 10: Nginx HTTP-only proxy
# =============================================================================
echo ""
echo "[STEP 10] Configuring Nginx HTTP proxy..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/guacamole-http.conf << 'EOF'
server {
    listen 80;
    server_name tty.devoops.lol;

    location /guacamole/ {
        proxy_pass            http://127.0.0.1:8080/guacamole/;
        proxy_http_version    1.1;
        proxy_set_header      Upgrade $http_upgrade;
        proxy_set_header      Connection "upgrade";
        proxy_set_header      Host $host;
        proxy_set_header      X-Real-IP $remote_addr;
        proxy_set_header      X-Forwarded-For $proxy_add_x_forwarded_for;
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
EOF

ln -sf /etc/nginx/sites-available/guacamole-http.conf \
       /etc/nginx/sites-enabled/guacamole-http.conf
nginx -t
systemctl enable --now nginx
echo "[OK]   Nginx HTTP proxy on port 80."

# =============================================================================
# STEP 11: cloudflared binary
# =============================================================================
echo ""
echo "[STEP 11] Installing cloudflared..."
if ! command -v cloudflared &>/dev/null; then
  curl -sSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor > /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq && apt-get install -y cloudflared
fi
echo "[OK]   $(cloudflared --version 2>&1 | head -1)"

# =============================================================================
# STEP 12: restart Tomcat and validate
# =============================================================================
echo ""
echo "[STEP 12] Restarting Tomcat to deploy WAR..."
systemctl restart tomcat9

echo "[INFO] Waiting for Guacamole to become ready (up to 90s)..."
MAX_WAIT=90; WAITED=0; HTTP="000"
while [[ $WAITED -lt $MAX_WAIT ]]; do
  sleep 5; WAITED=$((WAITED + 5))
  HTTP=$(curl -sSo /dev/null -w "%{http_code}" \
    --max-time 4 "http://127.0.0.1:8080/guacamole/" 2>/dev/null || echo "000")
  [[ "$HTTP" != "000" ]] && break
  echo "  [${WAITED}s] Waiting... (HTTP $HTTP)"
done

rm -rf /tmp/guacamole-server-${GUAC_VER} \
       /tmp/guacamole-auth-jdbc-${GUAC_VER} \
       /tmp/guacamole-auth-sso-${GUAC_VER} \
       /tmp/mysql-connector-j-${CONNECTOR_VER}

echo ""
echo "[INFO] ============================================================"
echo "[INFO] Validation:"
echo -n "  guacd:                    " ; systemctl is-active guacd
echo -n "  tomcat9:                  " ; systemctl is-active tomcat9
echo -n "  mariadb:                  " ; systemctl is-active mariadb
echo -n "  nginx:                    " ; systemctl is-active nginx
echo -n "  Guacamole (8080):         "
echo "HTTP $(curl -sSo /dev/null -w '%{http_code}' \
  --max-time 8 http://127.0.0.1:8080/guacamole/ 2>/dev/null || echo 000)"
echo -n "  Nginx proxy (80):         "
echo "HTTP $(curl -sSo /dev/null -w '%{http_code}' \
  --max-time 8 http://127.0.0.1/guacamole/ 2>/dev/null || echo 000)"
echo -n "  Loopback iptables:        "
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null && echo "OK" || echo "MISSING"
echo -n "  Extensions:               "
ls ${GUAC_HOME}/extensions/*.jar 2>/dev/null | xargs -I{} basename {} | tr '\n' ' '
echo ""
echo "[INFO] ============================================================"
echo "[INFO] install-guacamole.sh complete!"
echo ""
echo "[INFO] Guacamole: http://127.0.0.1:8080/guacamole/"
echo "[INFO] Default login: guacadmin / guacadmin"
echo "[WARN] Change guacadmin password before running continue script!"
echo ""
echo "[INFO] Next:"
echo "       sudo bash guacamole-continue.sh \\"
echo "         <CF_API_TOKEN> <CF_TUNNEL_TOKEN> <KC_CLIENT_SECRET>"
echo "[INFO] ============================================================"
